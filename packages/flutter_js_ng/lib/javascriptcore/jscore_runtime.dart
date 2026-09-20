import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:ffi/ffi.dart';
import '../javascript_runtime.dart';
import './binding/js_object_ref.dart' as jsObject;
import './flutter_jscore.dart';
import './jscore_bindings.dart';
import '../js_eval_result.dart';

class JavascriptCoreRuntime extends JavascriptRuntime {
  late Pointer _contextGroup;
  late Pointer _globalContext;
  late JSContext context;
  late Pointer _globalObject;

  @override
  int executePendingJob() {
    evaluate('(function(){})();');
    return 0;
  }

  String? onMessageFunctionName;
  String? sendMessageFunctionName;

  JavascriptCoreRuntime() {
    _contextGroup = jSContextGroupCreate();
    _globalContext = jSGlobalContextCreateInGroup(_contextGroup, nullptr);
    _globalObject = jSContextGetGlobalObject(_globalContext);

    context = JSContext(_globalContext);

    _runtimesByContext[_globalContext.address] = this;

    final Pointer<Utf8> funcNameCString = 'sendMessage'.toNativeUtf8();
    final functionObject = jSObjectMakeFunctionWithCallback(
        _globalContext,
        jSStringCreateWithUTF8CString(funcNameCString),
        Pointer.fromFunction(sendMessageBridgeFunction));
    jSObjectSetProperty(
        _globalContext,
        _globalObject,
        jSStringCreateWithUTF8CString(funcNameCString),
        functionObject,
        jsObject.JSPropertyAttributes.kJSPropertyAttributeNone,
        nullptr);
    calloc.free(funcNameCString);

    init();
  }

  @override
  void initChannelFunctions() {
    JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()] = {};
  }

  @override
  JsEvalResult evaluate(String js, {String? sourceUrl}) {
    final Pointer<Utf8> scriptCString = js.toNativeUtf8();
    final Pointer<Utf8>? sourceUrlCString = sourceUrl?.toNativeUtf8();

    final JSValuePointer exception = JSValuePointer();
    final jsValueRef = jSEvaluateScript(
        _globalContext,
        jSStringCreateWithUTF8CString(scriptCString),
        nullptr,
        sourceUrlCString != null
            ? jSStringCreateWithUTF8CString(sourceUrlCString)
            : nullptr,
        1,
        exception.pointer);
    calloc.free(scriptCString);
    if (sourceUrlCString != null) {
      calloc.free(sourceUrlCString as Pointer<NativeType>);
    }

    String result;

    final JSValue exceptionValue = exception.getValue(context);
    bool isPromise = false;
    if (exceptionValue.isObject) {
      result =
          'ERROR: ${exceptionValue.toObject().getProperty("message").string} \n  at ${exceptionValue.toObject().getProperty("stack").string}';
    } else {
      result = _getJsValue(jsValueRef);
      final JSValue resultValue = JSValuePointer(jsValueRef).getValue(context);

      isPromise = resultValue.isObject &&
          resultValue.toObject().getProperty('then').isObject &&
          resultValue.toObject().getProperty('catch').isObject;
    }

    return JsEvalResult(
      result,
      exceptionValue.isObject ? exceptionValue.toObject().pointer : jsValueRef,
      isError: result.startsWith('ERROR:'),
      isPromise: isPromise,
    );
  }

  @override
  void dispose() {
    final address = _globalContext.address;
    // identical(), not a bare remove: JSC recycles freed context addresses
    // aggressively (measured: 400 create/dispose cycles reused just 32
    // addresses), so `dispose -> create -> dispose the first one again` would
    // otherwise evict the live runtime that inherited the address.
    //
    // This guards the MAP only. A literal double dispose() still segfaults two
    // lines below, on jSGlobalContextRelease of a freed pointer - pre-existing,
    // and what would actually fix it is a `bool _disposed` early return.
    if (identical(_runtimesByContext[address], this)) {
      _runtimesByContext.remove(address);
    }
    jSGlobalContextRelease(_globalContext);
    jSContextGroupRelease(_contextGroup);
  }

  @override
  String getEngineInstanceId() => hashCode.abs().toString();

  /// Works only for iOS & MacOS.
  @override
  void setInspectable(bool inspectable) {
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        context.setInspectable(inspectable);
      } on Error {
        debugPrint('Could not set inspectable to $inspectable');
      }
    }
  }

  @override
  bool setupBridge(String channelName, Function(dynamic args) fn) {
    final channelFunctionCallbacks =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    if (channelFunctionCallbacks.keys.contains(channelName)) return false;

    channelFunctionCallbacks[channelName] = fn;

    return true;
  }

  static Pointer sendMessageBridgeFunction(
      Pointer ctx,
      Pointer function,
      Pointer thisObject,
      int argumentCount,
      Pointer<Pointer> arguments,
      Pointer<Pointer> exception) {
    final runtime = _runtimesByContext[ctx.address];
    // No entry means the context was already disposed; JS sees undefined,
    // which is what an unregistered channel has always produced.
    if (runtime == null) return nullptr;
    return runtime._sendMessage(
        ctx, function, thisObject, argumentCount, arguments, exception);
  }

  String _getJsValue(Pointer jsValueRef) {
    if (jSValueIsNull(_globalContext, jsValueRef) == 1) {
      return 'null';
    } else if (jSValueIsUndefined(_globalContext, jsValueRef) == 1) {
      return 'undefined';
    }
    final resultJsString =
        jSValueToStringCopy(_globalContext, jsValueRef, nullptr);
    final resultCString = jSStringGetCharactersPtr(resultJsString);
    final int resultCStringLength = jSStringGetLength(resultJsString);
    if (resultCString == nullptr) {
      return 'null';
    }
    final String result = String.fromCharCodes(Uint16List.view(
        resultCString.cast<Uint16>().asTypedList(resultCStringLength).buffer,
        0,
        resultCStringLength));
    jSStringRelease(resultJsString);
    return result;
  }

  /// Every live runtime in this isolate, keyed by its JSGlobalContextRef.
  ///
  /// This was a single static slot holding the most recently constructed
  /// runtime's handler. Dart statics are per-isolate, so constructing a second
  /// JavaScriptCore runtime in the same isolate silently rebound the first
  /// one's bridge: messages from runtime A were delivered to runtime B's
  /// handlers, and after B was disposed A's next message reached a released
  /// context and took the process down with SIGSEGV. The Nuvio pool runs
  /// several scrapers per isolate, so this was reachable on iOS and macOS with
  /// two scrapers and a close-and-reopen.
  ///
  /// JSC hands the calling context to the trampoline, so route on that.
  ///
  /// This closes the JS->Dart direction only. The Dart->JS direction is still
  /// open: javascript_runtime.dart's SetTimeout handler interpolates a
  /// plugin-supplied index into a script and evaluates it on a Timer that
  /// dispose() never cancels, so after enough runtimes the freed address is
  /// reused and that script runs inside a different plugin's live realm.
  static final Map<int, JavascriptCoreRuntime> _runtimesByContext = {};

  Pointer _sendMessage(
      Pointer ctx,
      Pointer function,
      Pointer thisObject,
      int argumentCount,
      Pointer<Pointer> arguments,
      Pointer<Pointer> exception) {
    final channelFunctions =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    final String channelName = _getJsValue(arguments[0]);
    final String message = _getJsValue(arguments[1]);

    if (channelFunctions.containsKey(channelName)) {
      final result = channelFunctions[channelName]!.call(jsonDecode(message));
      try {
        if (result is Future) {
          return _constructPromiseFor(result);
        }
        final encoded = json.encode(result);
        return JSValue.makeFromJSONString(context, encoded).pointer;
      } catch (err) {
        debugPrint(
            'Could not encode return value of message on channel $channelName to json... returning null');
      }
    } else {
      debugPrint('No channel $channelName registered');
    }

    return nullptr;
  }

  Pointer<NativeType> _constructPromiseFor(Future future) {
    final id = future.hashCode;
    final Pointer<Utf8> scriptCString = ('var __JSC_promise_result$id = {};'
            'new Promise(function(resolve, reject) { __JSC_promise_result$id.resolve = resolve;'
            ' __JSC_promise_result$id.reject = reject;});')
        .toNativeUtf8();

    final jsValueRef = jSEvaluateScript(
        _globalContext,
        jSStringCreateWithUTF8CString(scriptCString),
        nullptr,
        nullptr,
        1,
        nullptr);
    calloc.free(scriptCString);

    future.then((value) {
      final encoded = json.encode(value);
      evaluate(
          '__JSC_promise_result$id.resolve($encoded); __JSC_promise_result$id = null;');
    }).catchError((error) {
      evaluate(
          '__JSC_promise_result$id.reject("$error"); __JSC_promise_result$id = null;');
    });
    return jsValueRef;
  }

  @override
  JsEvalResult callFunction(Pointer<NativeType>? fn, Pointer<NativeType>? obj) {
    final JSValue fnValue = JSValuePointer(fn).getValue(context);
    final JSObject functionObj = fnValue.toObject();
    final JSValuePointer exception = JSValuePointer();
    final JSValue result = functionObj.callAsFunction(
      functionObj,
      JSValuePointer(obj),
      exception: exception,
    );
    final JSValue exceptionValue = exception.getValue(context);
    bool isPromise = false;

    if (exceptionValue.isObject) {
      throw Exception(
          'ERROR: ${exceptionValue.toObject().getProperty("message").string}');
    } else {
      isPromise = result.isObject &&
          result.toObject().getProperty('then').isObject &&
          result.toObject().getProperty('catch').isObject;
    }

    return JsEvalResult(
      _getJsValue(result.pointer),
      exceptionValue.isObject
          ? exceptionValue.toObject().pointer
          : result.pointer,
      isPromise: isPromise,
    );
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    if (jSValueIsNull(_globalContext, jsValue.rawResult) == 1) {
      return null;
    } else if (jSValueIsString(_globalContext, jsValue.rawResult) == 1) {
      return _getJsValue(jsValue.rawResult) as T;
    } else if (jSValueIsBoolean(_globalContext, jsValue.rawResult) == 1) {
      return (_getJsValue(jsValue.rawResult) == "true") as T;
    } else if (jSValueIsNumber(_globalContext, jsValue.rawResult) == 1) {
      final String valueString = _getJsValue(jsValue.rawResult);

      if (valueString.contains(".")) {
        try {
          return double.parse(valueString) as T;
        } on TypeError {
          debugPrint('Failed to cast $valueString... returning null');
          return null;
        }
      } else {
        try {
          return int.parse(valueString) as T;
        } on TypeError {
          debugPrint('Failed to cast $valueString... returning null');
          return null;
        }
      }
    } else if (jSValueIsObject(_globalContext, jsValue.rawResult) == 1 ||
        jSValueIsArray(_globalContext, jsValue.rawResult) == 1) {
      final JSValue objValue =
          JSValuePointer(jsValue.rawResult).getValue(context);
      final String serialized = objValue.createJSONString().string!;
      return jsonDecode(serialized);
    } else {
      return null;
    }
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    final JSValue objValue =
        JSValuePointer(jsValue.rawResult).getValue(context);
    return objValue.createJSONString().string!;
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return Future.value(evaluate(code, sourceUrl: sourceUrl));
  }
}
