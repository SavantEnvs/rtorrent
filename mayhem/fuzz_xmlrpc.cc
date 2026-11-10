// Fuzzes rtorrent's XML-RPC front end (the bundled TinyXML-2 backend): XML parsing, methodCall
// validation, value conversion, system.multicall and response serialisation.
#include "harness_common.h"

#include <cstdint>
#include <string>

#include "rpc/xmlrpc.h"

extern "C" int
LLVMFuzzerInitialize(int*, char***) {
  mayhem::init("xmlrpc_reflect", true);
  return 0;
}

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  rpc::XmlRpc xmlrpc;
  xmlrpc.initialize();

  std::string output;
  xmlrpc.process(reinterpret_cast<const char*>(data), static_cast<uint32_t>(size),
                 [&output](const char* c, uint32_t l) { output.append(c, l); return true; });
  return 0;
}
