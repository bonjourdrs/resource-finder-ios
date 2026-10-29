# Resource Finder iOS — 0.4.0 candidate

Native SwiftUI + AVFoundation app with ten source adapters: Jianpian, KKYS, Hongniu, 360, Modu, Feifan, Liangzi, Baofeng, Wujin and Tianya. All sources start enabled; the last five are explicitly experimental. No custom backend is required.

0.3 ported Android beta3's provider registry, independent source switches, catalog/media status records, manual rechecks, source-scoped favorites/watch/download identities and numeric next-episode rules. Unsupported and empty MacCMS groups remain visible with reasons. A catalog response or resolved descriptor never means an entire movie was played successfully. Public adapters read bounded HTTPS JSON/HTML data, do not execute remote JavaScript, refresh descriptors before playback/download, and validate HLS manifests before handing them to AVFoundation. Searches have a per-source 30-second deadline. Tianya requests reserve spaced slots with a five-second interval.

The 0.2 download-only picker, persistent native background MP4/HLS queue, local-only playback, removable search history and watch resume remain available. 0.4 adds a single custom chrome layer over AVPlayerLayer, lock, temporary long-press speed, seek/brightness/player-volume gestures, persistent speed, in-player queues/lines and DLNA. See FEATURE_PARITY.md for the exact behavior and remaining physical/platform acceptance items.

## Download and offline behavior

- `URLSessionDownloadTask` saves progressive media and `AVAssetDownloadURLSession` saves HLS media, including ordinary identity AES-128 HLS. A bounded manifest/key preflight saves the public 16-byte keys in protected per-download records. Offline playback activates a memory-only URLProtocol response for exactly those saved key URLs, then releases it when the player closes. Download preparation explicitly bypasses replay so a concurrent download gets fresh keys. Generated clear/encrypted samples are tested; DRM/FairPlay is not implemented. The HLS downloader requests the asset's media selections and validates `assetCache.isPlayableOffline` before declaring completion.
- Download-only never creates an AVPlayer or a watch record. The queue deduplicates by work/line/episode and starts at most two tasks. Default policy is Wi-Fi only. System background scheduling can defer work; force-quitting the app cancels native transfers. Interrupted tasks reconnect if still present, otherwise expose retry; intentionally paused tasks stay paused.
- Background sessions use fixed identifiers, reconnect after relaunch and hold Apple's completion handler until local validation and metadata persistence finish. A persisted attempt ID rejects callbacks from removed/retried tasks. Retry resolves a fresh descriptor and discards the old partial package rather than mixing media versions.
- HLS packages stay at the system-provided URL. Progressive files live in Application Support; media/metadata are excluded from backup. The queue stores sandbox-relative references/file bookmarks and catalog selections. Protected key records also retain their key URIs so the system can match requests. Resolved movie URLs and API credentials are not stored in queue metadata.
- Offline opening never calls the catalog resolver. Missing/incomplete assets are rejected and become retryable; no online fallback. Download removal is blocked while that item is playing. System-purged HLS packages are detected on opening.
- Native download progress remains below 100% until playable local content is validated. HLS progress measures the union of loaded time ranges. Catalog errors, transfer failure, storage problems and incomplete local media remain distinct failures.
- Watch history is written only after playback advances. Deleting an active watch record suppresses later writes from that session; an explicit new playback starts recording again. Automatic next episode keeps the current line and does not revive a suppressed watch record.

## Build and run

On a Mac with Xcode and XcodeGen:

```sh
brew install xcodegen
python3 scripts/prepare_assets.py
xcodegen generate
open ResourceFinder.xcodeproj
```

Select an iPhone simulator and Run. Normal launches use the real provider; no sample results are substituted for network errors. Debug UI tests explicitly launch with `--ui-testing` and use a generated 20-second color video. Those screenshots establish the interface and local playback flow, not real provider-video decoding.

`swift test` runs portable adapter contracts (Swift 6.0+ on macOS; the Linux test dependency uses Swift 6.2+). `swift run ProviderProbe` separately checks public catalog/detail/descriptor responses and writes `build/provider-probe.json`; network failures are reported rather than replaced by sample data.

`bash scripts/build_ipa.sh` archives the Release target for a generic iPhoneOS device with signing disabled, checks the platform and arm64 executable, and creates `build/Resource-Finder-iOS-0.4.0-Unsigned.ipa` plus a SHA-256 file. This is an unsigned device package and requires suitable signing/provisioning before installation. It is not an App Store/TestFlight export. The workflow uploads it even if later simulator tests fail; packaging alone does not establish test acceptance.

`bash scripts/ci.sh` runs unit and UI tests, exports screenshots and a locally ad-hoc-signed simulator `.app` ZIP. The simulator ZIP cannot install on an iPhone. Device installation requires a configured Apple team, bundle identifier, signing and a suitable distribution method. The simulator uses local ad-hoc signing so its normal Keychain identity can be tested; this uses no Apple developer certificate. No signing secrets, personal Apple credentials, uploads to TestFlight, or App Store submission are performed by this foundation workflow.

## Transport and media rules

- CryptoKit request signing/AES-GCM matches the independent Python/Android contract vectors. Signs the exact encoded URI; authenticated responses bind method, URI, status, timestamp, request nonce and installation identity. API redirects are rejected.
- The normal guest identity is locally generated and retained in a device-only Keychain item; no account login or identity rotation on failure. Catalog and playback URLs are not stored in history/favorites.
- Requests are cancellable and stale searches/episode loads cannot replace new selections. Works are identified by source plus numeric provider work ID, not title. Old saved entries without a source ID remain Jianpian, preserving the existing `jp:` download identities. Playback descriptors must match the selected line and episode and may not report fallback.
- HLS and progressive HTTP(S) use AVPlayer with a single app-owned control layer. User-Agent uses the public asset option; other required media headers use a token-scoped streaming HTTP relay. HLS URI attributes, child playlists, keys, segments and MP4 byte ranges are forwarded. No undocumented AVURLAsset option is used. Proprietary engines and remote JS parser pages remain unsupported on both platforms.
- ATS permits HTTP media to match Android. Production catalog adapters still enforce their own HTTPS/public-host policy and API redirect rules. Descriptor headers reject CR/LF injection and exclude guest API identity/hop-by-hop fields. Neither version bypasses provider authorization or region restrictions.
- Ordinary native downloads retain background transfers. HLS requiring the header relay pauses in the background with an explicit reason and can retry on return. iOS LAN relay casting stops when backgrounded; direct casting is independent of the phone's media stream. See Signing/README.md for the physical-device multicast capability.
- Playback pauses when leaving the foreground; closing releases the item, observers, relay, touch hold, orientation mask and screen/idle settings. Background audio and PiP are not part of Android feature parity.

## Validation

The workflow runs deterministic protocol, identity, persistence, stale-result, line-selection and actual synthetic-video decoding/playback tests, UI search/history/favorites/rotation flows, and a separate live public catalog/descriptor probe using the same Swift transport. The live probe does not request movie media bytes; a descriptor does not prove that AVPlayer can decode a provider video. Provider availability is reported independently from deterministic CI.

Phone playback, physical-device signing/install, iPad layout, live HLS/codec/header compatibility and household TVs remain acceptance items. Simulator tests cannot establish physical iPhone/TV parity. Platform differences are enumerated in FEATURE_PARITY.md.

Download validation includes actual native MP4, HLS and AES-128 HLS transfers from a loopback server, then shuts down that origin and checks rendered local playback, progression, seek and deletion. HLS playback tests attach an actual AVPlayerLayer; a separate online HLS baseline verifies the fixture. AES validation requires the production player to consume a saved key response. A scoped replay test verifies cleanup and fresh-network bypass during download preparation. UI tests cover download-only with no player launch, relaunch with a completed download, and local playback. Real provider episodes are not downloaded by CI. Native scheduling, system process termination, force-quit recovery and low-space behavior on a physical phone remain device acceptance items.

## Validation status

Local Swift 6.2.3 on Linux compiled the production portable core and passed 11 XCTest contracts, including cross-source favorites/watch deletion and legacy identity decoding. All 27 app/native-test Swift files passed syntax parsing. Linux checks do not type-check SwiftUI/AVFoundation/CommonCrypto branches and are not a substitute for an Xcode build.

The live Swift probe resolved matching sample HLS descriptors/manifests on KKYS, Hongniu, 360 and Modu. Feifan, Liangzi and Wujin catalogs/details matched; Baofeng and Tianya returned invalid JSON in that attempt. These observations do not establish physical-device playback or every-line availability.

Full Xcode build, native simulator acceptance and device IPA generation are tracked by this repository's workflow. Generated unsigned device packages require signing/provisioning before installation. A build artifact and passed native tests are separate acceptance milestones.
