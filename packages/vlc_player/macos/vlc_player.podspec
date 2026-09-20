#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vlc_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vlc_player'
  s.version          = '2.1.3'
  s.summary          = 'A macOS Flutter plugin for video playback using VLCKit.'
  s.description      = <<-DESC
A macOS Flutter plugin for video playback using VideoLAN VLCKit.
                       DESC
  s.homepage         = 'https://github.com/lingjhf/vlc_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'lingjhf' => 'lingjhf@users.noreply.github.com' }

  s.source           = { :path => '.' }
  # The renderer and VlcSharedSources.cc are symlinks into ../darwin, the one
  # copy both Darwin pods compile. They have to appear here as files because
  # CocoaPods only globs inside the pod root: `../darwin/**` matches nothing,
  # and `../src/native/*.cc` is why VlcSharedSources.cc exists at all. Only the
  # parts VLCKit does not already provide are pulled in - vlc_player_core.cc
  # owns a libvlc instance of its own, and here VLCKit owns the media player.
  s.source_files = 'vlc_player/Sources/vlc_player/**/*.{swift,h,mm,cc}'
  # Only the Objective-C renderer belongs in the generated umbrella header;
  # that umbrella is compiled as Objective-C, and the shared headers are C++.
  s.public_header_files = 'vlc_player/Sources/vlc_player/VlcTextureRenderer.h'
  s.resource_bundles = {'vlc_player_privacy' => ['vlc_player/Sources/vlc_player/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'
  s.dependency 'VLCKit', '3.7.3'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # VLCKit ships the libvlc C headers under its framework's Headers/vlc, so
    # `#include <vlc/vlc.h>` resolves exactly as it does on Windows and Linux.
    # Both spellings are listed because CocoaPods builds against the extracted
    # slice while the checked-in xcframework keeps its own copy.
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src/native"',
      '"$(PODS_XCFRAMEWORKS_BUILD_DIR)/VLCKit/VLCKit.framework/Headers"',
      '"$(PODS_ROOT)/VLCKit/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Headers"',
    ].join(' '),
  }
  s.script_phase = {
    :name => 'Patch VLCKit runtime path',
    :execution_position => :after_compile,
    :always_out_of_date => '1',
    :input_files => [
      '${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}/${PRODUCT_NAME}.framework/Versions/A/${PRODUCT_NAME}',
    ],
    :output_files => [
      '${DERIVED_FILE_DIR}/${CONFIGURATION}_vlc_player_patch_vlckit_runtime_path.stamp',
    ],
    :script => <<-SCRIPT
set -e

find "${BUILT_PRODUCTS_DIR}" -path "*/${PRODUCT_NAME}.framework/Versions/A/${PRODUCT_NAME}" -type f | while IFS= read -r FRAMEWORK_BINARY; do
  install_name_tool -change "@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit" "@executable_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit" "$FRAMEWORK_BINARY" || true
done
touch "${DERIVED_FILE_DIR}/${CONFIGURATION}_vlc_player_patch_vlckit_runtime_path.stamp"
    SCRIPT
  }
  s.swift_version = '5.0'
end
