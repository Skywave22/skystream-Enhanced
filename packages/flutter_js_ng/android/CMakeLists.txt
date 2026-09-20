cmake_minimum_required(VERSION 3.6.0)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -DANDROID_STL=c++_static -DANDROID_TOOLCHAIN=clang -DDEBUGGER_SERVER_PORT=${DEBUGGER_SERVER_PORT}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DQUICKJS")
# Align LOAD segments to 16 KB so the library loads on 16 KB page-size devices
# (Android 15+). The app now pins NDK r29, which defaults to 16 KB, but this
# stays explicit: r27 and earlier default to 4 KB, a single 4 KB-aligned library
# puts the whole app into page-size compatibility mode, and this package is also
# built standalone by its own example app. A plain linker flag rather than
# target_link_options, which needs CMake 3.13 and this file declares 3.6.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
include_directories(
    ../cxx/quickjs
)
add_library( fastdev_quickjs_runtime

             # Sets the library as a shared library.
             SHARED

             # Provides a relative path to your source file(s).
             ../cxx/libfastdev_quickjs_runtime.cpp

            # dtoa.c is new in quickjs-ng v0.10+; cutils.c and libbf.c are gone
            # (cutils is header-only now, and the bignum code moved into quickjs.c).
            ../cxx/quickjs/dtoa.c
            ../cxx/quickjs/libregexp.c
            ../cxx/quickjs/libunicode.c
            ../cxx/quickjs/quickjs.c
    )

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DCONFIG_VERSION=\\\"2020-11-08\\\"")

find_library(log-lib log)
target_link_libraries(fastdev_quickjs_runtime ${log-lib})