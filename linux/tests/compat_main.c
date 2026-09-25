//
//  compat_main.c
//  eul (linux)
//
//  Half of the Swift cross-check (compat_runner.swift is the other half).
//  Verifies our PBKDF2/HKDF derivation matches CryptoKit's key for key,
//  opens a Swift-sealed snapshot and decodes it, then seals one of our own
//  for Swift to open.
//
//  usage: compat_main SECRET keys_file swift_sealed_file c_sealed_out_file
//

#include "../src/crypto.h"
#include "../src/peer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(const char *name, int ok) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) {
        failures++;
    }
}

static int read_two_lines(const char *path, char *line1, char *line2, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) {
        return 0;
    }
    int ok = fgets(line1, (int)cap, f) != NULL && fgets(line2, (int)cap, f) != NULL;
    fclose(f);
    if (ok) {
        for (char **line = (char *[]){ line1, line2 }; **line; line++) {
            size_t n = strlen(*line);
            while (n > 0 && ((*line)[n - 1] == '\n' || (*line)[n - 1] == '\r')) {
                (*line)[--n] = '\0';
            }
        }
    }
    return ok;
}

static int read_line(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) {
        return 0;
    }
    int ok = fgets(out, (int)cap, f) != NULL;
    fclose(f);
    if (ok) {
        size_t n = strlen(out);
        while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) {
            out[--n] = '\0';
        }
    }
    return ok;
}

static size_t unhex(const char *hex, uint8_t *out, size_t cap) {
    size_t len = strlen(hex) / 2;
    if (len > cap) {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned byte;
        if (sscanf(hex + i * 2, "%2x", &byte) != 1) {
            return 0;
        }
        out[i] = (uint8_t)byte;
    }
    return len;
}

static void hexs(const uint8_t *data, size_t len, char *out) {
    for (size_t i = 0; i < len; i++) {
        sprintf(out + i * 2, "%02x", data[i]);
    }
    out[len * 2] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: compat_main SECRET keys_file sealed_file out_file\n");
        return 2;
    }
    const char *secret = argv[1];
    char topic_hex[80], seal_hex[80], sealed_hex[4096];
    if (!read_two_lines(argv[2], topic_hex, seal_hex, sizeof topic_hex)) {
        fprintf(stderr, "cannot read keys file (line 1 topic, line 2 seal)\n");
        return 2;
    }
    if (!read_line(argv[3], sealed_hex, sizeof sealed_hex)) {
        fprintf(stderr, "cannot read sealed file\n");
        return 2;
    }

    // our derivation against CryptoKit's
    char topic[80];
    uint8_t seal_key[32];
    peer_derive_keys(secret, topic, sizeof topic, seal_key);
    char expected_topic[80];
    snprintf(expected_topic, sizeof expected_topic, "eul-peer/%s", topic_hex);
    check("topic derivation matches Swift", strcmp(topic, expected_topic) == 0);
    char seal_got[80];
    hexs(seal_key, 32, seal_got);
    check("seal key derivation matches Swift", strcmp(seal_got, seal_hex) == 0);

    // open + decode the Swift-sealed snapshot
    uint8_t combined[2048];
    size_t combined_len = unhex(sealed_hex, combined, sizeof combined);
    check("swift payload size sane", combined_len > 28);
    uint8_t plain[2048];
    int opened = eul_chachapoly_open(seal_key, combined, combined_len, NULL, 0, plain);
    check("c opens swift ChaChaPoly payload", opened);

    peer_entry peer;
    int decoded = opened && peer_decode_snapshot(plain, combined_len - 28, &peer);
    check("c decodes swift snapshot JSON", decoded);
    if (decoded) {
        printf("     swift snapshot: name=%s cpu=%.1f memory=%.1f\n", peer.name,
               peer.cpu, peer.memory);
    }

    // seal one of our own for Swift to open
    const char *json =
        "{\"id\":\"C0FFEE-0001\",\"name\":\"rpi5\",\"stats\":{\"cpu\":7.5,"
        "\"memory\":33.0,\"temperature\":60.5,\"temperatureUnit\":\"celius\","
        "\"networkIn\":64,\"networkOut\":128}}";
    uint8_t nonce[12] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
                          0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };
    uint8_t out[512];
    eul_chachapoly_seal(seal_key, nonce, NULL, 0, (const uint8_t *)json, strlen(json), out);
    char hex_out[1200];
    hexs(out, strlen(json) + 28, hex_out);
    FILE *f = fopen(argv[4], "w");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", argv[4]);
        return 2;
    }
    fprintf(f, "%s\n", hex_out);
    fclose(f);
    printf("     c sealed a snapshot for swift to open\n");

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
    } else {
        printf("compat checks passed\n");
    }
    return failures != 0;
}
