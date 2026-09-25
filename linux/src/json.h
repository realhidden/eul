//
//  json.h
//  eul (linux)
//
//  Just enough JSON for the eul-peer snapshot: a growable writer and a
//  pull-parser that can walk objects and pull strings/doubles. Handles the
//  full string escape set (incl. \uXXXX) since peer names come from Macs.
//

#ifndef EUL_JSON_H
#define EUL_JSON_H

#include <stddef.h>

// --- writer -------------------------------------------------------------

typedef struct {
    char *buf;
    size_t len, cap;
    int truncated;
} json_writer;

void json_writer_init(json_writer *w, char *buf, size_t cap);
void json_put_raw(json_writer *w, const char *raw);
void json_put_string(json_writer *w, const char *s);
void json_put_double(json_writer *w, double v);
void json_put_long(json_writer *w, long v);

// --- parser -------------------------------------------------------------

typedef struct {
    const char *cur, *end;
} json_reader;

/// positions `r` at the first value inside the JSON document
int json_begin(json_reader *r, const char *data, size_t len);

/// finds `key` in the object `r` is positioned at; on success `r` is
/// repositioned at the value, on "not found" at the object's end
int json_find(json_reader *r, const char *key);

/// value readers; each consumes the value `r` points at
int json_read_string(json_reader *r, char *out, size_t cap);
int json_read_double(json_reader *r, double *out);
int json_skip_value(json_reader *r);

#endif
