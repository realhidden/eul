//
//  crypto.c
//  eul (linux)
//

#include "crypto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/random.h> // getentropy (the compat tests build here)
#endif

void eul_random_bytes(uint8_t *out, size_t len) {
    // getentropy: glibc 2.25+, musl 1.1.20+, macOS — at most 256 bytes a call
    while (len > 0) {
        size_t n = len > 256 ? 256 : len;
        if (getentropy(out, n) != 0) {
            // a zero nonce would break ChaChaPoly, a zero secret is guessable:
            // never fall back to anything predictable
            fprintf(stderr, "eul: no system randomness available\n");
            abort();
        }
        out += n;
        len -= n;
    }
}

// ---------------------------------------------------------------------------
// SHA-256 (FIPS 180-4)
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t state[8];
    uint64_t bits;
    uint8_t buf[64];
    size_t buf_len;
} sha256_ctx;

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_compress(uint32_t state[8], const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16)
             | ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR32(w[i - 15], 7) ^ ROR32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR32(w[i - 2], 17) ^ ROR32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ROR32(e, 6) ^ ROR32(e, 11) ^ ROR32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K256[i] + w[i];
        uint32_t S0 = ROR32(a, 2) ^ ROR32(a, 13) ^ ROR32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static void sha256_init(sha256_ctx *ctx) {
    static const uint32_t iv[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(ctx->state, iv, sizeof iv);
    ctx->bits = 0;
    ctx->buf_len = 0;
}

static void sha256_update(sha256_ctx *ctx, const uint8_t *data, size_t len) {
    ctx->bits += (uint64_t)len * 8;
    while (len > 0) {
        size_t take = 64 - ctx->buf_len;
        if (take > len) {
            take = len;
        }
        if (take > 0) { // data may be NULL for empty input (no AAD)
            memcpy(ctx->buf + ctx->buf_len, data, take);
        }
        ctx->buf_len += take;
        data += take;
        len -= take;
        if (ctx->buf_len == 64) {
            sha256_compress(ctx->state, ctx->buf);
            ctx->buf_len = 0;
        }
    }
}

static void sha256_final(sha256_ctx *ctx, uint8_t out[32]) {
    uint64_t bits = ctx->bits;
    uint8_t pad[72];
    size_t pad_len = ctx->buf_len < 56 ? 56 - ctx->buf_len : 120 - ctx->buf_len;
    memset(pad, 0, sizeof pad);
    pad[0] = 0x80;
    for (int i = 0; i < 8; i++) {
        pad[pad_len + i] = (uint8_t)(bits >> (56 - i * 8));
    }
    sha256_update(ctx, pad, pad_len + 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (uint8_t)(ctx->state[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(ctx->state[i]);
    }
}

void eul_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
    sha256_ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, out);
}

// ---------------------------------------------------------------------------
// HMAC-SHA256 with precomputed key states (PBKDF2 calls it 400k times)
// ---------------------------------------------------------------------------

typedef struct {
    sha256_ctx inner; // state after the ipad block
    sha256_ctx outer; // state after the opad block
} hmac_key;

static void hmac_key_init(hmac_key *hk, const uint8_t *key, size_t key_len) {
    uint8_t block[64];
    memset(block, 0, sizeof block);
    if (key_len > 64) {
        eul_sha256(key, key_len, block);
    } else if (key_len > 0) {
        memcpy(block, key, key_len);
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = block[i] ^ 0x36;
        opad[i] = block[i] ^ 0x5c;
    }
    sha256_init(&hk->inner);
    sha256_update(&hk->inner, ipad, 64);
    sha256_init(&hk->outer);
    sha256_update(&hk->outer, opad, 64);
}

static void hmac_digest(const hmac_key *hk, const uint8_t *data, size_t len, uint8_t out[32]) {
    sha256_ctx inner = hk->inner;
    sha256_update(&inner, data, len);
    uint8_t ihash[32];
    sha256_final(&inner, ihash);
    sha256_ctx outer = hk->outer;
    sha256_update(&outer, ihash, 32);
    sha256_final(&outer, out);
}

void eul_hmac_sha256(
    const uint8_t *key, size_t key_len,
    const uint8_t *data, size_t data_len,
    uint8_t out[32]
) {
    hmac_key hk;
    hmac_key_init(&hk, key, key_len);
    hmac_digest(&hk, data, data_len, out);
}

// ---------------------------------------------------------------------------
// PBKDF2-HMAC-SHA256 (RFC 2898)
// ---------------------------------------------------------------------------

void eul_pbkdf2_hmac_sha256(
    const uint8_t *pass, size_t pass_len,
    const uint8_t *salt, size_t salt_len,
    uint32_t iterations,
    uint8_t *out, size_t out_len
) {
    hmac_key hk;
    hmac_key_init(&hk, pass, pass_len);

    uint32_t block_index = 1;
    while (out_len > 0) {
        uint8_t u[32], t[32];
        uint8_t salt_block[256 + 4];
        size_t seed_len = salt_len + 4;
        if (seed_len > sizeof salt_block) {
            return; // salt too long for our stack buffer; callers use 8
        }
        memcpy(salt_block, salt, salt_len);
        salt_block[salt_len] = (uint8_t)(block_index >> 24);
        salt_block[salt_len + 1] = (uint8_t)(block_index >> 16);
        salt_block[salt_len + 2] = (uint8_t)(block_index >> 8);
        salt_block[salt_len + 3] = (uint8_t)(block_index);
        hmac_digest(&hk, salt_block, seed_len, u);
        memcpy(t, u, 32);

        for (uint32_t i = 1; i < iterations; i++) {
            hmac_digest(&hk, u, 32, u);
            for (int j = 0; j < 32; j++) {
                t[j] ^= u[j];
            }
        }

        size_t take = out_len < 32 ? out_len : 32;
        memcpy(out, t, take);
        out += take;
        out_len -= take;
        block_index++;
    }
}

// ---------------------------------------------------------------------------
// HKDF-SHA256 (RFC 5869), salt fixed to 32 zero bytes
// ---------------------------------------------------------------------------

void eul_hkdf_sha256(
    const uint8_t *ikm, size_t ikm_len,
    const uint8_t *info, size_t info_len,
    uint8_t *out, size_t out_len
) {
    static const uint8_t zeros[32] = { 0 };
    uint8_t prk[32];
    eul_hmac_sha256(zeros, sizeof zeros, ikm, ikm_len, prk);

    uint8_t t[32];
    size_t t_len = 0;
    uint8_t counter = 1;
    while (out_len > 0) {
        uint8_t block[64 + 256];
        size_t seed_len = t_len + info_len + 1;
        if (seed_len > sizeof block) {
            return; // info too long; callers use short labels
        }
        memcpy(block, t, t_len);
        if (info_len > 0) { // info may be NULL for an empty label
            memcpy(block + t_len, info, info_len);
        }
        block[t_len + info_len] = counter;
        eul_hmac_sha256(prk, sizeof prk, block, seed_len, t);
        t_len = 32;
        size_t take = out_len < 32 ? out_len : 32;
        memcpy(out, t, take);
        out += take;
        out_len -= take;
        counter++;
    }
}

// ---------------------------------------------------------------------------
// ChaCha20 (RFC 8439 §2.3)
// ---------------------------------------------------------------------------

#define ROL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

#define QR(a, b, c, d)                       \
    do {                                     \
        a += b; d ^= a; d = ROL32(d, 16);    \
        c += d; b ^= c; b = ROL32(b, 12);    \
        a += b; d ^= a; d = ROL32(d, 8);     \
        c += d; b ^= c; b = ROL32(b, 7);     \
    } while (0)

static void chacha20_block(
    const uint8_t key[32],
    const uint8_t nonce[12],
    uint32_t counter,
    uint8_t out[64]
) {
    uint32_t s[16] = {
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        (uint32_t)(key[0] | key[1] << 8 | key[2] << 16 | (uint32_t)key[3] << 24),
        (uint32_t)(key[4] | key[5] << 8 | key[6] << 16 | (uint32_t)key[7] << 24),
        (uint32_t)(key[8] | key[9] << 8 | key[10] << 16 | (uint32_t)key[11] << 24),
        (uint32_t)(key[12] | key[13] << 8 | key[14] << 16 | (uint32_t)key[15] << 24),
        (uint32_t)(key[16] | key[17] << 8 | key[18] << 16 | (uint32_t)key[19] << 24),
        (uint32_t)(key[20] | key[21] << 8 | key[22] << 16 | (uint32_t)key[23] << 24),
        (uint32_t)(key[24] | key[25] << 8 | key[26] << 16 | (uint32_t)key[27] << 24),
        (uint32_t)(key[28] | key[29] << 8 | key[30] << 16 | (uint32_t)key[31] << 24),
        counter,
        (uint32_t)(nonce[0] | nonce[1] << 8 | nonce[2] << 16 | (uint32_t)nonce[3] << 24),
        (uint32_t)(nonce[4] | nonce[5] << 8 | nonce[6] << 16 | (uint32_t)nonce[7] << 24),
        (uint32_t)(nonce[8] | nonce[9] << 8 | nonce[10] << 16 | (uint32_t)nonce[11] << 24),
    };
    uint32_t x[16];
    memcpy(x, s, sizeof x);

    for (int i = 0; i < 10; i++) {
        QR(x[0], x[4], x[8], x[12]);
        QR(x[1], x[5], x[9], x[13]);
        QR(x[2], x[6], x[10], x[14]);
        QR(x[3], x[7], x[11], x[15]);
        QR(x[0], x[5], x[10], x[15]);
        QR(x[1], x[6], x[11], x[12]);
        QR(x[2], x[7], x[8], x[13]);
        QR(x[3], x[4], x[9], x[14]);
    }

    for (int i = 0; i < 16; i++) {
        uint32_t v = x[i] + s[i];
        out[i * 4] = (uint8_t)v;
        out[i * 4 + 1] = (uint8_t)(v >> 8);
        out[i * 4 + 2] = (uint8_t)(v >> 16);
        out[i * 4 + 3] = (uint8_t)(v >> 24);
    }
}

// ---------------------------------------------------------------------------
// Poly1305 (RFC 8439 §2.5) — poly1305-donna style
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t r[5];
    uint32_t h[5];
    uint32_t pad[4];
    size_t leftover;
    uint8_t buffer[16];
} poly1305_ctx;

static uint32_t le32(const uint8_t *b) {
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}

static void poly1305_init(poly1305_ctx *ctx, const uint8_t key[32]) {
    // r is the 16-byte little-endian integer clamped to 2^130 - 16
    ctx->r[0] = (le32(key + 0)      ) & 0x3ffffff;
    ctx->r[1] = (le32(key + 3) >>  2) & 0x3ffff03;
    ctx->r[2] = (le32(key + 6) >>  4) & 0x3ffc0ff;
    ctx->r[3] = (le32(key + 9) >>  6) & 0x3f03fff;
    ctx->r[4] = (le32(key + 12) >>  8) & 0x00fffff;

    for (int i = 0; i < 5; i++) {
        ctx->h[i] = 0;
    }
    for (int i = 0; i < 4; i++) {
        ctx->pad[i] = le32(key + 16 + i * 4);
    }
    ctx->leftover = 0;
}

static void poly1305_blocks(poly1305_ctx *ctx, const uint8_t *m, size_t bytes, uint32_t hibit) {
    // hibit: 2^128 on every full block (RFC 8439 §2.5.2), 0 for the padded
    // final block — the appended 0x01 byte already carries that weight
    uint32_t r0 = ctx->r[0], r1 = ctx->r[1], r2 = ctx->r[2], r3 = ctx->r[3], r4 = ctx->r[4];
    uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    uint32_t h0 = ctx->h[0], h1 = ctx->h[1], h2 = ctx->h[2], h3 = ctx->h[3], h4 = ctx->h[4];

    while (bytes >= 16) {
        uint32_t t0 = le32(m);
        uint32_t t1 = le32(m + 4);
        uint32_t t2 = le32(m + 8);
        uint32_t t3 = le32(m + 12);

        h0 += t0 & 0x3ffffff;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x3ffffff;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x3ffffff;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x3ffffff;
        h4 += (t3 >> 8) | hibit;

        uint64_t d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
        uint64_t d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
        uint64_t d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
        uint64_t d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
        uint64_t d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

        uint64_t c;
        c = d0 >> 26; h0 = (uint32_t)d0 & 0x3ffffff;
        d1 += c; c = d1 >> 26; h1 = (uint32_t)d1 & 0x3ffffff;
        d2 += c; c = d2 >> 26; h2 = (uint32_t)d2 & 0x3ffffff;
        d3 += c; c = d3 >> 26; h3 = (uint32_t)d3 & 0x3ffffff;
        d4 += c; c = d4 >> 26; h4 = (uint32_t)d4 & 0x3ffffff;
        h0 += (uint32_t)c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
        h1 += c;

        m += 16;
        bytes -= 16;
    }

    ctx->h[0] = h0; ctx->h[1] = h1; ctx->h[2] = h2; ctx->h[3] = h3; ctx->h[4] = h4;
}

static void poly1305_finish(poly1305_ctx *ctx, uint8_t mac[16]) {
    if (ctx->leftover) {
        size_t i = ctx->leftover;
        ctx->buffer[i++] = 1;
        for (; i < 16; i++) {
            ctx->buffer[i] = 0;
        }
        poly1305_blocks(ctx, ctx->buffer, 16, 0);
        ctx->leftover = 0;
    }

    uint32_t h0 = ctx->h[0], h1 = ctx->h[1], h2 = ctx->h[2], h3 = ctx->h[3], h4 = ctx->h[4];
    uint32_t c;
    uint32_t g0, g1, g2, g3, g4;

    // fully carry h
    c = h1 >> 26; h1 &= 0x3ffffff;
    h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
    h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
    h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
    h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
    h1 += c;

    // compute h + -p
    g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
    g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
    g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
    g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
    g4 = h4 + c - (1U << 26);

    // select h if h < p, or h + -p if h >= p
    uint32_t mask = (g4 >> 31) - 1;
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    h0 = (h0 & mask) | g0;
    h1 = (h1 & mask) | g1;
    h2 = (h2 & mask) | g2;
    h3 = (h3 & mask) | g3;
    h4 = (h4 & mask) | g4;

    // h = h % (2^128), then mac = (h + pad) % (2^128)
    uint64_t h64 = (uint64_t)h0 | (uint64_t)h1 << 26 | (uint64_t)h2 << 52;
    uint64_t h64b = (uint64_t)h2 >> 12 | (uint64_t)h3 << 14 | (uint64_t)h4 << 40;
    uint64_t pad_lo = (uint64_t)ctx->pad[0] | (uint64_t)ctx->pad[1] << 32;
    uint64_t pad_hi = (uint64_t)ctx->pad[2] | (uint64_t)ctx->pad[3] << 32;
    uint64_t lo = h64 + pad_lo;
    uint64_t hi = h64b + pad_hi + (lo < h64);

    mac[0] = (uint8_t)lo;
    mac[1] = (uint8_t)(lo >> 8);
    mac[2] = (uint8_t)(lo >> 16);
    mac[3] = (uint8_t)(lo >> 24);
    mac[4] = (uint8_t)(lo >> 32);
    mac[5] = (uint8_t)(lo >> 40);
    mac[6] = (uint8_t)(lo >> 48);
    mac[7] = (uint8_t)(lo >> 56);
    mac[8] = (uint8_t)hi;
    mac[9] = (uint8_t)(hi >> 8);
    mac[10] = (uint8_t)(hi >> 16);
    mac[11] = (uint8_t)(hi >> 24);
    mac[12] = (uint8_t)(hi >> 32);
    mac[13] = (uint8_t)(hi >> 40);
    mac[14] = (uint8_t)(hi >> 48);
    mac[15] = (uint8_t)(hi >> 56);
}

static void poly1305_update(poly1305_ctx *ctx, const uint8_t *m, size_t bytes) {
    if (ctx->leftover) {
        size_t want = 16 - ctx->leftover;
        if (want > bytes) {
            want = bytes;
        }
        for (size_t i = 0; i < want; i++) {
            ctx->buffer[ctx->leftover + i] = m[i];
        }
        bytes -= want;
        m += want;
        ctx->leftover += want;
        if (ctx->leftover < 16) {
            return;
        }
        poly1305_blocks(ctx, ctx->buffer, 16, 1U << 24);
        ctx->leftover = 0;
    }
    size_t want = bytes & ~((size_t)15);
    if (want) {
        poly1305_blocks(ctx, m, want, 1U << 24);
        m += want;
        bytes -= want;
    }
    if (bytes) {
        for (size_t i = 0; i < bytes; i++) {
            ctx->buffer[ctx->leftover + i] = m[i];
        }
        ctx->leftover = bytes;
    }
}

// ---------------------------------------------------------------------------
// ChaCha20-Poly1305 AEAD (RFC 8439 §2.8)
// ---------------------------------------------------------------------------

static void le64(uint8_t *out, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        out[i] = (uint8_t)(v >> (i * 8));
    }
}

static void aead_mac(
    const uint8_t poly_key[32],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *ct, size_t ct_len,
    uint8_t tag[16]
) {
    poly1305_ctx ctx;
    poly1305_init(&ctx, poly_key);

    static const uint8_t zeros[16] = { 0 };
    if (aad_len > 0) {
        poly1305_update(&ctx, aad, aad_len);
        poly1305_update(&ctx, zeros, (16 - (aad_len % 16)) % 16);
    }
    if (ct_len > 0) {
        poly1305_update(&ctx, ct, ct_len);
        poly1305_update(&ctx, zeros, (16 - (ct_len % 16)) % 16);
    }
    uint8_t lengths[16];
    le64(lengths, (uint64_t)aad_len);
    le64(lengths + 8, (uint64_t)ct_len);
    poly1305_update(&ctx, lengths, 16);

    poly1305_finish(&ctx, tag);
}

static void xor_stream(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *in, uint8_t *out, size_t len
) {
    uint8_t block[64];
    for (size_t i = 0, counter = 1; i < len; i += 64, counter++) {
        chacha20_block(key, nonce, (uint32_t)counter, block);
        size_t take = len - i < 64 ? len - i : 64;
        for (size_t j = 0; j < take; j++) {
            out[i + j] = in[i + j] ^ block[j];
        }
    }
}

static int constant_time_eq(const uint8_t *a, const uint8_t *b, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

void eul_chachapoly_seal(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *pt, size_t pt_len,
    uint8_t *out
) {
    uint8_t *ct = out + 12;
    memcpy(out, nonce, 12);
    xor_stream(key, nonce, pt, ct, pt_len);

    uint8_t poly_key[32];
    uint8_t zero_block[64];
    chacha20_block(key, nonce, 0, zero_block);
    memcpy(poly_key, zero_block, 32);

    uint8_t tag[16];
    aead_mac(poly_key, aad, aad_len, ct, pt_len, tag);
    memcpy(ct + pt_len, tag, 16);
}

int eul_chachapoly_open(
    const uint8_t key[32],
    const uint8_t *combined, size_t combined_len,
    const uint8_t *aad, size_t aad_len,
    uint8_t *pt
) {
    if (combined_len < 28) {
        return 0;
    }
    size_t ct_len = combined_len - 28;
    const uint8_t *nonce = combined;
    const uint8_t *ct = combined + 12;
    const uint8_t *tag = ct + ct_len;

    uint8_t poly_key[32];
    uint8_t zero_block[64];
    chacha20_block(key, nonce, 0, zero_block);
    memcpy(poly_key, zero_block, 32);

    uint8_t computed[16];
    aead_mac(poly_key, aad, aad_len, ct, ct_len, computed);
    if (!constant_time_eq(computed, tag, 16)) {
        return 0;
    }

    xor_stream(key, nonce, ct, pt, ct_len);
    return 1;
}
