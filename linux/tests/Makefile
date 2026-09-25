CC      ?= cc
CFLAGS  ?= -O2
WARN     = -Wall -Wextra -Wpedantic -std=c99
DEFS     = -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE
LIBS     = -lpthread -lm -ldl

.PHONY: run compat clean

run: test_crypto test_json test_mqtt
	./test_crypto
	./test_json
	./test_mqtt

test_crypto: test_crypto.c ../src/crypto.c ../src/crypto.h
	$(CC) $(CFLAGS) $(WARN) $(DEFS) -o $@ test_crypto.c ../src/crypto.c $(LIBS)

test_json: test_json.c ../src/json.c ../src/json.h ../src/peer.c ../src/peer.h \
            ../src/stats.c ../src/crypto.c ../src/mqtt.c ../src/mqtt.h
	$(CC) $(CFLAGS) $(WARN) $(DEFS) -o $@ test_json.c ../src/json.c ../src/peer.c \
		../src/stats.c ../src/crypto.c ../src/mqtt.c $(LIBS)

test_mqtt: test_mqtt.c ../src/mqtt.c ../src/mqtt.h
	$(CC) $(CFLAGS) $(WARN) $(DEFS) -o $@ test_mqtt.c ../src/mqtt.c $(LIBS)

# macOS only: seals snapshots with the primitives the eul app ships
# (CommonCrypto PBKDF2 + CryptoKit HKDF/ChaChaPoly) and checks our C
# derivation matches key-for-key, in both directions.
compat: run_compat.sh compat_runner.swift compat_main.c
	./run_compat.sh

clean:
	rm -f test_crypto test_json test_mqtt compat_bin compat_keys.txt compat_swift_sealed.txt compat_c_sealed.txt
