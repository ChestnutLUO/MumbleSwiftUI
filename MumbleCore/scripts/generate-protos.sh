#!/usr/bin/env bash
# Regenerates Swift sources from the vendored Mumble .proto files.
# Requires: protoc, protoc-gen-swift (brew install protobuf swift-protobuf)
set -euo pipefail

cd "$(dirname "$0")/.."
PROTO_DIR="Sources/MumbleProtocol/Proto"
OUT_DIR="Sources/MumbleProtocol/Generated"

protoc \
    --proto_path="$PROTO_DIR" \
    --swift_out="$OUT_DIR" \
    --swift_opt=Visibility=Public \
    "$PROTO_DIR"/Mumble.proto "$PROTO_DIR"/MumbleUDP.proto

echo "Generated:"
ls -l "$OUT_DIR"
