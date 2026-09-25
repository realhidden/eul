//
//  mqtt.c
//  eul (linux)
//

#include "mqtt.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MQTT_KEEPALIVE 60
/// a broker that accepts TCP but never answers must not hang the thread
#define IO_TIMEOUT_SECONDS 10

static double mono_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int send_all(int fd, const uint8_t *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, data + off, len - off, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            return 0;
        }
        off += (size_t)n;
    }
    return 1;
}

static void write_packet_header(uint8_t *out, size_t *len, uint8_t header, size_t body_len) {
    out[(*len)++] = header;
    size_t rem = body_len;
    do {
        uint8_t byte = (uint8_t)(rem % 128);
        rem /= 128;
        if (rem > 0) {
            byte |= 0x80;
        }
        out[(*len)++] = byte;
    } while (rem > 0);
}

static void write_string(uint8_t *out, size_t *len, const char *s) {
    size_t n = strlen(s);
    out[(*len)++] = (uint8_t)(n >> 8);
    out[(*len)++] = (uint8_t)(n & 0xff);
    memcpy(out + *len, s, n);
    *len += n;
}

int mqtt_connect(mqtt_conn *m, const char *host, const char *port, const char *client_id,
                 int timeout_ms) {
    memset(m, 0, sizeof *m);
    m->fd = -1;
    snprintf(m->host, sizeof m->host, "%s", host);
    snprintf(m->port, sizeof m->port, "%s", port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *list = NULL;
    if (getaddrinfo(host, port, &hints, &list) != 0 || list == NULL) {
        return 0;
    }

    int fd = -1;
    for (struct addrinfo *ai = list; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        // non-blocking connect + poll so a dead broker can't hang the thread
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) != 0 && errno != EINPROGRESS) {
            close(fd);
            fd = -1;
            continue;
        }
        struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
        if (poll(&pfd, 1, timeout_ms) != 1) {
            close(fd);
            fd = -1;
            continue;
        }
        int err = 0;
        socklen_t err_len = sizeof err;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &err_len) != 0 || err != 0) {
            close(fd);
            fd = -1;
            continue;
        }
        fcntl(fd, F_SETFL, flags); // back to blocking, bounded by timeouts
        struct timeval tv = { IO_TIMEOUT_SECONDS, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        break;
    }
    freeaddrinfo(list);
    if (fd < 0) {
        return 0;
    }

    m->fd = fd;

    uint8_t packet[512];
    size_t len = 0;
    size_t body_len = 10 + strlen(client_id) + 2;
    write_packet_header(packet, &len, 0x10, body_len);
    write_string(packet, &len, "MQTT");
    packet[len++] = 4; // protocol level 3.1.1
    packet[len++] = 0x02; // clean session
    packet[len++] = (uint8_t)(MQTT_KEEPALIVE >> 8);
    packet[len++] = (uint8_t)(MQTT_KEEPALIVE & 0xff);
    write_string(packet, &len, client_id);
    if (!send_all(m->fd, packet, len)) {
        mqtt_close(m);
        return 0;
    }

    // CONNACK: 4 bytes
    uint8_t ack[4];
    size_t got = 0;
    while (got < sizeof ack) {
        ssize_t n = recv(m->fd, ack + got, sizeof ack - got, 0);
        if (n <= 0) {
            mqtt_close(m);
            return 0;
        }
        got += (size_t)n;
    }
    if (ack[0] != 0x20 || ack[3] != 0) {
        mqtt_close(m);
        return 0;
    }
    m->last_rx = mono_now();
    return 1;
}

int mqtt_subscribe(mqtt_conn *m, const char *topic) {
    uint8_t packet[512];
    size_t len = 0;
    write_packet_header(packet, &len, 0x82, 2 + strlen(topic) + 1 + 2);
    packet[len++] = 0; // packet id 1, high byte
    packet[len++] = 1; // low byte
    write_string(packet, &len, topic);
    packet[len++] = 0; // QoS 0
    return send_all(m->fd, packet, len);
}

int mqtt_publish(mqtt_conn *m, const char *topic, const uint8_t *payload, size_t payload_len) {
    uint8_t packet[4096];
    if (strlen(topic) + payload_len + 8 > sizeof packet) {
        return 0;
    }
    size_t len = 0;
    write_packet_header(packet, &len, 0x30, 2 + strlen(topic) + payload_len);
    write_string(packet, &len, topic);
    memcpy(packet + len, payload, payload_len);
    len += payload_len;
    return send_all(m->fd, packet, len);
}

int mqtt_ping(mqtt_conn *m) {
    static const uint8_t pingreq[] = { 0xC0, 0x00 };
    return send_all(m->fd, pingreq, sizeof pingreq);
}

/// finds the first packet in the buffer: 1 complete, 0 until more bytes
/// arrive, -1 when it can never fit and has to be discarded
static int next_packet(mqtt_conn *m, uint8_t *header, size_t *body_off, size_t *total) {
    if (m->buf_len < 2) {
        return 0;
    }
    size_t length = 0, multiplier = 1, index = 1;
    for (;;) {
        if (index > 4) {
            return -1; // remaining length is at most 4 bytes — not MQTT
        }
        if (index >= m->buf_len) {
            return 0;
        }
        uint8_t byte = m->buf[index++];
        length += (size_t)(byte & 0x7f) * multiplier;
        if ((byte & 0x80) == 0) {
            break;
        }
        multiplier *= 128;
    }
    *header = m->buf[0];
    *body_off = index;
    *total = index + length;
    if (*total > sizeof m->buf) {
        return -1;
    }
    return m->buf_len >= *total;
}

/// drops the first `n` buffered bytes
static void consume(mqtt_conn *m, size_t n) {
    memmove(m->buf, m->buf + n, m->buf_len - n);
    m->buf_len -= n;
}

/// takes packets off the buffer until one is a PUBLISH that fits `cap`
static int take_publish(mqtt_conn *m, uint8_t *msg, size_t cap, size_t *msg_len) {
    for (;;) {
        if (m->discard > 0) {
            size_t n = m->discard < m->buf_len ? m->discard : m->buf_len;
            consume(m, n);
            m->discard -= n;
            if (m->discard > 0) {
                return 0;
            }
        }
        uint8_t header = 0;
        size_t body_off = 0, total = 0; // stay 0 for a malformed length
        int state = next_packet(m, &header, &body_off, &total);
        if (state == 0) {
            return 0;
        }
        if (state < 0) {
            if (body_off == 0 || total <= sizeof m->buf) {
                return -1; // malformed length, not an oversized packet
            }
            m->discard = total;
            continue;
        }
        int found = 0;
        if ((header & 0xf0) == 0x30 && body_off + 2 <= total) { // PUBLISH
            size_t topic_len = (size_t)m->buf[body_off] << 8 | m->buf[body_off + 1];
            size_t payload_off = body_off + 2 + topic_len;
            // QoS > 0 carries a packet id; we subscribe at QoS 0 so it should not
            if ((header >> 1) & 0x03) {
                payload_off += 2;
            }
            if (payload_off <= total && total - payload_off <= cap) {
                *msg_len = total - payload_off;
                memcpy(msg, m->buf + payload_off, *msg_len);
                found = 1;
            }
        }
        // CONNACK / SUBACK / PINGRESP: nothing to do
        consume(m, total);
        if (found) {
            return 1;
        }
    }
}

int mqtt_poll(mqtt_conn *m, int timeout_ms, uint8_t *msg, size_t cap, size_t *msg_len) {
    int buffered = take_publish(m, msg, cap, msg_len);
    if (buffered != 0) {
        return buffered;
    }

    struct pollfd pfd = { .fd = m->fd, .events = POLLIN, .revents = 0 };
    int ready = poll(&pfd, 1, timeout_ms);
    if (ready <= 0) {
        if (ready < 0 && errno != EINTR) {
            return -1;
        }
        return 0;
    }

    ssize_t n = recv(m->fd, m->buf + m->buf_len, sizeof m->buf - m->buf_len, 0);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            return 0;
        }
        return -1;
    }
    m->buf_len += (size_t)n;
    m->last_rx = mono_now();
    return take_publish(m, msg, cap, msg_len);
}

double mqtt_idle_seconds(const mqtt_conn *m) {
    return mono_now() - m->last_rx;
}

void mqtt_close(mqtt_conn *m) {
    if (m->fd >= 0) {
        close(m->fd);
    }
    m->fd = -1;
    m->buf_len = 0;
    m->discard = 0;
}

void mqtt_disconnect(mqtt_conn *m) {
    static const uint8_t packet[] = { 0xE0, 0x00 };
    send_all(m->fd, packet, sizeof packet);
    mqtt_close(m);
}
