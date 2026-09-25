//
//  peer.c
//  eul (linux)
//

#include "peer.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "crypto.h"
#include "json.h"
#include "mqtt.h"

#define SHARE_INTERVAL 5.0
#define EXPIRY_SECONDS 16.0
#define MAX_AGE_SECONDS 60.0
#define CONNECT_TIMEOUT_MS 4000
#define RECONNECT_PAUSE 5
#define MQTT_KEEPALIVE 60 // must match mqtt.c

/// free, open brokers — the same rooms the Mac app uses; plain-TCP ports.
/// Every one is joined at once, like the Mac app: two peers that each fell
/// back to a different broker would otherwise never meet
static const char *const default_brokers[] = {
    "broker.emqx.io:1883",
    "broker.hivemq.com:1883",
    "test.mosquitto.org:1883",
};

static double mono_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int peer_unit_is_celsius(const char *unit) {
    return strcmp(unit, "celius") == 0 || strcmp(unit, "celsius") == 0
           || strcmp(unit, "c") == 0 || strcmp(unit, "C") == 0;
}

double peer_temperature_celsius(const peer_entry *p) {
    if (p->temperature < 0) {
        return -1;
    }
    double celsius;
    if (peer_unit_is_celsius(p->temperature_unit)) {
        celsius = p->temperature;
    } else if (strcmp(p->temperature_unit, "fahrenheit") == 0
               || strcmp(p->temperature_unit, "f") == 0) {
        celsius = (p->temperature - 32) / 1.8;
    } else if (strcmp(p->temperature_unit, "kelvin") == 0
               || strcmp(p->temperature_unit, "k") == 0) {
        celsius = p->temperature - 273.15;
    } else {
        return -1;
    }
    return celsius;
}

// --- key derivation (must mirror PeerDiscoveryStore.deriveKeys) -----------

void peer_derive_keys(const char *secret, char *topic, size_t topic_cap, uint8_t seal_key[32]) {
    static const uint8_t salt[] = "eul-peer";
    uint8_t master[32];
    eul_pbkdf2_hmac_sha256((const uint8_t *)secret, strlen(secret),
                           salt, sizeof salt - 1, 200000, master, sizeof master);

    uint8_t topic_key[32];
    eul_hkdf_sha256(master, sizeof master, (const uint8_t *)"topic", 5, topic_key, sizeof topic_key);
    char hex[33];
    for (int i = 0; i < 16; i++) {
        snprintf(hex + i * 2, 3, "%02x", topic_key[i]);
    }
    snprintf(topic, topic_cap, "eul-peer/%s", hex);

    eul_hkdf_sha256(master, sizeof master, (const uint8_t *)"seal", 4, seal_key, 32);
}

void peer_generate_secret(char *out, size_t cap) {
    // 4 groups of 5 from an alphabet without look-alikes, ~99 bits —
    // mirrors PeerDiscoveryStore.generateSecret
    static const char alphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
    const unsigned symbols = sizeof alphabet - 1; // 31
    size_t len = 0;
    for (int g = 0; g < 4 && len + 1 < cap; g++) {
        if (g > 0) {
            out[len++] = '-';
        }
        for (int i = 0; i < 5 && len + 1 < cap;) {
            uint8_t byte;
            eul_random_bytes(&byte, 1);
            // rejection sampling: 248 = 8 × 31, so every symbol is equally likely
            if (byte < 256 - 256 % symbols) {
                out[len++] = alphabet[byte % symbols];
                i++;
            }
        }
    }
    out[len] = '\0';
}

// --- snapshots --------------------------------------------------------------

/// Swift's JSONEncoder dates: seconds since 2001-01-01
#define REFERENCE_DATE_OFFSET 978307200.0

typedef struct {
    const char *id;
    const char *name;
    double sent_at;
    double cpu, memory, gpu, temperature; // -1 = omit
    double net_in, net_out;
    // the fields the Mac app's panel adds in 2.3 for its remote view
    int core_count;
    double cores[EUL_MAX_CORES];
    double disk_free, disk_total; // -1 = omit
    char uptime[32];               // "" = omit
} outgoing_snapshot;

/// JSON has no NaN/inf, and the Mac's decoder rejects the whole snapshot
static void put_number(json_writer *w, double v) {
    json_put_double(w, isfinite(v) ? v : 0);
}

/// returns 0 when the snapshot did not fit — never publish truncated JSON
static int build_snapshot_json(const outgoing_snapshot *s, char *buf, size_t cap) {
    json_writer w;
    json_writer_init(&w, buf, cap);
    json_put_raw(&w, "{\"id\":");
    json_put_string(&w, s->id);
    json_put_raw(&w, ",\"name\":");
    json_put_string(&w, s->name);
    json_put_raw(&w, ",\"sentAt\":");
    put_number(&w, s->sent_at);
    json_put_raw(&w, ",\"stats\":{");
    // temperatureUnit is not optional on the Mac side — always send it
    json_put_raw(&w, "\"temperatureUnit\":\"celius\"");
    if (s->cpu >= 0) {
        json_put_raw(&w, ",\"cpu\":");
        put_number(&w, s->cpu);
    }
    if (s->memory >= 0) {
        json_put_raw(&w, ",\"memory\":");
        put_number(&w, s->memory);
    }
    if (s->gpu >= 0) {
        json_put_raw(&w, ",\"gpu\":");
        put_number(&w, s->gpu);
    }
    if (s->temperature >= 0) {
        json_put_raw(&w, ",\"temperature\":");
        put_number(&w, s->temperature);
    }
    json_put_raw(&w, ",\"networkIn\":");
    put_number(&w, s->net_in);
    json_put_raw(&w, ",\"networkOut\":");
    put_number(&w, s->net_out);
    if (s->core_count > 0) {
        json_put_raw(&w, ",\"cores\":[");
        for (int i = 0; i < s->core_count; i++) {
            json_put_raw(&w, i ? "," : "");
            json_put_long(&w, isfinite(s->cores[i]) ? lround(s->cores[i]) : 0);
        }
        json_put_raw(&w, "]");
    }
    if (s->disk_total > 0 && s->disk_free >= 0) {
        // UInt64 on the Mac side — integers, not "123.000"; and 64-bit even
        // where long is 32 (armv7)
        char bytes[64];
        snprintf(bytes, sizeof bytes, ",\"diskFree\":%llu,\"diskTotal\":%llu",
                 (unsigned long long)s->disk_free, (unsigned long long)s->disk_total);
        json_put_raw(&w, bytes);
    }
    if (s->uptime[0]) {
        json_put_raw(&w, ",\"uptime\":");
        json_put_string(&w, s->uptime);
    }
    json_put_raw(&w, "}}");
    return !w.truncated;
}

/// decodes a peer's snapshot JSON (as produced by Swift's JSONEncoder)
int peer_decode_snapshot(const uint8_t *data, size_t len, peer_entry *out) {
    json_reader root;
    if (!json_begin(&root, (const char *)data, len)) {
        return 0;
    }
    memset(out, 0, sizeof *out);
    out->cpu = out->memory = out->gpu = out->temperature = -1;
    out->net_in = out->net_out = 0;
    out->last_seen = mono_now();

    json_reader top_reader = root;
    if (json_find(&root, "id")) {
        if (!json_read_string(&root, out->id, PEER_ID_LEN)) {
            return 0;
        }
    }
    root = top_reader;
    if (json_find(&root, "name")) {
        if (!json_read_string(&root, out->name, PEER_NAME_LEN)) {
            return 0;
        }
    }
    root = top_reader;
    double sent_at = 0;
    if (json_find(&root, "sentAt")) {
        if (!json_read_double(&root, &sent_at)) {
            return 0;
        }
    }
    root = top_reader;
    // each lookup restarts from the stats object; a failed find consumes
    // the object, so every FIND rewinds first
#define FIND(key)                          \
    do {                                   \
        root = stats_reader;               \
        found = json_find(&root, key);     \
    } while (0)
    if (json_find(&root, "stats")) {
        json_reader stats_reader = root;
        int found = 0;
        FIND("cpu");
        if (found) {
            json_read_double(&root, &out->cpu);
        }
        FIND("memory");
        if (found) {
            json_read_double(&root, &out->memory);
        }
        FIND("gpu");
        if (found) {
            json_read_double(&root, &out->gpu);
        }
        FIND("temperature");
        if (found) {
            json_read_double(&root, &out->temperature);
        }
        FIND("temperatureUnit");
        if (found) {
            json_read_string(&root, out->temperature_unit,
                             sizeof out->temperature_unit);
        }
        FIND("networkIn");
        if (found) {
            json_read_double(&root, &out->net_in);
        }
        FIND("networkOut");
        if (found) {
            json_read_double(&root, &out->net_out);
        }
    }
#undef FIND
    if (out->id[0] == '\0') {
        return 0;
    }
    // the name came off the network: no terminal control bytes (the
    // payload is authenticated, but a peer is still someone else's machine)
    for (char *c = out->name; *c; c++) {
        if ((unsigned char)*c < 0x20 || *c == 0x7f) {
            *c = '?';
        }
    }
    // replayed snapshots older than a minute are dropped (mirror the Mac app)
    double now_ref = (double)time(NULL) - REFERENCE_DATE_OFFSET;
    double age = now_ref - sent_at;
    if (age < -MAX_AGE_SECONDS || age > MAX_AGE_SECONDS) {
        return 0;
    }
    return 1;
}

// --- share thread -------------------------------------------------------------

static void record_peer(peer_store *ps, const peer_entry *incoming, const char *self_id) {
    if (strcmp(incoming->id, self_id) == 0) {
        return; // the broker echoes our own publishes back
    }
    peer_entry *slot = NULL;
    for (int i = 0; i < ps->peer_count; i++) {
        if (strcmp(ps->peers[i].id, incoming->id) == 0) {
            slot = &ps->peers[i];
            break;
        }
    }
    if (!slot && ps->peer_count < PEER_MAX) {
        slot = &ps->peers[ps->peer_count++];
    }
    if (!slot) {
        return;
    }
    *slot = *incoming;
}

static void prune_peers(peer_store *ps) {
    double now = mono_now();
    int i = 0;
    while (i < ps->peer_count) {
        if (now - ps->peers[i].last_seen > EXPIRY_SECONDS) {
            ps->peers[i] = ps->peers[--ps->peer_count];
        } else {
            i++;
        }
    }
}

/// one sample of the numbers the Mac app's snapshot carries
static void sample_for_share(stats_ctx *ctx, outgoing_snapshot *snap,
                             const char *self_id, const char *self_name) {
    system_stats stats;
    stats_sample(ctx, &stats);
    snap->id = self_id;
    snap->name = self_name;
    snap->sent_at = (double)time(NULL) - REFERENCE_DATE_OFFSET;
    snap->cpu = stats.cpu_count > 0 ? stats.cpu_usage_pct : -1;
    snap->memory = stats.mem_total_b > 0 ? stats.mem_used_pct : -1;
    snap->gpu = stats.has_gpu ? stats.gpu_pct : -1; // AMD/NVIDIA only
    snap->temperature = stats.has_temp ? stats.temp_c : -1;
    snap->net_in = stats.net_rx_bps;
    snap->net_out = stats.net_tx_bps;

    snap->core_count = stats.cpu_count < EUL_MAX_CORES ? stats.cpu_count : EUL_MAX_CORES;
    for (int i = 0; i < snap->core_count; i++) {
        snap->cores[i] = stats.cpu_core[i];
    }
    snap->disk_free = snap->disk_total = -1;
    for (int i = 0; i < stats.disk_count; i++) {
        if (strcmp(stats.disks[i].mount, "/") == 0) {
            snap->disk_free = stats.disks[i].free_b;
            snap->disk_total = stats.disks[i].total_b;
            break;
        }
    }
    snap->uptime[0] = '\0';
    if (stats.uptime_s > 0) {
        // the Mac's own upTimeString format
        long total = (long)stats.uptime_s;
        long days = total / 86400, hrs = (total % 86400) / 3600, mins = (total % 3600) / 60;
        if (days > 0) {
            snprintf(snap->uptime, sizeof snap->uptime, "%ldd %ldh %ldm", days, hrs, mins);
        } else {
            snprintf(snap->uptime, sizeof snap->uptime, "%ldh %ldm", hrs, mins);
        }
    }
}

/// one broker connection; all of them are kept up side by side
typedef struct {
    char host[96];
    char port[8];
    mqtt_conn conn;
    double retry_at;
    double last_ping;
} relay_link;

static void publish_status(peer_store *ps, const relay_link *links, int count) {
    pthread_mutex_lock(&ps->lock);
    ps->connected = 0;
    ps->broker_label[0] = '\0';
    size_t used = 0;
    for (int i = 0; i < count; i++) {
        if (links[i].conn.fd < 0) {
            continue;
        }
        int n = snprintf(ps->broker_label + used, sizeof ps->broker_label - used,
                         "%s%s", ps->connected ? ", " : "", links[i].host);
        if (n > 0 && used + (size_t)n < sizeof ps->broker_label) {
            used += (size_t)n;
        }
        ps->connected++;
    }
    pthread_mutex_unlock(&ps->lock);
}

static void drop_link(relay_link *link) {
    mqtt_close(&link->conn);
    link->retry_at = mono_now() + RECONNECT_PAUSE;
}

static void *share_thread(void *arg) {
    peer_store *ps = arg;

    stats_ctx share_ctx;
    stats_init(&share_ctx);
    system_stats warm;
    stats_sample(&share_ctx, &warm); // prime the delta baseline

    char self_id[PEER_ID_LEN];
    char self_name[PEER_NAME_LEN];
    char topic[80];
    uint8_t seal_key[32];
    char brokers[8][96];
    pthread_mutex_lock(&ps->lock);
    snprintf(self_id, sizeof self_id, "%s", ps->self_id);
    snprintf(self_name, sizeof self_name, "%s", ps->self_name);
    snprintf(topic, sizeof topic, "%s", ps->topic);
    memcpy(seal_key, ps->seal_key, 32);
    int broker_count = ps->broker_count;
    for (int i = 0; i < broker_count; i++) {
        snprintf(brokers[i], sizeof brokers[i], "%s", ps->brokers[i]);
    }
    pthread_mutex_unlock(&ps->lock);
    if (broker_count == 0) {
        broker_count = (int)(sizeof default_brokers / sizeof default_brokers[0]);
        for (int i = 0; i < broker_count; i++) {
            snprintf(brokers[i], sizeof brokers[i], "%s", default_brokers[i]);
        }
    }

    relay_link links[8];
    int link_count = 0;
    for (int i = 0; i < broker_count; i++) {
        const char *colon = strrchr(brokers[i], ':');
        if (!colon || colon == brokers[i] || !colon[1]) {
            fprintf(stderr, "eul: ignoring broker \"%s\" (want host:port)\n", brokers[i]);
            continue;
        }
        relay_link *link = &links[link_count++];
        memset(link, 0, sizeof *link);
        snprintf(link->host, sizeof link->host, "%.*s", (int)(colon - brokers[i]), brokers[i]);
        snprintf(link->port, sizeof link->port, "%s", colon + 1);
        link->conn.fd = -1;
    }

    uint8_t instance[4];
    eul_random_bytes(instance, sizeof instance);
    char client_id[32];
    snprintf(client_id, sizeof client_id, "eul-linux-%02x%02x%02x%02x",
             instance[0], instance[1], instance[2], instance[3]);

    char json[2048];
    uint8_t sealed[sizeof json + 28];
    uint8_t msg[4096];
    uint8_t plain[sizeof msg];
    double last_publish = 0;

    while (1) {
        pthread_mutex_lock(&ps->lock);
        int running = ps->running;
        pthread_mutex_unlock(&ps->lock);
        if (!running) {
            break;
        }

        // (re)connect whatever is down and due
        int changed = 0;
        for (int i = 0; i < link_count; i++) {
            relay_link *link = &links[i];
            if (link->conn.fd >= 0 || mono_now() < link->retry_at) {
                continue;
            }
            if (mqtt_connect(&link->conn, link->host, link->port, client_id, CONNECT_TIMEOUT_MS)
                && mqtt_subscribe(&link->conn, topic)) {
                link->last_ping = mono_now();
            } else {
                drop_link(link);
            }
            changed = 1;
        }
        if (changed) {
            publish_status(ps, links, link_count);
        }

        double now = mono_now();
        int live = 0;
        for (int i = 0; i < link_count; i++) {
            live += links[i].conn.fd >= 0;
        }
        if (live == 0) {
            struct timespec ts = { 0, 200 * 1000 * 1000 };
            nanosleep(&ts, NULL);
            continue;
        }

        // every 5 s, one sealed snapshot to every broker
        if (now - last_publish >= SHARE_INTERVAL) {
            last_publish = now;
            outgoing_snapshot snap;
            sample_for_share(&share_ctx, &snap, self_id, self_name);
            if (build_snapshot_json(&snap, json, sizeof json)) {
                size_t json_len = strlen(json);
                uint8_t nonce[12];
                eul_random_bytes(nonce, sizeof nonce);
                eul_chachapoly_seal(seal_key, nonce, NULL, 0, (const uint8_t *)json, json_len, sealed);
                for (int i = 0; i < link_count; i++) {
                    if (links[i].conn.fd >= 0 && !mqtt_publish(&links[i].conn, topic, sealed, json_len + 28)) {
                        drop_link(&links[i]);
                        changed = 1;
                    }
                }
            }
        }

        for (int i = 0; i < link_count; i++) {
            relay_link *link = &links[i];
            if (link->conn.fd < 0) {
                continue;
            }
            // ping at half the keepalive; nothing back for 1.5× it and the
            // link is dead even if TCP has not noticed yet
            if (now - link->last_ping >= MQTT_KEEPALIVE / 2) {
                link->last_ping = now;
                if (!mqtt_ping(&link->conn)) {
                    drop_link(link);
                    changed = 1;
                    continue;
                }
            }
            if (mqtt_idle_seconds(&link->conn) > MQTT_KEEPALIVE * 1.5) {
                drop_link(link);
                changed = 1;
                continue;
            }

            // the wait is shared out across the links; then drain what arrived
            int timeout = 250 / live;
            size_t msg_len = 0;
            int got;
            while ((got = mqtt_poll(&link->conn, timeout, msg, sizeof msg, &msg_len)) > 0) {
                timeout = 0;
                peer_entry incoming;
                if (msg_len >= 28
                    && eul_chachapoly_open(seal_key, msg, msg_len, NULL, 0, plain)
                    && peer_decode_snapshot(plain, msg_len - 28, &incoming)) {
                    pthread_mutex_lock(&ps->lock);
                    record_peer(ps, &incoming, self_id);
                    pthread_mutex_unlock(&ps->lock);
                }
            }
            if (got < 0) {
                drop_link(link);
                changed = 1;
            }
        }
        if (changed) {
            publish_status(ps, links, link_count);
        }

        pthread_mutex_lock(&ps->lock);
        prune_peers(ps);
        pthread_mutex_unlock(&ps->lock);
    }

    for (int i = 0; i < link_count; i++) {
        if (links[i].conn.fd >= 0) {
            mqtt_disconnect(&links[i].conn);
        }
    }
    return NULL;
}

// --- lifecycle -------------------------------------------------------------------

int peer_start(peer_store *ps, const char *secret, const char *name_override,
               const char *broker_spec) {
    memset(ps, 0, sizeof *ps);
    pthread_mutex_init(&ps->lock, NULL);

    if (broker_spec && broker_spec[0]) {
        const char *p = broker_spec;
        while (*p && ps->broker_count < (int)(sizeof ps->brokers / sizeof ps->brokers[0])) {
            const char *comma = strchr(p, ',');
            size_t len = comma ? (size_t)(comma - p) : strlen(p);
            while (len > 0 && *p == ' ') {
                p++;
                len--;
            }
            if (len > 0 && len < sizeof ps->brokers[0]) {
                snprintf(ps->brokers[ps->broker_count++], sizeof ps->brokers[0],
                         "%.*s", (int)len, p);
            }
            if (!comma) {
                break;
            }
            p = comma + 1;
        }
    }


    // trim a stray space from copying the secret over — only at the ends,
    // exactly like the Mac's trimmingCharacters(in: .whitespacesAndNewlines);
    // a secret with inner spaces must derive the same keys on both sides
    const char *begin = secret;
    while (*begin == ' ' || *begin == '\n' || *begin == '\r' || *begin == '\t') {
        begin++;
    }
    size_t trimmed_len = strlen(begin);
    while (trimmed_len > 0 && (begin[trimmed_len - 1] == ' ' || begin[trimmed_len - 1] == '\n'
                               || begin[trimmed_len - 1] == '\r' || begin[trimmed_len - 1] == '\t')) {
        trimmed_len--;
    }
    if (trimmed_len == 0 || trimmed_len >= sizeof ps->secret) {
        return 0;
    }
    memcpy(ps->secret, begin, trimmed_len);
    ps->secret[trimmed_len] = '\0';

    peer_derive_keys(ps->secret, ps->topic, sizeof ps->topic, ps->seal_key);

    // per-launch instance id: a restarted peer simply shows up as new
    uint8_t raw[16];
    eul_random_bytes(raw, sizeof raw);
    snprintf(ps->self_id, sizeof ps->self_id,
             "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
             raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]);

    char hostname[128];
    gethostname(hostname, sizeof hostname - 1);
    hostname[sizeof hostname - 1] = '\0';
    char *dot = strstr(hostname, ".local");
    if (dot) {
        *dot = '\0';
    }
    if (name_override && name_override[0]) {
        snprintf(ps->self_name, sizeof ps->self_name, "%s", name_override);
    } else {
        snprintf(ps->self_name, sizeof ps->self_name, "%s", hostname);
    }

    ps->connected = 0;
    ps->running = 1;
    if (pthread_create(&ps->thread, NULL, share_thread, ps) != 0) {
        ps->running = 0;
        return 0;
    }
    return 1;
}

void peer_stop(peer_store *ps) {
    pthread_mutex_lock(&ps->lock);
    ps->running = 0;
    pthread_mutex_unlock(&ps->lock);
    pthread_join(ps->thread, NULL);
    pthread_mutex_destroy(&ps->lock);
}
