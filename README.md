# Resource Finder iOS

Native SwiftUI + AVFoundation app for iOS 17 and later. Ten catalog adapters, source-scoped library/history, download-only MP4/HLS and offline playback.

0.4 adds the Android-style single-layer player, lock, temporary long-press speed, seek/brightness/volume gestures, persistent speed, in-player episode/line selection, header-aware media relays and DLNA SOAP control. See [feature acceptance contract](resource_finder_ios/FEATURE_PARITY.md) for behavior and platform differences. Automated acceptance passed **61 tests** (15 portable, 38 native, 8 UI) in [run 14](https://github.com/bonjourdrs/resource-finder-ios/actions/runs/40890416787), using app source `a33d021065c4189dffe49912e75df96e42624248`. Native tests ran on an iPhone 16 Pro simulator with iOS 18.5 / Xcode 16.4.

[Build workflow](https://github.com/bonjourdrs/resource-finder-ios/actions/workflows/build-resource-finder-ios.yml) packages a genuine arm64 iPhoneOS archive as **Resource-Finder-iOS-0.4.0-Unsigned.ipa**, with a SHA-256 checksum. This package requires signing/provisioning before installation. The simulator app is a separate ZIP.

No Apple signing credentials are configured. SSDP auto-discovery on physical iOS requires Apple's approved multicast entitlement; manual device-description URL addition uses unicast. An iOS HTTP relay needs the app in the foreground. These are explicit platform constraints, not features silently reported as complete. Physical iPhone and household-TV acceptance remain after signing.

[Windows signing and iPhone installation](INSTALL_CN.md) explains the required step after an unsigned build.

[App documentation](resource_finder_ios/README.md) describes build and transport behavior. Catalog and descriptor probes do not prove full-movie playback.

Verified 0.4 device package: 4,192,546 bytes; SHA-256 `d2ecd11b4fbd3ec992b57913944657eccb3c79efd4f273c8b42f16bcd990d5c2`. Its plist and Mach-O identify iPhoneOS arm64 / minimum iOS 17; no code signature or provisioning profile is present. Automated acceptance includes origin-stopped HLS/AES decoding, local TV media relay, download-only/relaunch/offline playback, real long-press duration, double-tap pause, lock/unlock and line matching. This remains an unsigned development package.
