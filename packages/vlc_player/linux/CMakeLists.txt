# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "vlc_player")
project(${PROJECT_NAME} LANGUAGES CXX)

find_package(PkgConfig REQUIRED)
# Capped, unlike every other platform's libVLC: Windows downloads a pinned
# 3.0.23 runtime and Apple gets 3.0.23 through VLCKit, but Linux takes whatever
# the distro ships. Uncapped, that happily configures against libvlc 4.x, whose
# C API the vendored libvlcpp headers in ../third_party do not match - and the
# failure surfaces as a wall of template errors, not a version complaint.
#
# Upper bound only, deliberately. A >=3.0.20 floor was tried and reverted: no
# native source here requires it (nothing under src/ or third_party/ changed),
# and it silently costs users. Ubuntu 22.04 LTS ships libvlc 3.0.16, so a floor
# breaks `flutter build linux` from source there, and it also forces the arm64
# release runner off 22.04 - which raises the shipped binary's glibc floor from
# 2.35 to 2.39 and strands arm64 users on 22.04 and Debian 12. Add a floor only
# with the specific API that needs it named here.
pkg_check_modules(LIBVLC REQUIRED IMPORTED_TARGET "libvlc<4.0.0")

# This value is used when generating builds using this plugin, so it must
# not be changed.
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
  "vlc_player_plugin.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})
# vlc_player_core.cc calls std::clamp, so state the C++17 requirement here
# rather than inheriting it from whatever floor the embedding app happens to
# set in apply_standard_settings.
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_17)

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
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/native"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libvlcpp")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::LIBVLC)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(vlc_player_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# These unit tests can be run from a terminal after building the example.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (${include_${PROJECT_NAME}_tests})
if(${CMAKE_VERSION} VERSION_LESS "3.11.0")
message("Unit tests require CMake 3.11.0 or later")
else()
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/release-1.11.0.zip
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)

FetchContent_MakeAvailable(googletest)

# The plugin's exported API is not very useful for unit testing, so build the
# sources directly into the test binary rather than using the shared library.
add_executable(${TEST_RUNNER}
  test/vlc_player_plugin_test.cc
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
# The test runner compiles ${PLUGIN_SOURCES} directly, so it needs C++17 too.
target_compile_features(${TEST_RUNNER} PRIVATE cxx_std_17)
target_compile_definitions(${TEST_RUNNER} PRIVATE VLC_PLAYER_TESTING)
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(${TEST_RUNNER} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/native"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libvlcpp")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter)
target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::GTK)
target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::LIBVLC)
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})

endif()  # CMake version check
endif()  # include_${PROJECT_NAME}_tests
