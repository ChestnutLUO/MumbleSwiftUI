# MumbleSwiftUI

A native Mumble client for Apple platforms, built with SwiftUI. Targets the
Mumble 1.5 protocol (protobuf UDP voice, Opus-only) with legacy fallback
planned for older servers.

## Features

- TLS control channel with trust-on-first-use certificate pinning
- Two-way voice: OCB2-AES128 encrypted UDP with automatic TCP-tunnel
  fallback and crypt resync; Opus 48 kHz, per-speaker jitter buffers
- Transmit modes: continuous, voice activity (adjustable threshold with
  live meter), push-to-talk
- Self mute/deafen, per-user local mute, speaking indicators
- Channel tree: join, create channels; channel and private text chat

## Layout

- `MumbleCore/` — SwiftPM package, UI-independent:
  - `MumbleProtocol` — vendored `.proto` definitions, generated Swift
    protobufs, Mumble varint codec, TCP control-channel framing.
  - `MumbleCrypto` — OCB2-AES128 for the UDP voice channel.
  - `MumbleConnection` — Network.framework TLS + UDP transport,
    session state machine.
  - `MumbleAudio` — Opus encode/decode (vendored libopus), mic capture,
    AVAudioEngine playback, jitter buffer, voice activity detection.
- `App/` — the SwiftUI app. Targets: `MumbleSwiftUI` (macOS) and
  `MumbleSwiftUI-iOS` (iPhone/iPad).

## Building

Prerequisites: Xcode 26+. No Homebrew dependencies — libopus is
vendored and compiled from source for macOS, iOS, and simulator
(protobuf/xcodegen only needed when regenerating).

**App**: open `App/MumbleSwiftUI.xcodeproj`, scheme `MumbleSwiftUI`
(macOS) or `MumbleSwiftUI-iOS` (iPhone/iPad), ⌘R.
The project is generated from `App/project.yml` — edit that and rerun
`xcodegen generate` rather than editing project settings directly.

Running the iOS app on a real device requires a development team:
select yours under Signing & Capabilities (or set `DEVELOPMENT_TEAM`
in `project.yml`). The simulator needs no signing.

**Core package tests**:

```sh
cd MumbleCore
swift test                        # unit tests
MUMBLE_INTEGRATION=1 swift test   # + live-server tests (needs local server)
```

Regenerate protobufs after updating the vendored `.proto` files
(requires `brew install protobuf swift-protobuf`):

```sh
MumbleCore/scripts/generate-protos.sh
```

Local test server (OrbStack/Docker):

```sh
docker run -d --name mumble-test -p 64738:64738 -p 64738:64738/udp mumblevoip/mumble-server
```

## Protocol references

- https://github.com/mumble-voip/mumble/tree/master/docs/dev/network-protocol
- `src/Mumble.proto`, `src/MumbleUDP.proto`, `src/MumbleProtocol.{h,cpp}` in
  the upstream repo (BSD-licensed; vendored protos retain their headers).

## License

BSD 3-Clause (see `LICENSE`). Portions derived from the BSD-licensed
[Mumble](https://github.com/mumble-voip/mumble) project — notably the
OCB2-AES128 implementation and the vendored protocol definitions.
`MumbleCore/Vendor/swift-protobuf` is Apple's
[swift-protobuf](https://github.com/apple/swift-protobuf) (Apache-2.0),
vendored unmodified. `MumbleCore/Vendor/opus` is
[libopus 1.5.2](https://opus-codec.org) (BSD-3-Clause), vendored with
docs/tests/DNN models stripped.
