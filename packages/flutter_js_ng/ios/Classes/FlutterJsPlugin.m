#import "FlutterJsPlugin.h"
// flutter_js_ng, not flutter_js. Xcode names the generated Swift
// compatibility header after the Clang module, and this fork's podspec sets
// `s.name = 'flutter_js_ng'` with DEFINES_MODULE, so the module -- and the
// header -- is `flutter_js_ng` (see the generated
// Target Support Files/flutter_js_ng/flutter_js_ng.modulemap). The pre-fork
// name survived the rename here, so `__has_include` silently took the #else
// branch and the fallback then failed the build outright with
// "'flutter_js-Swift.h' file not found".
//
// Only the module name changes. The method channels below stay
// `io.abner.flutter_js`, because those are the wire contract with the Dart
// side, not a build-time identifier.
#if __has_include(<flutter_js_ng/flutter_js_ng-Swift.h>)
#import <flutter_js_ng/flutter_js_ng-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "flutter_js_ng-Swift.h"
#endif

@implementation FlutterJsPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftFlutterJsPlugin registerWithRegistrar:registrar];
}
@end
