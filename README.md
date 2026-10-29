# Resource Finder iOS

Native SwiftUI + AVFoundation app for iOS 17 and later. Ten catalog adapters, source-scoped library/history, download-only MP4/HLS and offline playback.

0.4 adds the Android-style single-layer player, lock, temporary long-press speed, seek/brightness/volume gestures, persistent speed, in-player episode/line selection, header-aware media relays and DLNA SOAP control. See [feature acceptance contract](resource_finder_ios/FEATURE_PARITY.md) for behavior and platform differences. CI acceptance for 0.4 is in progress.

[Build workflow](https://github.com/bonjourdrs/resource-finder-ios/actions/workflows/build-resource-finder-ios.yml) packages a genuine arm64 iPhoneOS archive as **Resource-Finder-iOS-0.4.0-Unsigned.ipa**, with a SHA-256 checksum. This package requires signing/provisioning before installation. The simulator app is a separate ZIP.

No Apple signing credentials are configured. SSDP auto-discovery on physical iOS requires Apple's approved multicast entitlement; manual device-description URL addition uses unicast. An iOS HTTP relay needs the app in the foreground. These are explicit platform constraints, not features silently reported as complete. Physical iPhone and household-TV acceptance remain after signing.

[Windows signing and iPhone installation](INSTALL_CN.md) explains the required step after an unsigned build.

[App documentation](resource_finder_ios/README.md) describes build and transport behavior. The prior 0.3 baseline passed 45 tests in [run 3](https://github.com/bonjourdrs/resource-finder-ios/actions/runs/40828283362); those results do not validate 0.4. Catalog and descriptor probes do not prove full-movie playback.
