#
# CocoaPods spec for maplibre_flutter_macos — kept in sync with Package.swift so
# both SPM and CocoaPods consumers build (CLAUDE.md §9). Validate with
# `pod lib lint maplibre_flutter_macos.podspec`.
#
Pod::Spec.new do |s|
  s.name             = 'maplibre_flutter_macos'
  s.version          = '0.0.2'
  s.summary          = 'The macOS implementation of maplibre_flutter.'
  s.description      = <<-DESC
Native MapLibre vector maps for Flutter on macOS (mbgl-core via
maplibre_flutter_core, composited through a Metal external texture).
                       DESC
  s.homepage         = 'https://github.com/Mankeli-Software/maplibre_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mankeli Solutions Oy' => 'contact@mankeli.co' }
  s.source           = { :path => '.' }

  # Same Swift sources as the SPM layout so both build managers compile identical
  # files. No MapLibre dependency — macOS uses maplibre_flutter_core (CLAUDE.md §9).
  s.source_files = 'maplibre_flutter_macos/Sources/maplibre_flutter_macos/**/*'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.9'
end
