#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_torrent_server.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_torrent_server'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.vendored_frameworks = 'TorrServer.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # The manifest was tracked but never bundled, so it shipped in nothing.
  #
  # Its contents are still the template default - every array empty, i.e. "this
  # plugin touches no required-reason API". Confirm that before an App Store
  # submission: the embedded server stats and writes files under Application
  # Support, which is the NSPrivacyAccessedAPICategoryFileTimestamp /
  # DiskSpace territory, and an inaccurate declaration is itself a rejection.
  # https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'flutter_torrent_server_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
