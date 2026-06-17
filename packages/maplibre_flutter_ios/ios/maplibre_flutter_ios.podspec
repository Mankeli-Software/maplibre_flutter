#
# CocoaPods spec for maplibre_flutter_ios — kept in sync with Package.swift so
# both SPM and CocoaPods consumers build (CLAUDE.md §9). Validate with
# `pod lib lint maplibre_flutter_ios.podspec`.
#
Pod::Spec.new do |s|
  s.name             = 'maplibre_flutter_ios'
  s.version          = '0.0.2'
  s.summary          = 'The iOS implementation of maplibre_flutter.'
  s.description      = <<-DESC
Native MapLibre vector maps for Flutter on iOS (MapLibre Apple SDK, UiKitView).
                       DESC
  s.homepage         = 'https://github.com/Mankeli-Software/maplibre_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mankeli Solutions Oy' => 'contact@mankeli.co' }
  s.source           = { :path => '.' }

  # The Swift sources live under the SPM layout; point CocoaPods at the same
  # files so both build managers compile identical sources. (swiftgen's
  # ObjCCompatibleSwiftFileInput emits no ObjC glue, so there is no .m here.)
  s.source_files = 'maplibre_flutter_ios/Sources/maplibre_flutter_ios/**/*'

  s.dependency 'Flutter'
  s.dependency 'MapLibre', '~> 6.27'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.9'
end
