//
//  test_json.c
//  eul (linux)
//
//  Exercises the JSON parser against snapshots exactly as Swift's
//  JSONEncoder produces them (field order, escapes, null optionals), and
//  the peer decode path end to end.
//

#include "../src/json.h"
#include "../src/peer.h"

#include <math.h>
#include <time.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check_int(const char *name, int got, int want) {
    if (got != want) {
        failures++;
        printf("FAIL %s: got %d want %d\n", name, got, want);
    } else {
        printf("ok   %s\n", name);
    }
}

static void check_str(const char *name, const char *got, const char *want) {
    if (strcmp(got, want) != 0) {
        failures++;
        printf("FAIL %s: got \"%s\" want \"%s\"\n", name, got, want);
    } else {
        printf("ok   %s\n", name);
    }
}

static void check_double(const char *name, double got, double want) {
    if (fabs(got - want) > 0.001) {
        failures++;
        printf("FAIL %s: got %f want %f\n", name, got, want);
    } else {
        printf("ok   %s\n", name);
    }
}

int main(void) {
    // fresh timestamps inside the 60 s freshness window
    char sent_at[48];
    snprintf(sent_at, sizeof sent_at, "%.3f", (double)time(NULL) - 978307200.0 - 5);

    // a snapshot the way the Mac app emits it: full field list
    char swift_snapshot[512];
    snprintf(swift_snapshot, sizeof swift_snapshot,
        "{\"id\":\"A1B2C3D4-1111-2222-3333-444455556666\","
        "\"name\":\"MacBook Pro \\u2019s MacBook \\\"Pro\\\"\","
        "\"sentAt\":%s,"
        "\"stats\":{\"cpu\":12.5,\"memory\":45.25,\"gpu\":null,"
        "\"temperature\":52,\"temperatureUnit\":\"celius\","
        "\"networkIn\":1024,\"networkOut\":512}}", sent_at);

    peer_entry p;
    check_int("decode swift snapshot", peer_decode_snapshot((const uint8_t *)swift_snapshot,
                                                            strlen(swift_snapshot), &p), 1);
    check_str("id", p.id, "A1B2C3D4-1111-2222-3333-444455556666");
    check_str("name with escapes", p.name, "MacBook Pro \xe2\x80\x99s MacBook \"Pro\"");
    check_double("cpu", p.cpu, 12.5);
    check_double("memory", p.memory, 45.25);
    check_double("gpu stays unset", p.gpu, -1);
    check_double("temperature", p.temperature, 52);
    check_str("temperature unit", p.temperature_unit, "celius");
    check_double("net in", p.net_in, 1024);
    check_double("net out", p.net_out, 512);

    // optionals omitted entirely (our own encoder skips them) — every stats
    // field after a missing one must still decode
    char minimal[192];
    snprintf(minimal, sizeof minimal,
        "{\"id\":\"peer-2\",\"name\":\"rpi4\",\"sentAt\":%s,"
        "\"stats\":{\"networkIn\":0}}", sent_at);
    check_int("decode minimal snapshot", peer_decode_snapshot((const uint8_t *)minimal,
                                                              strlen(minimal), &p), 1);
    check_str("minimal id", p.id, "peer-2");
    check_str("minimal name", p.name, "rpi4");
    check_double("missing cpu stays unset", p.cpu, -1);
    check_double("missing memory stays unset", p.memory, -1);
    check_double("net in present", p.net_in, 0);

    // fahrenheit peer converts to celsius
    char fahrenheit[160];
    snprintf(fahrenheit, sizeof fahrenheit,
        "{\"id\":\"peer-3\",\"name\":\"x\",\"sentAt\":%s,"
        "\"stats\":{\"temperature\":100,\"temperatureUnit\":\"fahrenheit\"}}", sent_at);
    check_int("decode fahrenheit", peer_decode_snapshot((const uint8_t *)fahrenheit,
                                                        strlen(fahrenheit), &p), 1);
    check_double("fahrenheit to celsius", peer_temperature_celsius(&p), 37.777);

    // stale snapshots (outside the 60 s window) are dropped
    const char *stale =
        "{\"id\":\"peer-4\",\"name\":\"x\",\"sentAt\":805100000.0,"
        "\"stats\":{}}";
    check_int("stale snapshot rejected", peer_decode_snapshot((const uint8_t *)stale,
                                                              strlen(stale), &p), 0);

    // garbage is rejected
    check_int("garbage rejected",
              peer_decode_snapshot((const uint8_t *)"not json at all", 14, &p), 0);
    check_int("truncated rejected",
              peer_decode_snapshot((const uint8_t *)"{\"id\":\"x\"", 10, &p), 0);

    // writer: escaped strings round-trip through the parser
    char buf[256];
    json_writer w;
    json_writer_init(&w, buf, sizeof buf);
    json_put_raw(&w, "{\"name\":");
    json_put_string(&w, "a\"b\\c\nd\001e");
    json_put_raw(&w, "}");
    json_reader r;
    char name_out[128];
    check_int("writer produces json", json_begin(&r, buf, strlen(buf)), 1);
    check_int("writer key found", json_find(&r, "name"), 1);
    check_int("writer string parses", json_read_string(&r, name_out, sizeof name_out), 1);
    check_str("writer escape round-trip", name_out, "a\"b\\c\nd\001e");

    // a full 2.3 Mac snapshot: nested arrays, UInt64 disk bytes, JSONEncoder's
    // escaped "/" and a non-ASCII name — everything the Mac app now sends
    {
        char mac23[1024];
        double now_ref = (double)time(NULL) - 978307200.0;
        snprintf(mac23, sizeof mac23,
                 "{\"id\":\"MAC-23\",\"name\":\"Zsombor\u2019s MacBook \\/ M3\",\"sentAt\":%.3f,"
                 "\"stats\":{\"cores\":[12,30,8,4,50,2,1,0,3,9,11,7,5,60,70,80],\"coreKinds\":\"PPPPPPPPPPPPEEEE\","
                 "\"cpu\":23.4,\"diskFree\":412000000000,\"diskTotal\":994000000000,\"gpu\":5,"
                 "\"memory\":61.2,\"memoryApp\":8.1,\"memoryCompressed\":1.3,\"memoryTotal\":36,"
                 "\"memoryWired\":2.2,\"networkIn\":1234,\"networkOut\":567,\"temperature\":52,"
                 "\"temperatureUnit\":\"celius\",\"uptime\":\"3d 4h 5m\"}}", now_ref);
        peer_entry p;
        check_int("decode 2.3 mac snapshot", peer_decode_snapshot((const uint8_t *)mac23, strlen(mac23), &p), 1);
        check_str("2.3 name with \\/ and u2019", p.name, "Zsombor\xe2\x80\x99s MacBook / M3");
        check_double("2.3 cpu after arrays", p.cpu, 23.4);
        check_double("2.3 gpu", p.gpu, 5);
        check_double("2.3 net out last", p.net_out, 567);
    }

    // a control byte in a peer name never reaches the terminal
    {
        char evil[256];
        double now_ref = (double)time(NULL) - 978307200.0;
        snprintf(evil, sizeof evil,
                 "{\"id\":\"E\",\"name\":\"a\\u001b[2Jb\",\"sentAt\":%.3f,\"stats\":{\"networkIn\":0,\"networkOut\":0,\"temperatureUnit\":\"celius\"}}",
                 now_ref);
        peer_entry p;
        check_int("decode escape-laden name", peer_decode_snapshot((const uint8_t *)evil, strlen(evil), &p), 1);
        check_str("escape byte replaced", p.name, "a?[2Jb");
    }

    // NaN/inf must never reach JSON output
    {
        char out[64];
        json_writer nw;
        json_writer_init(&nw, out, sizeof out);
        json_put_double(&nw, NAN);
        json_put_raw(&nw, ",");
        json_put_double(&nw, INFINITY);
        check_str("non-finite numbers are null", out, "null,null");
    }

    printf(failures ? "\n%d FAILURE(S)\n" : "\nall passed\n", failures);
    return failures != 0;
}
