# Resource Finder iOS

Native SwiftUI + AVFoundation video source browser for iOS 17 and later.

- Ten source adapters with independent source switches and catalog/media verification states.
- Favorites, removable search history, watch resume and source-scoped persistence.
- Download-only MP4/HLS tasks, native background transfers and local-only offline playback.
- System player controls for playback speed, landscape/fullscreen and AirPlay.

## Build artifacts

[Build workflow](https://github.com/bonjourdrs/resource-finder-ios/actions/workflows/build-resource-finder-ios.yml) runs on a standard macOS GitHub-hosted runner. It packages a genuine arm64 iPhoneOS archive as **Resource-Finder-iOS-0.3.0-Unsigned.ipa**, with a SHA-256 checksum. This unsigned package needs appropriate signing/provisioning before iPhone installation. The separate simulator app ZIP cannot install on an iPhone.

No Apple signing credentials are configured. Android custom gestures/lock behavior and DLNA are not implemented. Catalog or descriptor checks do not prove full-movie playback or the availability of every line.

See [app documentation](resource_finder_ios/README.md) for setup, transport rules and verification scope. This repository contains an independent current iOS snapshot; no unrelated project files or previous private history are included.
