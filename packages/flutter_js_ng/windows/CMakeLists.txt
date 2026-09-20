cmake_minimum_required(VERSION 3.15)

# The CMake target must be named <pub package name>_plugin: Flutter's generated
# windows/flutter/generated_plugins.cmake iterates FLUTTER_PLUGIN_LIST (which now
# carries "flutter_js_ng", from this package's pubspec `name:`) and references
# ${plugin}_plugin, including inside $<TARGET_FILE:...>. A generator expression
# naming a target that does not exist is a fatal configure-time error, so a
# mismatch here does not fail late - no Windows build configures at all.
#
# OUTPUT_NAME deliberately keeps the produced library called flutter_js_plugin.
# The target name is internal to the build; the FILE name is a runtime contract,
# dlopen'd by literal string from lib/quickjs/ffi.dart and quickjs_runtime.dart.
# Pinning it means this fix changes only the build graph and leaves the shipped
# runtime behaviour byte-identical. Rename it (and those Dart call sites) in one
# go later if the inconsistency grates - but do it on a machine that can build
# Windows, because nothing in the test suite would catch a dlopen name mismatch.
set(PROJECT_NAME "flutter_js_ng")
project(${PROJECT_NAME} LANGUAGES CXX C)
add_compile_options("$<$<CXX_COMPILER_ID:MSVC>:/utf-8>")

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_js_ng_plugin")

set(QUICKJS_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../cxx")
add_definitions(-DCONFIG_VERSION="2024-01-01" -DQUICKJS -D_GNU_SOURCE)

add_library(${PLUGIN_NAME} SHARED
  "flutter_js_plugin.cpp"
  "${QUICKJS_SRC_DIR}/quickjs/dtoa.c"
  "${QUICKJS_SRC_DIR}/quickjs/libregexp.c"
  "${QUICKJS_SRC_DIR}/quickjs/libunicode.c"
  "${QUICKJS_SRC_DIR}/quickjs/quickjs.c"
  "${QUICKJS_SRC_DIR}/libfastdev_quickjs_runtime.cpp"
)
set_target_properties(${PLUGIN_NAME} PROPERTIES OUTPUT_NAME "flutter_js_plugin")

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${QUICKJS_SRC_DIR}/quickjs")

if(MSVC)
    set_target_properties(${PLUGIN_NAME} PROPERTIES C_STANDARD 11)
    target_compile_options(${PLUGIN_NAME} PRIVATE /experimental:c11atomics /WX- /W0)
endif()

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)