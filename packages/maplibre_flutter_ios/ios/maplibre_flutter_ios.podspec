#
# CocoaPods spec for maplibre_flutter_ios — kept in sync with Package.swift so
# both SPM and CocoaPods consumers build (CLAUDE.md §9). Validate with
# `pod lib lint maplibre_flutter_ios.podspec`.
#
# The default iOS renderer: mbgl-core (Metal) → Flutter Texture. It does NOT
# depend on the MapLibre Apple SDK (the native engine ships via
# maplibre_flutter_core), so there is no mbgl symbol duplication.
#
Pod::Spec.new do |s|
  s.name             = 'maplibre_flutter_ios'
  s.version          = '0.0.3'
  s.summary          = 'The default iOS implementation of maplibre_flutter.'
  s.description      = <<-DESC
Native MapLibre vector maps for Flutter on iOS (mbgl-core via Metal + a Flutter Texture).
                       DESC
  s.homepage         = 'https://github.com/Mankeli-Software/maplibre_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mankeli Solutions Oy' => 'contact@mankeli.co' }
  s.source           = { :path => '.' }

  # The Swift sources live under the SPM layout; point CocoaPods at the same
  # files so both build managers compile identical sources.
  s.source_files = 'maplibre_flutter_ios/Sources/maplibre_flutter_ios/**/*'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.9'
end
