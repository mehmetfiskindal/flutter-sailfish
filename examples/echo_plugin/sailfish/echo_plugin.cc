// Example native plugin: exercises the standard method codec and event channels.
//
// Method channel "flutter_sailfish/echo":
//   echo(any)  -> returns its argument unchanged (checks every codec type round-trips)
//   info()     -> map with the system name, machine and the plugin's C++ standard
//   fail()     -> error result with a code, message and details
//   streamStats() -> how many streams were cancelled by Dart or completed by the plugin
//   (others)   -> not implemented
//
// Event channel "flutter_sailfish/echo_events": on listen, a background thread sends the
// integers 1..count, one every intervalMs, and then ends the stream. Arguments (a map, all
// optional): count (default 5), intervalMs (default 100), failAt (send an error event instead
// of that number; default 0 = never). The thread stops when Dart cancels the subscription.

#include <sys/utsname.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter_sailfish_plugin.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::unique_ptr<flutter::EventChannel<EncodableValue>> g_events;

// The one active listener: an event channel has a single stream at a time.
struct Stream {
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;
  std::atomic<bool> stop{false};
  std::thread thread;
};
std::unique_ptr<Stream> g_stream;
std::atomic<int> g_cancelled{0};
std::atomic<int> g_completed{0};

int64_t IntArgument(const EncodableValue* args, const char* key, int64_t fallback) {
  const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
  if (!map) return fallback;
  auto it = map->find(EncodableValue(std::string(key)));
  if (it == map->end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
  return fallback;
}

// Stops the producer thread (if any) and drops the sink. Runs on the platform thread.
void StopStream() {
  if (!g_stream) return;
  g_stream->stop = true;
  if (g_stream->thread.joinable()) g_stream->thread.join();
  g_stream.reset();
}

void Produce(Stream* stream, int64_t count, int64_t interval_ms, int64_t fail_at) {
  for (int64_t i = 1; i <= count; ++i) {
    // Sleep in short slices so a cancel is noticed quickly.
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(interval_ms);
    while (std::chrono::steady_clock::now() < deadline) {
      if (stream->stop) return;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (stream->stop) return;
    if (i == fail_at) {
      stream->sink->Error("tick_failed", "Failed on request", EncodableValue(i));
    } else {
      stream->sink->Success(EncodableValue(i));
    }
  }
  if (stream->stop) return;
  stream->sink->EndOfStream();
  ++g_completed;
}

void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "echo") {
    result->Success(call.arguments() ? *call.arguments() : EncodableValue());
  } else if (method == "info") {
    utsname u = {};
    uname(&u);
    EncodableMap info;
    info[EncodableValue("sysname")] = EncodableValue(std::string(u.sysname));
    info[EncodableValue("machine")] = EncodableValue(std::string(u.machine));
    info[EncodableValue("cppStandard")] = EncodableValue(static_cast<int64_t>(__cplusplus));
    result->Success(EncodableValue(info));
  } else if (method == "fail") {
    result->Error("demo_error", "This failure was requested", EncodableValue(42));
  } else if (method == "streamStats") {
    EncodableMap stats;
    stats[EncodableValue("cancelled")] = EncodableValue(static_cast<int32_t>(g_cancelled));
    stats[EncodableValue("completed")] = EncodableValue(static_cast<int32_t>(g_completed));
    result->Success(EncodableValue(stats));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

FLUTTER_SAILFISH_PLUGIN_EXPORT void FlutterSailfishPluginRegister(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "flutter_sailfish/echo", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);

  g_events = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "flutter_sailfish/echo_events", &flutter::StandardMethodCodec::GetInstance());
  g_events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      // on listen
      [](const EncodableValue* arguments, std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        StopStream();
        g_stream = std::make_unique<Stream>();
        g_stream->sink = std::move(events);
        const int64_t count = IntArgument(arguments, "count", 5);
        const int64_t interval = IntArgument(arguments, "intervalMs", 100);
        const int64_t fail_at = IntArgument(arguments, "failAt", 0);
        Stream* stream = g_stream.get();
        stream->thread = std::thread([=] { Produce(stream, count, interval, fail_at); });
        return nullptr;
      },
      // on cancel
      [](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        StopStream();
        ++g_cancelled;
        return nullptr;
      }));
}
