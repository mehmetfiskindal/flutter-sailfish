// Interface between the Sailfish runner and native Flutter plugins.
//
// A native plugin is a shared library placed in the plugins directory of an app
// (/usr/share/<app>/plugins/lib*.so, or $FLUTTER_SAILFISH_PLUGINS). The runner loads each
// library with dlopen before the engine starts and calls its FlutterSailfishPluginRegister
// on the platform (Qt GUI) thread. The plugin uses the messenger to create channels with
// Flutter's C++ client wrapper (embedder/third_party/flutter_client_wrapper), exactly as a
// Linux or Windows desktop plugin does with a plugin registrar:
//
//   FLUTTER_SAILFISH_PLUGIN_EXPORT void FlutterSailfishPluginRegister(
//       flutter::BinaryMessenger* messenger) {
//     static auto channel = std::make_unique<flutter::MethodChannel<>>(
//         messenger, "my_plugin", &flutter::StandardMethodCodec::GetInstance());
//     channel->SetMethodCallHandler(...);
//   }
//
// The messenger lives as long as the process. Handlers run on the platform thread; replies
// to Send() arrive there too. The plugin must be built with the same compiler and C++
// standard library as the runner (the Sailfish SDK target), as std::function and
// std::string cross this boundary, and with C++17 for the client wrapper.

#ifndef FLUTTER_SAILFISH_PLUGIN_H_
#define FLUTTER_SAILFISH_PLUGIN_H_

#include <flutter/binary_messenger.h>

#define FLUTTER_SAILFISH_PLUGIN_EXPORT extern "C" __attribute__((visibility("default")))

typedef void (*FlutterSailfishPluginRegisterFn)(flutter::BinaryMessenger* messenger);

#endif  // FLUTTER_SAILFISH_PLUGIN_H_
