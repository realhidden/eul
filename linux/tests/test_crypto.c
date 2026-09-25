//
//  test_crypto.c
//  eul (linux)
//
//  Known-answer tests against the RFC 8439 / 6234 / 4231 / 5869 / 6070
//  vectors, plus ChaChaPoly round-trip and tamper checks.
//

#include "../src/crypto.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void hex(const uint8_t *data, size_t len, char *out) {
    for (size_t i = 0; i < len; i++) {
        sprintf(out + i * 2, "%02x", data[i]);
    }
    out[len * 2] = 0;
}

static void check(const char *name, const char *got, const char *want) {
    int ok = strcmp(got, want) == 0;
    if (!ok) {
        failures++;
        printf("FAIL %s\n  got  %s\n  want %s\n", name, got, want);
    } else {
        printf("ok   %s\n", name);
    }
}

static void check_int(const char *name, int got, int want) {
    if (got != want) {
        failures++;
        printf("FAIL %s: got %d want %d\n", name, got, want);
    } else {
        printf("ok   %s\n", name);
    }
}

int main(void) {
    uint8_t out[64];
    char got[300], want[300];

    // SHA-256("abc") — FIPS 180-4 example
    eul_sha256((const uint8_t *)"abc", 3, out);
    hex(out, 32, got);
    check("sha256(abc)", got,
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    // SHA-256 of the 56-char "abc...dea" two-block message
    eul_sha256((const uint8_t *)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, out);
    hex(out, 32, got);
    check("sha256(two-block)", got,
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    // HMAC-SHA256, RFC 4231 test case 2
    eul_hmac_sha256((const uint8_t *)"Jefe", 4,
                    (const uint8_t *)"what do ya want for nothing?", 28, out);
    hex(out, 32, got);
    check("hmac-sha256 rfc4231#2", got,
          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    // HMAC key longer than the block size (RFC 4231 test case 6)
    uint8_t long_key[131];
    memset(long_key, 0xaa, sizeof long_key);
    eul_hmac_sha256(long_key, sizeof long_key,
                    (const uint8_t *)"Test Using Larger Than Block-Size Key - Hash Key First", 54, out);
    hex(out, 32, got);
    check("hmac-sha256 rfc4231#6", got,
          "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");

    // PBKDF2-HMAC-SHA256, 1 and 4096 iterations
    eul_pbkdf2_hmac_sha256((const uint8_t *)"password", 8, (const uint8_t *)"salt", 4, 1, out, 32);
    hex(out, 32, got);
    check("pbkdf2 c=1", got,
          "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");

    eul_pbkdf2_hmac_sha256((const uint8_t *)"password", 8, (const uint8_t *)"salt", 4, 4096, out, 32);
    hex(out, 32, got);
    check("pbkdf2 c=4096", got,
          "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");

    // PBKDF2 output shorter than one block (25-byte truncation of the c=1 vector)
    eul_pbkdf2_hmac_sha256((const uint8_t *)"password", 8, (const uint8_t *)"salt", 4, 1, out, 25);
    hex(out, 25, got);
    check("pbkdf2 dklen=25", got,
          "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc354808");

    // HKDF-SHA256, RFC 5869 test case 3 (zero salt, empty info — our only mode)
    uint8_t ikm[22];
    memset(ikm, 0x0b, sizeof ikm);
    eul_hkdf_sha256(ikm, sizeof ikm, NULL, 0, out, 42);
    hex(out, 42, got);
    check("hkdf rfc5869#3", got,
          "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8");

    // ChaCha20-Poly1305, RFC 8439 §2.8.2
    static const uint8_t key[32] = {
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b,
        0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
    };
    static const uint8_t nonce[12] = {
        0x07, 0x00, 0x00, 0x00, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
    };
    static const uint8_t aad[12] = {
        0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
    };
    static const char *pt =
        "Ladies and Gentlemen of the class of '99: If I could offer you "
        "only one tip for the future, sunscreen would be it.";
    static const uint8_t want_ct_tag[130] = {
        0xd3, 0x1a, 0x8d, 0x34, 0x64, 0x8e, 0x60, 0xdb, 0x7b, 0x86, 0xaf, 0xbc,
        0x53, 0xef, 0x7e, 0xc2, 0xa4, 0xad, 0xed, 0x51, 0x29, 0x6e, 0x08, 0xfe,
        0xa9, 0xe2, 0xb5, 0xa7, 0x36, 0xee, 0x62, 0xd6, 0x3d, 0xbe, 0xa4, 0x5e,
        0x8c, 0xa9, 0x67, 0x12, 0x82, 0xfa, 0xfb, 0x69, 0xda, 0x92, 0x72, 0x8b,
        0x1a, 0x71, 0xde, 0x0a, 0x9e, 0x06, 0x0b, 0x29, 0x05, 0xd6, 0xa5, 0xb6,
        0x7e, 0xcd, 0x3b, 0x36, 0x92, 0xdd, 0xbd, 0x7f, 0x2d, 0x77, 0x8b, 0x8c,
        0x98, 0x03, 0xae, 0xe3, 0x28, 0x09, 0x1b, 0x58, 0xfa, 0xb3, 0x24, 0xe4,
        0xfa, 0xd6, 0x75, 0x94, 0x55, 0x85, 0x80, 0x8b, 0x48, 0x31, 0xd7, 0xbc,
        0x3f, 0xf4, 0xde, 0xf0, 0x8e, 0x4b, 0x7a, 0x9d, 0xe5, 0x76, 0xd2, 0x65,
        0x86, 0xce, 0xc6, 0x4b, 0x61, 0x16,
        // tag
        0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a, 0x7e, 0x90, 0x2e, 0xcb,
        0xd0, 0x60, 0x06, 0x91,
    };
    size_t pt_len = strlen(pt);
    uint8_t sealed[256];
    eul_chachapoly_seal(key, nonce, aad, sizeof aad, (const uint8_t *)pt, pt_len, sealed);

    // expected combined form: nonce ‖ ciphertext ‖ tag
    uint8_t expected[142];
    memcpy(expected, nonce, 12);
    memcpy(expected + 12, want_ct_tag, pt_len + 16);
    hex(sealed, pt_len + 28, got);
    hex(expected, pt_len + 28, want);
    check("chachapoly rfc8439#2.8.2", got, want);

    // opening it back
    uint8_t opened[256];
    check_int("chachapoly open(rfc vector)",
              eul_chachapoly_open(key, sealed, pt_len + 28, aad, sizeof aad, opened)
                  && memcmp(opened, pt, pt_len) == 0, 1);

    // round-trip with empty AAD (what the peer protocol uses)
    static const uint8_t rkey[32] = { 1, 2, 3 };
    static const uint8_t rnonce[12] = { 9 };
    const char *msg = "{\"id\":\"x\",\"stats\":{\"cpu\":1.5}}";
    eul_chachapoly_seal(rkey, rnonce, NULL, 0, (const uint8_t *)msg, strlen(msg), sealed);
    check_int("chachapoly roundtrip (empty aad)",
              eul_chachapoly_open(rkey, sealed, strlen(msg) + 28, NULL, 0, opened)
                  && memcmp(opened, msg, strlen(msg)) == 0, 1);

    // flipping one ciphertext bit must fail the tag
    sealed[40] ^= 1;
    check_int("chachapoly rejects tampering",
              eul_chachapoly_open(rkey, sealed, strlen(msg) + 28, NULL, 0, opened), 0);

    printf(failures ? "\n%d FAILURE(S)\n" : "\nall passed\n", failures);
    return failures != 0;
}
