import 'dart:ffi';

import 'package:flutter_js_ng/quickjs/utf8_null_terminated.dart';

final class JSContext extends Struct {
  @Uint8()
  external int char;
}

final class JSRuntime extends Struct {
  @Uint8()
  external int char;
}

final class JSValueConst extends Struct {
  @Uint8()
  external int char;
}

const int JS_EVAL_TYPE_GLOBAL = 0;
const int JS_EVAL_TYPE_MODULE = 1;
const int JS_EVAL_TYPE_DIRECT = 2;
const int JS_EVAL_TYPE_INDIRECT = 3;

enum QuickJSTypeModule {
  JS_EVAL_TYPE_GLOBAL,
  JS_EVAL_TYPE_MODULE,
  JS_EVAL_TYPE_DIRECT,
  JS_EVAL_TYPE_INDIRECT
}

// Mirrors the JS_TAG_* enum in cxx/quickjs/quickjs.h - see the note on JSTag
// in ffi.dart. Kept in both spellings because both are used across this
// package; they must move together.
const JS_TAG_FIRST = -9,
    /* first negative tag */
    JS_TAG_BIG_INT = -9,
    JS_TAG_SYMBOL = -8,
    JS_TAG_STRING = -7,
    JS_TAG_STRING_ROPE = -6,
    JS_TAG_OBJECT = -1,
    JS_TAG_INT = 0,
    JS_TAG_BOOL = 1,
    JS_TAG_NULL = 2,
    JS_TAG_UNDEFINED = 3,
    JS_TAG_UNINITIALIZED = 4,
    JS_TAG_CATCH_OFFSET = 5,
    JS_TAG_EXCEPTION = 6,
    JS_TAG_SHORT_BIG_INT = 7,
    JS_TAG_FLOAT64 = 8;

// ignore: camel_case_types
typedef JS_NewRuntimeDartBridge = Pointer<JSRuntime> Function();

typedef ChannelCallback = Pointer<JSValueConst> Function(
  Pointer<JSContext>,
  Pointer<Utf8NullTerminated>,
  Pointer<Utf8NullTerminated>,
);

// ignore: camel_case_types
typedef JS_NewContextFn = Pointer<JSContext> Function(
  Pointer<JSRuntime>? jrt,
  Pointer<NativeFunction<ChannelCallback>>? fnConsoleLog,
  Pointer<NativeFunction<ChannelCallback>>? fnSetTimeout,
  Pointer<NativeFunction<ChannelCallback>>? fnSendNative,
);

typedef JSEvalWrapper = Pointer Function(
    Pointer<JSContext> ctx,
    Pointer<Utf8NullTerminated> input,
    int inputLength,
    Pointer<Utf8NullTerminated> filename,
    int evalFlags,
    Pointer<Int32> errors,
    Pointer<JSValueConst> result,
    Pointer<Pointer<Utf8NullTerminated>> stringResult);

// ignore: camel_case_types
typedef JS_GetNullValue = Pointer Function(
  Pointer<JSContext> ctx,
  Pointer<JSValueConst> v,
);

typedef JSEvalWrapperNative = Pointer Function(
    Pointer<JSContext> ctx,
    Pointer<Utf8NullTerminated> input,
    Int32 inputLength,
    Pointer<Utf8NullTerminated> filename,
    Int32 evalFlags,
    Pointer<Int32> errors,
    Pointer<JSValueConst> result,
    Pointer<Pointer<Utf8NullTerminated>> stringResult);

typedef JSExecutePendingJob = int Function(
  Pointer<JSRuntime> rt,
  Pointer<JSContext> ctx,
);

typedef JSExecutePendingJobNative = Uint32 Function(
  Pointer<JSRuntime> rt,
  Pointer<JSContext> ctx,
);

typedef JSCallFunction1ArgNative = Uint32 Function(
  Pointer<JSContext> ctx,
  Pointer<JSValueConst> function,
  Pointer<JSValueConst> object,
  Pointer<JSValueConst> result,
  Pointer<Pointer<Utf8NullTerminated>> stringResult,
);

typedef JSCallFunction1Arg = int Function(
  Pointer<JSContext> ctx,
  Pointer<JSValueConst> function,
  Pointer<JSValueConst> object,
  Pointer<JSValueConst> result,
  Pointer<Pointer<Utf8NullTerminated>> stringResult,
);

typedef JSGetTypeTagNative = Int32 Function(Pointer<JSValueConst> jsValue);
typedef JSGetTypeTag = int Function(Pointer<JSValueConst> jsValue);

typedef JSIsArrayNative = Int32 Function(
    Pointer<JSContext> ctx, Pointer<JSValueConst> jsValue);
typedef JSIsArray = int Function(
    Pointer<JSContext> ctx, Pointer<JSValueConst> jsValue);

typedef JSJSONStringify = int Function(
  Pointer<JSContext> ctx,
  Pointer<JSValueConst> obj,
  Pointer<JSValueConst> res,
  Pointer<Pointer<Utf8NullTerminated>> stringResult,
);
typedef JSJSONStringifyNative = Int32 Function(
  Pointer<JSContext> ctx,
  Pointer<JSValueConst> obj,
  Pointer<JSValueConst> res,
  Pointer<Pointer<Utf8NullTerminated>> stringResult,
);
