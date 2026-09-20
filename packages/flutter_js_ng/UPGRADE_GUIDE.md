# QuickJS-NG Upgrade Guide for flutter_js_ng

## Architecture

| Platform | JS engine | How it is built |
| :--- | :--- | :--- |
| Android | **QuickJS-NG** | Compiled from `cxx/quickjs/` by `android/CMakeLists.txt` during the app build |
| Windows | **QuickJS-NG** | Compiled from `cxx/quickjs/` by `windows/CMakeLists.txt` |
| Linux | **QuickJS-NG** | Compiled from `cxx/quickjs/` by `linux/CMakeLists.txt` |
| iOS | JavaScriptCore | System framework |
| macOS | JavaScriptCore | System framework |

Nothing is prebuilt and nothing is downloaded: the three QuickJS platforms all
compile the same vendored C in `cxx/quickjs/`, alongside the bridge in
`cxx/libfastdev_quickjs_runtime.cpp`. Because Apple platforms run
JavaScriptCore, **the host test suite on macOS never exercises QuickJS at all** —
an engine change that compiles and passes `flutter test` can still be broken on
Android. Verify engine changes on a device or with a native harness.

Currently vendored: **quickjs-ng v0.17.0**.

## Upgrading the engine

1. Run the **Sync QuickJS-NG Source** workflow
   (`.github/workflows/build_quickjs_ng.yml`) with the target tag, e.g.
   `v0.18.0`. It copies every root `.c`/`.h` except upstream's own entrypoints
   and test harnesses into `cxx/quickjs/`, then commits.
   **Update that workflow's `default:` input to the new tag in the same change**,
   or a later default run silently downgrades the engine.
2. Reconcile the source list. Four places name the `.c` files to compile, and a
   sync that adds or removes one breaks all four:
   - `android/CMakeLists.txt`
   - `windows/CMakeLists.txt`
   - `linux/CMakeLists.txt`
   - the "Build QuickJS Test Bridge" step in `.github/workflows/ci.yml`

   The set moves between releases. v0.9.0 built `cutils.c libregexp.c
   libunicode.c libbf.c quickjs.c`; v0.17.0 builds `dtoa.c libregexp.c
   libunicode.c quickjs.c` — `cutils` became header-only, `libbf` was dropped
   (so `-DCONFIG_BIGNUM` no longer selects anything), and `dtoa.c` arrived.
3. Fix the bridge against the new headers. The fastest signal is compiling it
   directly rather than through Gradle:

   ```bash
   cd packages/flutter_js_ng
   defs='-DCONFIG_VERSION="2024-01-01" -DQUICKJS -D_GNU_SOURCE'
   for f in dtoa libregexp libunicode quickjs; do
     clang -c -fPIC -O0 -std=gnu17 -w $defs -Icxx/quickjs -o /tmp/$f.o cxx/quickjs/$f.c
   done
   clang++ -c -fPIC -O0 -std=c++17 $defs -Icxx/quickjs -Icxx \
     -o /tmp/bridge.o cxx/libfastdev_quickjs_runtime.cpp
   ```

   The v0.9.0 → v0.17.0 jump needed exactly one change: `JS_IsError` lost its
   `JSContext*`.
4. **Check the tag enum**, which is where this bites silently. `lib/quickjs/ffi.dart`
   (`JSTag`) and `lib/quickjs/qjs_typedefs.dart` (`JS_TAG_*`) both mirror the
   `JS_TAG_*` enum in `cxx/quickjs/quickjs.h`, and a stale copy does not crash —
   it returns the wrong Dart type. v0.17.0 moved `FLOAT64` from 7 to 8 (7 is now
   `SHORT_BIG_INT`) and added `STRING_ROPE` at -6; both files had been carrying
   Bellard's original layout, which quickjs-ng never used. A rope is a string,
   so every `case JS_TAG_STRING` needs `JS_TAG_STRING_ROPE` beside it.
5. **Expect every cached `.qbc` to be invalid.** QuickJS bytecode is
   version-stamped, so after an engine upgrade existing caches fail with
   `SyntaxError: invalid version (N expected=M)`.
   `JsBasedProvider` handles this by deleting the unusable file and recompiling
   from source, costing one slow load. If you change that caching, keep the
   fallback.
6. Verify on a device, not just on the host. Build the Android app, run it, and
   confirm plugins report `Loaded script for ...` on first launch and
   `Loaded bytecode for ...` on the second.

## Checking alignment

`android/CMakeLists.txt` passes `-Wl,-z,max-page-size=16384` so the library
loads on 16 KB page-size devices. After any change, confirm with:

```bash
$ANDROID_HOME/ndk/<version>/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-objdump -p \
  build/app/intermediates/merged_native_libs/debug/out/lib/arm64-v8a/libfastdev_quickjs_runtime.so \
  | grep LOAD
```

Every LOAD segment must report `align 2**14` or higher.
