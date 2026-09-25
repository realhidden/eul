#!/bin/bash
# Swift cross-check for the eul-peer protocol (macOS only — needs CryptoKit
# via the system Swift toolchain). Verifies:
#   1. our PBKDF2/HKDF derivation matches CryptoKit key for key
#   2. we open and decode a snapshot the way the Mac app seals it
#   3. Swift opens a snapshot we sealed
set -euo pipefail
cd "$(dirname "$0")"

SECRET="xryfj-qcrb4-vrckj-r7p8d"
CC=${CC:-cc}
CFLAGS="-O2 -std=c99 -Wall -Wextra -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE"

echo "== building"
$CC $CFLAGS -o compat_bin compat_main.c ../src/peer.c ../src/crypto.c ../src/mqtt.c ../src/json.c ../src/stats.c -lpthread -lm -ldl

SENT_AT=$(( $(date +%s) - 978307200 - 5 ))
SNAPSHOT="{\"id\":\"SWIFT-TEST-1\",\"name\":\"MacBook Pro\",\"sentAt\":${SENT_AT}.5,\"stats\":{\"cpu\":12.5,\"memory\":45.25,\"temperature\":52,\"temperatureUnit\":\"celius\",\"networkIn\":1024,\"networkOut\":512}}"

echo "== swift derives keys, seals a snapshot"
swift compat_runner.swift keys "$SECRET" > compat_keys.txt
swift compat_runner.swift seal "$SECRET" "$SNAPSHOT" > compat_swift_sealed.txt

echo "== c verifies derivation, opens and decodes"
./compat_bin "$SECRET" compat_keys.txt compat_swift_sealed.txt compat_c_sealed.txt

echo "== swift opens the c snapshot"
ROUNDTRIP=$(swift compat_runner.swift open "$SECRET" "$(cat compat_c_sealed.txt)")
echo "$ROUNDTRIP" | grep -q '"name":"rpi5"' && echo "ok   swift opens c payload, JSON intact"

echo "compat check complete"
