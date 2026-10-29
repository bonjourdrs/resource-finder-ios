# Android 1.3 beta3 / iOS 0.4 acceptance contract

Android reference: `bonjourdrs/codex-test` commit `9dca0368d3ccf07bee461d6501100b9a31721b3a`. iOS changes are native implementations; byte-for-byte UI and binary sizes are not parity criteria.

| Capability | Required behavior / evidence |
|---|---|
| Ten catalogs | Same enabled registry and five experimental flags; preserve unsupported groups and per-source observations |
| Library | Source-scoped favorites, removable searches, watch history and downloads; old JP records compatible |
| Resume | Restart completed/near-end videos; suppress records deleted during a session |
| Download only | Resolve and enqueue without opening or interrupting a player; MP4/HLS/AES-128 offline verification |
| Playback controls | One chrome layer, 16:9 portrait video with actions below, fullscreen landscape, three-second auto-hide |
| Lock | Hide every transport action; only unlock can appear; tap summons unlock; orientation mask held |
| Speed | Persistent 0.5/0.75/1/1.25/1.5/2/2.5/3; hold temporarily uses max(fixed, configured hold speed); cancel/pause restores |
| Gestures | Tap chrome, double tap transport, horizontal seek, left brightness and right player volume; suppressed while locked |
| Queue / lines | Select episodes in player, same-source line switch only on unique matching episode; keep playback on mismatch |
| DLNA | SSDP discovery, explicit description URL, SOAP load/play/pause/stop/seek/volume/status, natural auto-next; failures visible |
| Header media | Validate and apply required headers; stream MP4 ranges and rewrite HLS playlists/keys/segments through bounded relay |
| Casting transport | Direct URL or TV-restricted LAN relay; offline MP4 relay; offline HLS uses system export only if supported |

## Platform differences requiring physical acceptance

- iOS SSDP multicast requires an Apple-approved multicast entitlement in the signing profile. Manual unicast device addition needs only Local Network permission. Unsigned CI packages cannot grant an entitlement. See Signing/README.md.
- iOS cannot run an arbitrary HTTP relay indefinitely after suspension. Header-adapted HLS downloads pause with a visible explanation in background; foreground continuation retries a fresh descriptor. Ordinary native MP4/HLS transfers retain existing background support. LAN relay casting explicitly stops when the app backgrounds. Android's foreground service can keep its relay alive.
- Right-side gesture changes this video's volume on iOS. Hardware volume still controls the system. Brightness is restored when leaving playback.
- Offline HLS TV export depends on AVFoundation's export support for the downloaded package. An unsupported export is an explicit error, never a network fallback. Online HLS/MP4 and offline MP4 have independent relay paths.
- iOS uses AirPlay in addition to DLNA. Real TV codecs, Wi-Fi isolation, entitlement grant and physical iPhone rotation must be verified after signing. Simulator SOAP fixtures are protocol evidence, not household-TV evidence.
- Both builds reject proprietary engines and remote JavaScript parsing pages. A catalog descriptor is not proof every provider movie can decode.

CI acceptance is pending for this revision. Do not mark physical device / TV acceptance complete based on simulator tests.
