// Fuzzes rtorrent's JSON-RPC 2.0 front end: JSON parsing, request validation, parameter conversion
// into torrent::Object, command dispatch and response serialisation.
#include "harness_common.h"

#include <cstdint>
#include <string>

#include "rpc/jsonrpc.h"

extern "C" int
LLVMFuzzerInitialize(int*, char***) {
  mayhem::init("jsonrpc_reflect", true);
  return 0;
}

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  rpc::JsonRpc jsonrpc;
  jsonrpc.initialize();

  std::string output;
  jsonrpc.process(reinterpret_cast<const char*>(data), static_cast<uint32_t>(size),
                  [&output](const char* c, uint32_t l) { output.append(c, l); return true; });
  return 0;
}
