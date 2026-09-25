//
//  test_mqtt.c
//  eul (linux)
//
//  Feeds the MQTT reader byte streams through a socketpair: packets split
//  across reads, several in one read, and a packet too large for the
//  buffer — which anyone can publish to a public topic.
//

#include "../src/mqtt.h"

#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int failures = 0;

/// write() whose result the test does care about: a short write is a failure
static void put(int fd, const void *data, size_t len) {
    if (write(fd, data, len) != (ssize_t)len) {
        printf("FAIL short write\n");
        failures++;
    }
}

static void check(const char *name, int ok) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    failures += !ok;
}

/// a QoS 0 PUBLISH on topic "t" carrying `len` bytes of `fill`
static size_t publish_packet(uint8_t *out, size_t len, uint8_t fill) {
    size_t body = 2 + 1 + len, n = 0;
    out[n++] = 0x30;
    do {
        uint8_t byte = body % 128;
        body /= 128;
        out[n++] = byte | (body ? 0x80 : 0);
    } while (body);
    out[n++] = 0;
    out[n++] = 1;
    out[n++] = 't';
    memset(out + n, fill, len);
    return n + len;
}

int main(void) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        return 1;
    }
    mqtt_conn m;
    memset(&m, 0, sizeof m);
    m.fd = fds[0];
    uint8_t msg[4096], pkt[16384];
    size_t got_len = 0;

    // split across two writes
    size_t n = publish_packet(pkt, 100, 'a');
    put(fds[1], pkt, 10);
    check("half a packet is not a message", mqtt_poll(&m, 50, msg, sizeof msg, &got_len) == 0);
    put(fds[1], pkt + 10, n - 10);
    check("completed packet is delivered", mqtt_poll(&m, 50, msg, sizeof msg, &got_len) == 1 && got_len == 100 && msg[0] == 'a');

    // three packets in one write: all three come out, one per call
    size_t total = 0;
    total += publish_packet(pkt + total, 20, 'x');
    total += publish_packet(pkt + total, 30, 'y');
    pkt[total++] = 0xD0; // PINGRESP in between
    pkt[total++] = 0x00;
    total += publish_packet(pkt + total, 40, 'z');
    put(fds[1], pkt, total);
    int ok = mqtt_poll(&m, 50, msg, sizeof msg, &got_len) == 1 && got_len == 20 && msg[0] == 'x';
    ok &= mqtt_poll(&m, 0, msg, sizeof msg, &got_len) == 1 && got_len == 30 && msg[0] == 'y';
    ok &= mqtt_poll(&m, 0, msg, sizeof msg, &got_len) == 1 && got_len == 40 && msg[0] == 'z';
    check("three packets in one read, none lost", ok);

    // 10 KB junk publish, then a normal one: the connection survives
    // (written in slices while reading: a socketpair buffers only ~8 KB)
    n = publish_packet(pkt, 10000, 'j');
    n += publish_packet(pkt + n, 16, 'k');
    int result = 0;
    for (size_t sent = 0; sent < n;) {
        size_t slice = n - sent < 1024 ? n - sent : 1024;
        ssize_t wrote = write(fds[1], pkt + sent, slice);
        if (wrote <= 0) {
            break;
        }
        sent += (size_t)wrote;
        int got = mqtt_poll(&m, 10, msg, sizeof msg, &got_len);
        if (got != 0) {
            result = got;
        }
    }
    for (int i = 0; i < 10 && result == 0; i++) {
        result = mqtt_poll(&m, 50, msg, sizeof msg, &got_len);
    }
    check("oversized packet skipped, next one delivered", result == 1 && got_len == 16 && msg[0] == 'k');

    // a malformed remaining length is a dead connection
    uint8_t bad[] = { 0x30, 0xff, 0xff, 0xff, 0xff, 0x7f };
    put(fds[1], bad, sizeof bad);
    check("malformed length drops the link", mqtt_poll(&m, 50, msg, sizeof msg, &got_len) == -1);

    close(fds[1]);
    close(fds[0]);
    printf(failures ? "\n%d FAILURE(S)\n" : "\nall passed\n", failures);
    return failures != 0;
}
