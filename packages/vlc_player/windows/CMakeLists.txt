# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "vlc_player")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "vlc_player_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "../src/native/vlc_frame_sink.h"
  "../src/native/vlc_pixel_buffer_sink.cc"
  "../src/native/vlc_pixel_buffer_sink.h"
  "../src/native/vlc_player_core.cc"
  "../src/native/vlc_player_core.h"
  "../src/native/vlc_player_types.h"
  "../src/native/vlc_video_output.cc"
  "../src/native/vlc_video_output.h"
  "vlc_player_plugin.cpp"
  "vlc_player_plugin.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/vlc_player/vlc_player_plugin_c_api.h"
  "vlc_player_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# x86-64 only, and the check has to be on the ARCHITECTURE, not the pointer
# width. CMAKE_SIZEOF_VOID_P is 8 on ARM64 too, so the old pointer-width guard
# passed on an ARM64 host and the build went on to download the win64 (x86-64)
# VLC below and link its x64 sdk/lib/libvlc.lib into an ARM64 DLL - a confusing
# linker failure, or a broken binary, instead of a clear "not supported".
#
# To lift this: VideoLAN publishes no Windows ARM64 VLC build at
# download.videolan.org/pub/videolan/vlc/<ver>/, so an ARM64 libVLC has to
# exist (or be built) before the archive/URL below can be selected by arch.
if(DEFINED CMAKE_GENERATOR_PLATFORM AND CMAKE_GENERATOR_PLATFORM)
  set(VLC_PLAYER_TARGET_ARCH "${CMAKE_GENERATOR_PLATFORM}")
else()
  set(VLC_PLAYER_TARGET_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
endif()
string(TOLOWER "${VLC_PLAYER_TARGET_ARCH}" VLC_PLAYER_TARGET_ARCH)

if(NOT VLC_PLAYER_TARGET_ARCH MATCHES "^(x64|amd64|x86_64)$")
  message(FATAL_ERROR
    "vlc_player supports Windows x64 only; this build targets "
    "'${VLC_PLAYER_TARGET_ARCH}'. No ARM64 libVLC is published upstream, so "
    "the bundled x86-64 VLC runtime cannot be linked into an ARM64 binary.")
endif()

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "vlc_player currently supports Windows x64 builds only.")
endif()

set(VLC_PLAYER_VLC_VERSION "3.0.23")
set(VLC_PLAYER_VLC_ARCHIVE "vlc-${VLC_PLAYER_VLC_VERSION}-win64.7z")
# Mirrors, tried in order. The canonical host is first; the others are here
# because it went down on 2026-09-20 and took every Windows build with it,
# with CMake reporting only `status: [28;"Timeout was reached"]`.
# `get.videolan.org` is VideoLAN's own redirector and load-balances across the
# mirror pool, so it also survives any single mirror disappearing.
#
# Falling back is only safe because EXPECTED_HASH is enforced on every attempt
# below: a mirror serving anything but the exact archive fails the hash and the
# loop moves on. Both alternates were verified to serve bytes matching the
# pinned SHA256 on 2026-09-20.
set(VLC_PLAYER_VLC_URLS
  "https://download.videolan.org/pub/videolan/vlc/${VLC_PLAYER_VLC_VERSION}/win64/${VLC_PLAYER_VLC_ARCHIVE}"
  "https://get.videolan.org/vlc/${VLC_PLAYER_VLC_VERSION}/win64/${VLC_PLAYER_VLC_ARCHIVE}"
  "https://mirror.init7.net/videolan/vlc/${VLC_PLAYER_VLC_VERSION}/win64/${VLC_PLAYER_VLC_ARCHIVE}")
set(VLC_PLAYER_VLC_SHA256
  "eb4fd8a28291da73608c733786a09610fea865fbe94113bcb60b91c1ebb8404a")
set(VLC_PLAYER_VLC_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/vlc")
set(VLC_PLAYER_VLC_ARCHIVE_PATH
  "${VLC_PLAYER_VLC_DOWNLOAD_DIR}/${VLC_PLAYER_VLC_ARCHIVE}")
set(VLC_PLAYER_RUNTIME_DIR
  "${VLC_PLAYER_VLC_DOWNLOAD_DIR}/vlc-${VLC_PLAYER_VLC_VERSION}")

if(NOT EXISTS "${VLC_PLAYER_RUNTIME_DIR}/libvlc.dll" OR
   NOT EXISTS "${VLC_PLAYER_RUNTIME_DIR}/libvlccore.dll" OR
   NOT EXISTS "${VLC_PLAYER_RUNTIME_DIR}/plugins")
  file(MAKE_DIRECTORY "${VLC_PLAYER_VLC_DOWNLOAD_DIR}")
  set(vlc_player_downloaded FALSE)
  set(vlc_player_download_errors "")
  foreach(vlc_player_url IN LISTS VLC_PLAYER_VLC_URLS)
    message(STATUS
      "Downloading VLC ${VLC_PLAYER_VLC_VERSION} Windows runtime from "
      "${vlc_player_url}")
    # Deliberately NOT EXPECTED_HASH: that makes file(DOWNLOAD) raise a fatal
    # error on a mismatch, which aborts the whole configure step and so can
    # never reach the next mirror -- it defeats the point of this loop. The
    # hash is still mandatory, just checked below where a failure is
    # recoverable, so a mirror serving the wrong bytes is rejected exactly as
    # before.
    file(DOWNLOAD
      "${vlc_player_url}"
      "${VLC_PLAYER_VLC_ARCHIVE_PATH}"
      SHOW_PROGRESS
      STATUS vlc_player_download_status
      # Without these, a stalled transfer holds the configure step until the
      # CI runner's own job limit rather than failing over. The ceiling is
      # generous: the archive is ~38 MB and a slow but working mirror must not
      # be abandoned mid-transfer. Neither caps the TCP connect, so a
      # black-holed host still costs the system timeout (~75 s) once.
      INACTIVITY_TIMEOUT 30
      TIMEOUT 600
      TLS_VERIFY ON)
    list(GET vlc_player_download_status 0 vlc_player_download_code)
    list(GET vlc_player_download_status 1 vlc_player_download_message)
    if(vlc_player_download_code EQUAL 0)
      file(SHA256 "${VLC_PLAYER_VLC_ARCHIVE_PATH}" vlc_player_actual_sha256)
      if(vlc_player_actual_sha256 STREQUAL VLC_PLAYER_VLC_SHA256)
        set(vlc_player_downloaded TRUE)
        break()
      endif()
      set(vlc_player_download_message
        "SHA256 mismatch (expected ${VLC_PLAYER_VLC_SHA256}, got ${vlc_player_actual_sha256})")
    endif()
    # A timed-out or hash-mismatched attempt leaves a partial file behind, and
    # the extractor below would otherwise be handed it once the last mirror
    # failed too.
    file(REMOVE "${VLC_PLAYER_VLC_ARCHIVE_PATH}")
    string(APPEND vlc_player_download_errors
      "\n  ${vlc_player_url}: ${vlc_player_download_message}")
  endforeach()
  if(NOT vlc_player_downloaded)
    message(FATAL_ERROR
      "Failed to download the VLC ${VLC_PLAYER_VLC_VERSION} Windows runtime "
      "from any known mirror:${vlc_player_download_errors}")
  endif()

  file(REMOVE_RECURSE "${VLC_PLAYER_RUNTIME_DIR}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "${VLC_PLAYER_VLC_ARCHIVE_PATH}"
    WORKING_DIRECTORY "${VLC_PLAYER_VLC_DOWNLOAD_DIR}"
    RESULT_VARIABLE vlc_player_extract_result)
  if(NOT vlc_player_extract_result EQUAL 0)
    message(FATAL_ERROR
      "Failed to extract VLC Windows runtime from ${VLC_PLAYER_VLC_ARCHIVE_PATH}.")
  endif()
endif()

set(VLC_PLAYER_LIBVLC_MEDIA_HEADER
  "${VLC_PLAYER_RUNTIME_DIR}/sdk/include/vlc/libvlc_media.h")
# libvlc_media.h declares `typedef SSIZE_T ssize_t;` for MSVC and then uses
# ssize_t in libvlc_media_read_cb. MSVC has no ssize_t of its own, so the
# typedef has to survive, but it also has to not collide with another header
# that has already made one. Guarding it on _SSIZE_T_DEFINED - the macro MinGW
# and the CRT use for exactly this - gives both.
#
# Gating it on a compiler version instead does not: on VS2015 and later the
# typedef disappears, nothing else supplies ssize_t, and every use becomes
# C4431 "missing type specifier", which /WX turns into a build failure.
if(EXISTS "${VLC_PLAYER_LIBVLC_MEDIA_HEADER}")
  file(READ "${VLC_PLAYER_LIBVLC_MEDIA_HEADER}" vlc_player_libvlc_media)
  set(vlc_player_libvlc_media_patched "${vlc_player_libvlc_media}")
  string(REPLACE
    "#if _MSC_VER < 1900\ntypedef SSIZE_T ssize_t;\n#endif"
    "typedef SSIZE_T ssize_t;"
    vlc_player_libvlc_media_patched
    "${vlc_player_libvlc_media_patched}")
  string(REPLACE
    "#ifndef _SSIZE_T_DEFINED\n#define _SSIZE_T_DEFINED\ntypedef SSIZE_T ssize_t;\n#endif"
    "typedef SSIZE_T ssize_t;"
    vlc_player_libvlc_media_patched
    "${vlc_player_libvlc_media_patched}")
  string(REPLACE
    "typedef SSIZE_T ssize_t;"
    "#ifndef _SSIZE_T_DEFINED\n#define _SSIZE_T_DEFINED\ntypedef SSIZE_T ssize_t;\n#endif"
    vlc_player_libvlc_media_patched
    "${vlc_player_libvlc_media_patched}")
  if(NOT vlc_player_libvlc_media STREQUAL vlc_player_libvlc_media_patched)
    file(WRITE "${VLC_PLAYER_LIBVLC_MEDIA_HEADER}"
      "${vlc_player_libvlc_media_patched}")
  endif()
endif()

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(vlc_player_bundled_libraries
  ""
  PARENT_SCOPE
)
if(EXISTS "${VLC_PLAYER_RUNTIME_DIR}/libvlc.dll" AND
   EXISTS "${VLC_PLAYER_RUNTIME_DIR}/libvlccore.dll" AND
   EXISTS "${VLC_PLAYER_RUNTIME_DIR}/plugins" AND
   EXISTS "${VLC_PLAYER_RUNTIME_DIR}/sdk/include/vlc/vlc.h" AND
   EXISTS "${VLC_PLAYER_RUNTIME_DIR}/sdk/lib/libvlc.lib")
  target_include_directories(${PLUGIN_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/native"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libvlcpp"
    "${VLC_PLAYER_RUNTIME_DIR}/sdk/include")
  target_link_libraries(${PLUGIN_NAME} PRIVATE
    "${VLC_PLAYER_RUNTIME_DIR}/sdk/lib/libvlc.lib")

  file(GLOB VLC_PLAYER_RUNTIME_DLLS "${VLC_PLAYER_RUNTIME_DIR}/*.dll")
  set(vlc_player_bundled_libraries
    ${VLC_PLAYER_RUNTIME_DLLS}
    PARENT_SCOPE
  )

  if(DEFINED BINARY_NAME)
    foreach(vlc_player_runtime_directory hrtfs locale lua plugins skins)
      if(EXISTS "${VLC_PLAYER_RUNTIME_DIR}/${vlc_player_runtime_directory}")
        add_custom_target(
          ${PLUGIN_NAME}_copy_${vlc_player_runtime_directory} ALL
          COMMAND "${CMAKE_COMMAND}" -E copy_directory
          "${VLC_PLAYER_RUNTIME_DIR}/${vlc_player_runtime_directory}"
          "$<TARGET_FILE_DIR:${BINARY_NAME}>/${vlc_player_runtime_directory}")
      endif()
    endforeach()
  endif()
else()
  message(FATAL_ERROR
    "Incomplete downloaded VLC Windows runtime in ${VLC_PLAYER_RUNTIME_DIR}. "
    "Expected libvlc.dll, libvlccore.dll, plugins/, sdk/include, and "
    "sdk/lib/libvlc.lib.")
endif()

# === Tests ===
# These unit tests can be run from a terminal after building the example, or
# from Visual Studio after opening the generated solution file.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (${include_${PROJECT_NAME}_tests})
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.17.0.zip
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# The plugin's C API is not very useful for unit testing, so build the sources
# directly into the test binary rather than using the DLL.
add_executable(${TEST_RUNNER}
  test/vlc_player_plugin_test.cpp
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_compile_definitions(${TEST_RUNNER} PRIVATE VLC_PLAYER_TESTING)
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(${TEST_RUNNER} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/native"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libvlcpp"
  "${VLC_PLAYER_RUNTIME_DIR}/sdk/include")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${TEST_RUNNER} PRIVATE
  "${VLC_PLAYER_RUNTIME_DIR}/sdk/lib/libvlc.lib")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)
# flutter_wrapper_plugin has link dependencies on the Flutter DLL.
add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_LIBRARY}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
)
foreach(vlc_player_runtime_dll ${VLC_PLAYER_RUNTIME_DLLS})
  add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${vlc_player_runtime_dll}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
  )
endforeach()
foreach(vlc_player_runtime_directory hrtfs locale lua plugins skins)
  if(EXISTS "${VLC_PLAYER_RUNTIME_DIR}/${vlc_player_runtime_directory}")
    add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_directory
      "${VLC_PLAYER_RUNTIME_DIR}/${vlc_player_runtime_directory}"
      "$<TARGET_FILE_DIR:${TEST_RUNNER}>/${vlc_player_runtime_directory}")
  endif()
endforeach()

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
