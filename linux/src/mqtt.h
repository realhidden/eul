//
//  mqtt.h
//  eul (linux)
//
//  Minimal MQTT 3.1.1 client — QoS 0 publish/subscribe on one topic over
//  plain TCP, just enough to use a public broker as a relay. Mirrors the
//  Mac app's MQTTClient: clean session, keepalive 60, rotate on failure.
//  Snapshots are sealed before they ever reach this layer, so the link
//  being plaintext is fine.
//

#ifndef EUL_MQTT_H
#define EUL_MQTT_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int fd;
    char host[128];
    char port[8];
    uint8_t buf[4096];
    size_t buf_len;
    /// bytes still to drop from a packet too big for `buf` — anyone can
    /// publish to a public topic, so that must not cost us the connection
    size_t discard;
    /// monotonic time of the last byte received, for the liveness watchdog
    double last_rx;
} mqtt_conn;

/// blocking TCP connect with timeout, then CONNECT/CONNACK
int mqtt_connect(mqtt_conn *m, const char *host, const char *port, const char *client_id,
                 int timeout_ms);

/// SUBSCRIBE at QoS 0; call once after a successful connect
int mqtt_subscribe(mqtt_conn *m, const char *topic);

/// PUBLISH at QoS 0
int mqtt_publish(mqtt_conn *m, const char *topic, const uint8_t *payload, size_t len);

int mqtt_ping(mqtt_conn *m);

/// returns one buffered PUBLISH if there is one, otherwise waits up to
/// `timeout_ms` for more bytes; on a PUBLISH copies the payload out.
/// returns 1 on message, 0 on idle/keepalive tick, -1 on dead connection.
/// Call again while it returns 1 — one read can carry several messages.
int mqtt_poll(mqtt_conn *m, int timeout_ms, uint8_t *msg, size_t cap, size_t *msg_len);

/// seconds since the broker last sent anything (PINGRESP included)
double mqtt_idle_seconds(const mqtt_conn *m);

void mqtt_close(mqtt_conn *m);

/// sends DISCONNECT first
void mqtt_disconnect(mqtt_conn *m);

#endif
