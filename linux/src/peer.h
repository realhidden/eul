//
//  peer.h
//  eul (linux)
//
//  The eul-peer protocol, Linux side. A shared secret derives three keys
//  (PBKDF2-HMAC-SHA256, 200k iterations, salt "eul-peer" → HKDF-SHA256):
//  a topic token ("eul-peer/<hex>" on the public broker) and a ChaChaPoly
//  sealing key. Every 5 s each peer publishes a sealed stats snapshot; the
//  broker room is shared with the Mac app, which listens on the same topic
//  over TLS — the payload is sealed either way, so our plain link is fine.
//

#ifndef EUL_PEER_H
#define EUL_PEER_H

#include <pthread.h>
#include <stdint.h>

#include "stats.h"

#define PEER_MAX 16
#define PEER_ID_LEN 40
#define PEER_NAME_LEN 128

typedef struct {
    char id[PEER_ID_LEN];
    char name[PEER_NAME_LEN];
    // -1 when the peer doesn't report a value
    double cpu, memory, gpu, temperature;
    char temperature_unit[16]; // raw Swift enum value ("celius" included)
    double net_in, net_out;
    double last_seen; // monotonic seconds
} peer_entry;

typedef struct {
    // published state (lock covers everything below)
    pthread_mutex_t lock;
    int running;
    int connected;
    char broker_label[128]; // connected brokers, comma separated
    char self_name[PEER_NAME_LEN];
    peer_entry peers[PEER_MAX];
    int peer_count;

    // configuration, set before start
    char secret[256];
    char topic[80];
    uint8_t seal_key[32];
    char self_id[PEER_ID_LEN];
    char brokers[8][96]; // host:port overrides, 0 = default list
    int broker_count;
    pthread_t thread;
} peer_store;

/// derives keys and spawns the share thread; returns 1 on success, 0 for
/// an empty secret or a thread that would not start.
/// broker_spec: comma separated host:port list, or NULL for the defaults
int peer_start(peer_store *ps, const char *secret, const char *name_override,
               const char *broker_spec);

void peer_stop(peer_store *ps);

/// 4 groups of 5 from an alphabet without look-alikes, ~99 bits — the same
/// format the Mac app generates
void peer_generate_secret(char *out, size_t cap);

/// PBKDF2("eul-peer", 200k) -> HKDF("topic")/HKDF("seal"), the exact
/// derivation PeerDiscoveryStore performs
void peer_derive_keys(const char *secret, char *topic, size_t topic_cap,
                      uint8_t seal_key[32]);

/// decodes one plaintext snapshot JSON (as Swift's JSONEncoder emits it);
/// returns 0 and leaves `out` untouched for junk or stale snapshots
int peer_decode_snapshot(const uint8_t *data, size_t len, peer_entry *out);

/// true if `unit` is the sender's unit string for Celsius
int peer_unit_is_celsius(const char *unit);

/// converts a peer's reported temperature into Celsius (-1 when unknown)
double peer_temperature_celsius(const peer_entry *p);

#endif
