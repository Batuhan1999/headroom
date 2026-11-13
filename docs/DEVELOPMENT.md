# Development

Headroom uses SwiftUI and AppKit for a menu bar dropdown, IOBluetooth for Sony's RFCOMM control channel, and Core Audio for output activity. Swift alone keeps the bundle small and avoids a second compiler, FFI bridge or bundled runtime.

- `Sources/HeadroomCore`: frame parser, serialized request/ACK session, typed WH-1000XM5 settings, connection and idle policies. No hardware required for tests.
- `Sources/Headroom`: Bluetooth lifecycle, device-scoped audio tap, sleep observer, native dropdown, notifications, hot key and HUD.
- `Tests/HeadroomCoreTests`: captured Sony frames, malformed/truncated input, retries, source handoff, power-off safety, call restoration and battery thresholds.

## Validation

```sh
swift test
bash scripts/build.sh
```

The transport never replays queued mutations after reconnecting. Unknown playback/call state blocks auto-off. Silence from this Mac does not prove silence on the phone: remote playback must first be verified for the selected headset, firmware and remote device. Explicit source requests have a ten-second settling window, so stale phone reports cannot immediately re-mute a requested Mac. Sony's result and subsequent device selection are checked; rejected or unconfirmed requests are shown in the dropdown.

Hardware validation during development on a WH-1000XM5 (firmware 2.0.2) covered remote playing/paused reports, phone playback with a muted Mac stream, continuous phone playback through lid-close/wake, recovery after a transient reconnect error, manual shutdown and the silence timer's final-check shutdown path using a shortened 15-second test. These do not establish correctness for every app, call, firmware, dark-wake case or a full 15-minute run. Additional headphone controls use Sound Connect's published WH-1000XM5 layouts; the automated tests include its captured firmware 2.4.1 replies.

## Responsiveness

Core Audio process and device scans run on a utility queue, once per cycle. The UI consumes a timestamped snapshot; stale snapshots become unknown and cannot satisfy idle checks. RFCOMM writes are asynchronous and retain their buffers until completion or channel close. The paired-device list is cached between refreshes. Optional diagnostic serialization, login-status queries and file writes run off the main thread.

The 300-point native panel fits its content, with scrolling at screen height. Opening it and changing sections do not use animations. Outside-click dismissal excludes the status-item button, so that button can close the open panel without immediately reopening it.

A [GitHub Actions template](macos-ci.yml) runs tests and verifies an ad-hoc app build on macOS. To enable it, copy it to `.github/workflows/ci.yml` using a GitHub login with workflow-write permission. Automated CI is not enabled in this initial publication; the commands above were run locally.

## Packaging

`scripts/build.sh [destination]` produces `dist/Headroom.app` by default. `SIGNING_IDENTITY` selects a local identity; the default is ad-hoc. Do not commit certificates, private keys, local diagnostics, preferences or hardware addresses. Public beta assets use ad-hoc signing and are not notarized.

The app has no updater and never replaces itself from the upstream Sound Connect releases. The GitHub link opens this project's own release page. Settings from the early local prototype migrate once on the same Mac; that domain is read only for migration and no personal device data is embedded in source.

## Protocol sources

- [Sound Connect](https://github.com/aecca/sound-connect/tree/749e54438ec7be055a45021fea30dff87de22975): Sony v2 frames, noise control, EQ, DSEE, Speak-to-Chat, wearing settings and menu patterns (MIT).
- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient/tree/3c8f3330c85d45c29e7b76f718082a8d4fe402f1): playback controller, call status, source-switch outcomes and connected-source layouts (MIT).

Preserve the notices in `ThirdParty` when redistributing adapted code.
