# MumbleSwiftUI

A native Mumble client for Apple platforms, built with SwiftUI. Targets the
Mumble 1.5 protocol (protobuf UDP voice, Opus-only) with legacy fallback
planned for older servers.

## Layout

- `MumbleCore/` — SwiftPM package, UI-independent:
  - `MumbleProtocol` — vendored `.proto` definitions, generated Swift
    protobufs, Mumble varint codec, TCP control-channel framing.
  - (planned) `MumbleCrypto` — OCB2-AES128 for the UDP voice channel.
  - (planned) `MumbleConnection` — Network.framework TLS + UDP transport,
    session state machine.
  - (planned) `MumbleAudio` — Opus encode/decode, AVAudioEngine I/O,
    jitter buffer.
- (planned) `App/` — the SwiftUI multiplatform app.

## Development

```sh
cd MumbleCore
swift test
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
