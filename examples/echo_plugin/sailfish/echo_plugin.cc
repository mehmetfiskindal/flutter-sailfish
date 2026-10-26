// Example native plugin: exercises the standard method codec in both directions.
//
// Channel "flutter_sailfish/echo":
//   echo(any)  -> returns its argument unchanged (checks every codec type round-trips)
//   info()     -> map with the system name, machine and the plugin's C++ standard
//   fail()     -> error result with a code, message and details
//   (others)   -> not implemented

#include <sys/utsname.h>

#include <memory>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter_sailfish_plugin.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

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
  } else {
    result->NotImplemented();
  }
}

}  // namespace

FLUTTER_SAILFISH_PLUGIN_EXPORT void FlutterSailfishPluginRegister(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "flutter_sailfish/echo", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
}
