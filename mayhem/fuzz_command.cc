// Fuzzes rtorrent's command-script interpreter (the syntax used by .rtorrent.rc and xmlrpc string
// calls): command-name parsing, argument/list/block parsing and execution of the pure commands.
#include "harness_common.h"

#include <cstdint>

#include <torrent/exceptions.h>

#include "rpc/parse_commands.h"

extern "C" int
LLVMFuzzerInitialize(int*, char***) {
  mayhem::init("cmd_reflect", true);
  return 0;
}

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const char* first = reinterpret_cast<const char*>(data);

  try {
    rpc::parse_command_multiple(rpc::make_target(), first, first + size);
  } catch (const torrent::input_error&) {
    return -1;
  }

  return 0;
}
