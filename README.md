# SpotCloud

Tweak for Spotify 9.1.90 (iOS, sideloaded with ESign, no jailbreak).

- **SoundCloud in search**: Spotify's search also asks SoundCloud api-v2; results are mixed into the
  normal results with "(SC)" after the title. Duplicates are merged, Go+/encrypted/preview tracks hidden.
- **Played natively**: a tapped SC track is downloaded (HLS, remuxed to .m4a without re-encoding, album
  "SoundCloud", SC ID in the comment), dropped into Spotify's local files and played by Spotify's player.
  1 GB LRU cache, next 2–3 SC tracks in the queue prefetched.
- **JamesDSP**: libjamesdsp (with a bass-priority output limiter) is the engine behind spotifyglass's
  Audio effects page. `Scripts/patch_spotifyglass.py` turns spotifyglass's own engine off (one
  instruction, checked against the exact build).

Every feature is behind a flag (`spotcloud.feature.*`) and a crash guard. Hooks are Objective-C runtime
swaps and an import-slot rebind only: no Substrate, no code patching at runtime.

## Status

| Stage | What | State |
|---|---|---|
| 0 | Probe (classes, requests, dumps) + JamesDSP | this build |
| 1 | SoundCloud client, filter, dedup (+ tests) | done, not hooked yet |
| 2 | Search injection | after the probe log |
| 3 | Download, remux, tags, local files, playback | |
| 4 | Cache, prefetch, settings page | |

## Build

GitHub Actions (`.github/workflows/build.yml`) builds `SpotCloud.dylib` and runs the logic tests.
Locally: `THEOS=~/theos make` (libjamesdsp's static library needs `xcrun` for clang/libtool/SDK).

## Credits

libjamesdsp by James Fung (GPL-2.0, `vendor/libjamesdsp`). Ideas from EeveeSpotify (response patching),
NextUp (player/queue), soundcloud.ts (client_id, transcodings).
