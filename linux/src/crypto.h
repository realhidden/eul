//
//  crypto.h
//  eul (linux)
//
//  SHA-256, HMAC-SHA256, PBKDF2, HKDF and ChaCha20-Poly1305 (RFC 8439),
//  implemented here so the binary stays self-contained. The eul-peer
//  protocol must stay byte-compatible with CryptoKit on the Mac side:
//  ChaChaPoly combined = nonce ‖ ciphertext ‖ 16-byte tag, empty AAD.
//

#ifndef EUL_CRYPTO_H
#define EUL_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

/// fills `out` from the kernel CSPRNG; aborts rather than ever returning
/// predictable bytes
void eul_random_bytes(uint8_t *out, size_t len);

void eul_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

void eul_hmac_sha256(
    const uint8_t *key, size_t key_len,
    const uint8_t *data, size_t data_len,
    uint8_t out[32]
);

void eul_pbkdf2_hmac_sha256(
    const uint8_t *pass, size_t pass_len,
    const uint8_t *salt, size_t salt_len,
    uint32_t iterations,
    uint8_t *out, size_t out_len
);

/// RFC 5869: salt is fixed to 32 zero bytes (what CryptoKit's HKDF uses when
/// called without one — HMAC over an empty key and a zero-padded key agree).
void eul_hkdf_sha256(
    const uint8_t *ikm, size_t ikm_len,
    const uint8_t *info, size_t info_len,
    uint8_t *out, size_t out_len
);

/// writes nonce ‖ ciphertext ‖ tag (plaintext length + 28 bytes)
void eul_chachapoly_seal(
    const uint8_t key[32],
    const uint8_t nonce[12],
    const uint8_t *aad, size_t aad_len,
    const uint8_t *pt, size_t pt_len,
    uint8_t *out
);

/// returns 1 and writes plaintext on success, 0 on authentication failure
int eul_chachapoly_open(
    const uint8_t key[32],
    const uint8_t *combined, size_t combined_len,
    const uint8_t *aad, size_t aad_len,
    uint8_t *pt
);

#endif
