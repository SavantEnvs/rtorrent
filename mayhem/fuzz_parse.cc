// Fuzzes rtorrent's value/list/object parsers and printers (rpc/parse.cc) plus the base64 decoder.
// The first input byte selects the entry point, the rest is the text handed to it.
#include "harness_common.h"

#include <cstdint>
#include <string>

#include <torrent/exceptions.h>
#include <torrent/object.h>

#include "rpc/parse.h"
#include "utils/base64.h"

extern "C" int
LLVMFuzzerInitialize(int*, char***) {
  mayhem::init(nullptr, false);
  return 0;
}

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 1)
    return -1;

  const uint8_t selector = data[0];
  const std::string text(reinterpret_cast<const char*>(data) + 1, size - 1);
  const char* first = text.c_str();
  const char* last  = first + text.size();

  try {
    torrent::Object obj;
    std::string     printed;
    int64_t         value;

    switch (selector % 8) {
    case 0:
      rpc::parse_object(first, last, &obj);
      rpc::print_object_std(&printed, &obj, 0);
      break;
    case 1:
      obj = torrent::Object::create_list();
      rpc::parse_list(first, last, &obj, &rpc::parse_is_delim_list);
      printed = rpc::convert_list_to_string(obj);
      break;
    case 2:
      rpc::parse_whole_list(first, last, &obj);
      if (obj.is_list() && !obj.as_list().empty() && obj.as_list().front().is_string())
        printed = rpc::convert_list_to_command(obj.as_list().begin(), obj.as_list().end());
      break;
    case 3:
      rpc::parse_whole_value(first, &value, 0, 1);
      break;
    case 4:
      rpc::parse_value_nothrow(first, &value, 10, 1024);
      break;
    case 5:
      rpc::parse_whole_string(first, last, &printed);
      break;
    case 6:
      rpc::parse_object(first, last, &obj, &rpc::parse_is_delim_block);
      printed = rpc::convert_to_string(obj);
      rpc::convert_to_value_nothrow(obj, &value);
      break;
    default:
      printed = utils::decode_base64(text);
      break;
    }
  } catch (const torrent::input_error&) {
    return -1;
  }

  return 0;
}
