cmake_minimum_required(VERSION 3.6.0)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -DANDROID_STL=c++_static -DANDROID_TOOLCHAIN=clang -DDEBUGGER_SERVER_PORT=${DEBUGGER_SERVER_PORT}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DQUICKJS")
# Align LOAD segments to 16 KB so the library loads on 16 KB page-size devices
# (Android 15+). NDK r27, which the app builds with, still defaults to 4 KB, and
# a single 4 KB-aligned library puts the whole app into page-size compatibility
# mode. A plain linker flag rather than target_link_options, which needs CMake
# 3.13 and this file declares 3.6.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
include_directories(
    ../cxx/quickjs
)
add_library( fastdev_quickjs_runtime

             # Sets the library as a shared library.
             SHARED

             # Provides a relative path to your source file(s).
             ../cxx/libfastdev_quickjs_runtime.cpp

            ../cxx/quickjs/cutils.c
            ../cxx/quickjs/libregexp.c
            ../cxx/quickjs/libunicode.c
            ../cxx/quickjs/libbf.c
            ../cxx/quickjs/quickjs.c
    )

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DCONFIG_VERSION=\\\"2020-11-08\\\"")

find_library(log-lib log)
target_link_libraries(fastdev_quickjs_runtime ${log-lib})