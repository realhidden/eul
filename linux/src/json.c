//
//  json.c
//  eul (linux)
//

#include "json.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- writer -------------------------------------------------------------

void json_writer_init(json_writer *w, char *buf, size_t cap) {
    w->buf = buf;
    w->len = 0;
    w->cap = cap;
    w->truncated = 0;
    if (cap > 0) {
        buf[0] = '\0';
    }
}

static void json_put_bytes(json_writer *w, const char *s, size_t n) {
    if (w->len + n + 1 > w->cap) {
        w->truncated = 1;
        n = w->cap > w->len + 1 ? w->cap - w->len - 1 : 0;
    }
    memcpy(w->buf + w->len, s, n);
    w->len += n;
    w->buf[w->len] = '\0';
}

void json_put_raw(json_writer *w, const char *raw) {
    json_put_bytes(w, raw, strlen(raw));
}

void json_put_string(json_writer *w, const char *s) {
    json_put_bytes(w, "\"", 1);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        char esc[8];
        switch (*p) {
        case '"':
            json_put_bytes(w, "\\\"", 2);
            break;
        case '\\':
            json_put_bytes(w, "\\\\", 2);
            break;
        case '\b':
            json_put_bytes(w, "\\b", 2);
            break;
        case '\f':
            json_put_bytes(w, "\\f", 2);
            break;
        case '\n':
            json_put_bytes(w, "\\n", 2);
            break;
        case '\r':
            json_put_bytes(w, "\\r", 2);
            break;
        case '\t':
            json_put_bytes(w, "\\t", 2);
            break;
        default:
            if (*p < 0x20) {
                snprintf(esc, sizeof esc, "\\u%04x", *p);
                json_put_bytes(w, esc, 6);
            } else {
                json_put_bytes(w, (const char *)p, 1);
            }
        }
        if (w->truncated) {
            return;
        }
    }
    json_put_bytes(w, "\"", 1);
}

void json_put_double(json_writer *w, double v) {
    if (!isfinite(v)) {
        json_put_raw(w, "null"); // JSON has no NaN/inf
        return;
    }
    char num[40];
    snprintf(num, sizeof num, "%.3f", v);
    json_put_raw(w, num);
}

void json_put_long(json_writer *w, long v) {
    char num[24];
    snprintf(num, sizeof num, "%ld", v);
    json_put_raw(w, num);
}

// --- parser -------------------------------------------------------------

static void skip_ws(json_reader *r) {
    while (r->cur < r->end && (*r->cur == ' ' || *r->cur == '\t' || *r->cur == '\n' || *r->cur == '\r')) {
        r->cur++;
    }
}

int json_begin(json_reader *r, const char *data, size_t len) {
    r->cur = data;
    r->end = data + len;
    skip_ws(r);
    return r->cur < r->end && *r->cur == '{';
}

static int match(json_reader *r, char c) {
    skip_ws(r);
    if (r->cur < r->end && *r->cur == c) {
        r->cur++;
        return 1;
    }
    return 0;
}

/// walks over the value at `r`, leaving `r` just past it
int json_skip_value(json_reader *r) {
    skip_ws(r);
    if (r->cur >= r->end) {
        return 0;
    }
    char c = *r->cur;
    if (c == '"') {
        r->cur++;
        while (r->cur < r->end) {
            if (*r->cur == '\\') {
                r->cur++;
            } else if (*r->cur == '"') {
                r->cur++;
                return 1;
            }
            r->cur++;
        }
        return 0;
    }
    if (c == '{' || c == '[') {
        char open = c, close = c == '{' ? '}' : ']';
        int depth = 0;
        while (r->cur < r->end) {
            if (*r->cur == '"') { // skip strings wholesale (they may hold brackets)
                json_reader sub = { r->cur, r->end };
                if (!json_skip_value(&sub)) {
                    return 0;
                }
                r->cur = sub.cur;
                continue;
            }
            if (*r->cur == open) {
                depth++;
            } else if (*r->cur == close) {
                if (--depth == 0) {
                    r->cur++;
                    return 1;
                }
            }
            r->cur++;
        }
        return 0;
    }
    // number, true, false, null: run to the next delimiter
    while (r->cur < r->end && *r->cur != ',' && *r->cur != '}' && *r->cur != ']' && *r->cur != ' ' && *r->cur != '\n' && *r->cur != '\r' && *r->cur != '\t') {
        r->cur++;
    }
    return 1;
}

int json_find(json_reader *r, const char *key) {
    skip_ws(r);
    if (r->cur >= r->end || *r->cur != '{') {
        return 0;
    }
    r->cur++;
    skip_ws(r);
    if (r->cur < r->end && *r->cur == '}') {
        r->cur++;
        return 0;
    }
    for (;;) {
        skip_ws(r);
        if (r->cur >= r->end || *r->cur != '"') {
            return 0;
        }
        json_reader key_reader = *r;
        char name[64];
        if (!json_read_string(&key_reader, name, sizeof name)) {
            return 0;
        }
        r->cur = key_reader.cur;
        skip_ws(r);
        if (r->cur >= r->end || *r->cur != ':') {
            return 0;
        }
        r->cur++;
        skip_ws(r);
        if (strcmp(name, key) == 0) {
            return 1;
        }
        if (!json_skip_value(r)) {
            return 0;
        }
        if (match(r, ',')) {
            continue;
        }
        if (match(r, '}')) {
            return 0;
        }
        return 0;
    }
}

static int read_hex4(const char *p, unsigned *out) {
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') {
            v |= (unsigned)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            v |= (unsigned)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            v |= (unsigned)(c - 'A' + 10);
        } else {
            return 0;
        }
    }
    *out = v;
    return 1;
}

static size_t put_utf8(char *out, size_t cap, size_t len, unsigned cp) {
    char enc[4];
    size_t n;
    if (cp < 0x80) {
        enc[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        enc[0] = (char)(0xc0 | (cp >> 6));
        enc[1] = (char)(0x80 | (cp & 0x3f));
        n = 2;
    } else if (cp < 0x10000) {
        enc[0] = (char)(0xe0 | (cp >> 12));
        enc[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
        enc[2] = (char)(0x80 | (cp & 0x3f));
        n = 3;
    } else {
        enc[0] = (char)(0xf0 | (cp >> 18));
        enc[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
        enc[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
        enc[3] = (char)(0x80 | (cp & 0x3f));
        n = 4;
    }
    for (size_t i = 0; i < n && len + 1 < cap; i++) {
        out[len++] = enc[i];
    }
    return len;
}

int json_read_string(json_reader *r, char *out, size_t cap) {
    skip_ws(r);
    if (r->cur >= r->end || *r->cur != '"' || cap == 0) {
        return 0;
    }
    r->cur++;
    size_t len = 0;
    while (r->cur < r->end && *r->cur != '"') {
        char c = *r->cur;
        if (c == '\\') {
            r->cur++;
            if (r->cur >= r->end) {
                return 0;
            }
            char e = *r->cur++;
            switch (e) {
            case '"': c = '"'; break;
            case '\\': c = '\\'; break;
            case '/': c = '/'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case 'n': c = '\n'; break;
            case 'r': c = '\r'; break;
            case 't': c = '\t'; break;
            case 'u': {
                unsigned cp;
                if (r->end - r->cur < 4 || !read_hex4(r->cur, &cp)) {
                    return 0;
                }
                r->cur += 4;
                // surrogate pair
                if (cp >= 0xd800 && cp <= 0xdbff && r->end - r->cur >= 6
                    && r->cur[0] == '\\' && r->cur[1] == 'u') {
                    unsigned lo;
                    if (read_hex4(r->cur + 2, &lo) && lo >= 0xdc00 && lo <= 0xdfff) {
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                        r->cur += 6;
                    }
                }
                len = put_utf8(out, cap, len, cp);
                continue;
            }
            default:
                return 0;
            }
            if (len + 1 < cap) {
                out[len++] = c;
            }
        } else {
            if (len + 1 < cap) {
                out[len++] = c;
            }
            r->cur++;
        }
    }
    if (r->cur >= r->end) {
        return 0;
    }
    r->cur++; // closing quote
    out[len] = '\0';
    return 1;
}

int json_read_double(json_reader *r, double *out) {
    skip_ws(r);
    const char *start = r->cur;
    char *endp;
    double v = strtod(start, &endp);
    if (endp == start) {
        return 0;
    }
    r->cur = endp;
    *out = v;
    return 1;
}
