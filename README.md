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

## Verified 0.3.0 build

[Workflow run 3](https://github.com/bonjourdrs/resource-finder-ios/actions/runs/40828283362) passed for app source commit `34d559c678b25830aaad19054a69138be418f263`.

- Xcode 16.4 archived the Release app for iPhoneOS arm64; version 0.3.0, build 3, minimum iOS 17.
- 11 portable core tests, 28 native iOS tests and 6 UI tests passed with zero failures. Native tests ran on an iPhone 16 Pro simulator with iOS 18.5 and include MP4/HLS/AES-128 downloads and local playback after the synthetic origin stopped.
- Test screenshots for detail, portrait/landscape playback and completed downloads were inspected. UI media is a generated color-video fixture.
- Live Jianpian catalog/descriptor checks passed. KKYS, Hongniu, 360 and Modu resolved matching HLS descriptors/manifests. Feifan, Liangzi, Baofeng and Wujin catalogs/details responded; Tianya returned invalid catalog JSON in this attempt. These checks do not prove real provider-video decoding or all-line availability.
- IPA SHA-256: `c7cc3a2df60e1fc1f176644c52e8e1a2a81f7217f5ce348b629a01a0c607f618`.

The package is unsigned. Physical iPhone installation/playback and household-TV acceptance remain to be verified after signing. Workflow artifacts have limited retention; the workflow can regenerate them.
