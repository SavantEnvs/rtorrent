// Shared in-process setup for the rtorrent fuzz harnesses: the same main-thread / Control /
// command-table state the upstream cppunit suites build in setUp(), created once per process.
#ifndef MAYHEM_HARNESS_COMMON_H
#define MAYHEM_HARNESS_COMMON_H

#include "config.h"

#include <chrono>
#include <clocale>
#include <memory>

#include "command_helpers.h"
#include "control.h"
#include "globals.h"
#include "rpc/command_map.h"
#include "rpc/rpc_manager.h"

#include <torrent/net/resolver.h>
#include <torrent/system/thread.h>

void initialize_command_string();

namespace mayhem {

class HarnessThread : public torrent::system::Thread {
public:
  const char* name() const override { return "mayhem harness"; }

  void init_thread() override {
    m_resolver = std::make_unique<torrent::net::Resolver>();
    m_state    = STATE_INITIALIZED;
    init_thread_local();
  }

  void cleanup_thread() override {}

private:
  void call_events() override { process_callbacks(); }

  std::chrono::microseconds next_timeout() override { return std::chrono::minutes(10); }
};

inline torrent::Object
reflect(rpc::target_type, const torrent::Object& obj) {
  return obj;
}

inline torrent::Object
reflect_string(rpc::target_type, const std::string& str) {
  return str;
}

// Allow-list: only pure commands are registered (a reflector and the string.* family), never
// execute.*, system.*, file or network commands, so no input can touch the host.
inline void
init(const char* reflect_name, bool with_string_commands) {
  static HarnessThread* thread = nullptr;

  if (thread == nullptr) {
    thread = new HarnessThread;
    thread->init_thread();
    setlocale(LC_ALL, "");
    control = new Control;

    // main.cc binds this to the download list; a freshly started rtorrent has no downloads loaded.
    rpc::rpc.slot_find_download() = [](const char*) -> core::Download* { return nullptr; };

    if (with_string_commands)
      initialize_command_string();
  }

  if (reflect_name != nullptr && rpc::commands.find(reflect_name) == rpc::commands.end()) {
    CMD2_ANY(reflect_name, &reflect);
    CMD2_ANY_STRING(std::string(reflect_name) + "_string", &reflect_string);
  }
}

} // namespace mayhem

#endif
