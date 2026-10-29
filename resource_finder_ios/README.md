# Resource Finder iOS — 0.4.0

Native SwiftUI + AVFoundation app for iOS 17+. Ten source adapters: Jianpian, KKYS, Hongniu, 360, Modu, Feifan, Liangzi, Baofeng, Wujin and Tianya. All start enabled; the last five are experimental. Catalog responses, media descriptors and actual playback are separate evidence.

0.4 adds one playback control layer, persistent 0.5–3× speeds, temporary long-press acceleration, screen lock, seek/brightness/player-volume gestures, in-player queues and uniquely matched line switching. Portrait actions stay below 16:9 video; landscape panels overlay from the right and chrome hides after three seconds. See [acceptance contract](FEATURE_PARITY.md).

## Download and offline behavior

- Download-only never creates an AVPlayer or records watch history. Tasks are source/line/episode scoped and deduplicated; at most two assets transfer at once.
- MP4 uses native background URLSession downloads. New HLS uses standard cached playlists, public identity AES-128 keys and media resources. Each media object uses a native background URLSession task with required headers. Up to two objects per HLS asset transfer concurrently.
- Master/rendition playlists, URI attributes, keys and byte-range references are rewritten to local cache names. A byte-range resource is saved in full once so its offsets remain valid. Media playlists must be finite VOD. Variable URLs, DRM and steering/interstitial extensions without an offline adapter are rejected explicitly.
- Per-attempt cache metadata and protected key files persist before transfer. Native tasks reconnect after relaunch. Intentionally paused tasks remain paused; failed retries resolve a fresh descriptor and discard old partial media. Default policy is Wi-Fi only. System scheduling, force quit and low storage still require physical-device acceptance.
- Completion requires every expected cache object and playable local media, not just a transfer callback. Local opening checks files before playback. Missing keys/media become retryable errors; offline opening never calls the catalog resolver or silently falls back online.
- Local HLS playback serves only the validated cache through a random-token loopback relay. DLNA serves the same standard cache through a peer-restricted Wi-Fi relay. No private Apple package parsing or failed MP4 export path is used. Older 0.3 movpkg downloads remain phone-playable; re-download is required to make them portable for DLNA.
- Search deletion, favorites and watch history remain source-scoped and backward compatible with old JP records. Deleting a watch record suppresses later writes from that session; auto-next does not revive it.

## Casting

DLNA includes SSDP discovery, explicit LAN description URL addition, SOAP load/play/pause/stop/seek/volume/status, TV episode selection, auto-next, return-to-phone position and controls after closing the player. SOAP responses and media relays have separate tests. Only a successful TV status response is reported as TV playback.

SSDP discovery on a physical iPhone requires Apple's approved multicast entitlement and a matching signing profile; see [signing notes](Signing/README.md). Manual unicast device addition needs Local Network permission. AirPlay is also available where the media route is compatible. iOS LAN relays require the app in the foreground and stop explicitly when backgrounded. TV codec support and Wi-Fi isolation require household-TV testing.

## Build and install

```sh
brew install xcodegen
python3 scripts/prepare_assets.py
xcodegen generate
open ResourceFinder.xcodeproj
```

`swift test` runs portable source/persistence contracts. `bash scripts/ci.sh` runs native unit and UI tests against synthetic MP4/HLS/AES fixtures. Normal launches always use real services; test fixtures require the explicit DEBUG UI-test flag.

`bash scripts/build_ipa.sh` archives iPhoneOS arm64 with signing disabled and packages `build/Resource-Finder-iOS-0.4.0-Unsigned.ipa`, a checksum and platform metadata. This IPA needs signing/provisioning before installation. It is not a TestFlight export. The separate simulator app cannot install on an iPhone. See [Windows installation instructions](../INSTALL_CN.md).

No Apple credentials or signing certificates are configured. Public macOS CI uses a standard hosted runner.

## Transport rules and validation scope

- Public adapters validate bounded HTTPS JSON/HTML and do not execute remote JavaScript. API crypto vectors match the independent Python/Android contract. A locally generated Keychain guest identity is used; no user account is embedded.
- Media descriptors must match the chosen work/line/episode and reject fallback. Required media headers are applied through public networking APIs; CR/LF/control injection and API identity/hop-by-hop headers are rejected or excluded. HTTP media is allowed to match Android.
- Provider switches and observations do not auto-disable a failed/untested source. Catalog availability is independent of decoding, region restrictions and all-line availability.
- Synthetic tests cover actual local decode, seek, origin-stopped HLS/AES playback and TV media relay, queue persistence, native background task plumbing, SOAP protocol and player UI gestures. These do not prove physical iPhone signing, mobile network scheduling, every provider movie, every TV codec or multicast entitlement approval.
- iOS volume gestures affect the current video; hardware buttons control system volume. Brightness and orientation/idle state are restored when playback closes. Background audio and PiP are outside the Android feature scope.

Automated 0.4 acceptance passed 61 tests (15 portable + 38 native + 8 UI) in [run 14](https://github.com/bonjourdrs/resource-finder-ios/actions/runs/40890416787), app source `a33d021065c4189dffe49912e75df96e42624248`. The iPhoneOS arm64 package was verified separately from the iOS 18.5 simulator tests. Installation still requires effective device signing/provisioning and physical iPhone/TV testing.
