#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# libtorrent (pinned, static, uninstrumented) is prebuilt by the Dockerfile; rtorrent's configure finds it
# through pkg-config. -lcurl -lcrypto -lz is what libtorrent.pc leaves for the final link.
DEP=/opt/toolchains/deps/libtorrent-16f8b1b
export PKG_CONFIG_PATH="$DEP/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
CONFIGURE_ARGS=(--with-xmlrpc-tinyxml2 LIBS="-lcurl -lcrypto -lz")
JOBS="$MAYHEM_JOBS"
BUILD="$SRC/mayhem/build"
BIN="$BUILD/bin"
mkdir -p "$BUILD"

# upstream's generated configure/Makefile.in are gitignored, so regenerate them (idempotent).
autoreconf -fi

# 1) rtorrent itself, sanitized + SanCov (libFuzzer's -no-link flavour, so the project objects carry
#    coverage and the same archive links into both the fuzzer and the standalone reproducer).
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
mkdir -p "$BUILD/fuzz" "$BIN"
(
  cd "$BUILD/fuzz"
  # configure's conftests run under ASan: keep LSan out of them (build-time only).
  export ASAN_OPTIONS=detect_leaks=0
  "$SRC/configure" "${CONFIGURE_ARGS[@]}" CC="$CC" CXX="$CXX" CFLAGS="$FUZZ_FLAGS" CXXFLAGS="$FUZZ_FLAGS"
  make -j"$JOBS" -C src libsub_root.a
)

# Compile/link recipe for the harnesses = whatever rtorrent's own Makefile uses for the project.
cat > "$BUILD/fuzz/vars.mk" <<'MK'
print-%: ; @echo '$($*)'
MK
mk() { make -s -f "$BUILD/fuzz/src/Makefile" -f "$BUILD/fuzz/vars.mk" -C "$BUILD/fuzz/src" "print-$1"; }
HCXX="$(mk CXX) $(mk CXXFLAGS) $(mk CPPFLAGS) $(mk DEFS) -I$BUILD/fuzz -I$SRC -I$SRC/src"
HLIBS="$(mk LIBS)"

# 2) Harnesses: each is built twice, against libFuzzer and against the standalone run-once driver.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/fuzz/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/fuzz/lsan_off.o"

for h in fuzz_jsonrpc fuzz_xmlrpc fuzz_command fuzz_parse; do
  $HCXX -c "$SRC/mayhem/$h.cc" -o "$BUILD/fuzz/$h.o"
  $HCXX $LIB_FUZZING_ENGINE "$BUILD/fuzz/$h.o" "$BUILD/fuzz/lsan_off.o" "$BUILD/fuzz/src/libsub_root.a" $HLIBS -o "$BIN/$h"
  $HCXX "$BUILD/fuzz/$h.o" "$BUILD/fuzz/standalone_main.o" "$BUILD/fuzz/lsan_off.o" "$BUILD/fuzz/src/libsub_root.a" $HLIBS -o "$BIN/$h-standalone"
done

# 3) rtorrent's own cppunit suites with the project's normal flags (independent of the build above);
#    mayhem/test.sh only runs them.
mkdir -p "$BUILD/tests"
(
  cd "$BUILD/tests"
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS "$SRC/configure" "${CONFIGURE_ARGS[@]}" CC="$CC" CXX="$CXX" \
    CFLAGS="-g -O2 $COVERAGE_FLAGS" CXXFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  make -j"$JOBS" check TESTS=
)
