# eul for Linux — a self-contained terminal system monitor.
# No external dependencies: plain C99 + POSIX, needs only a C compiler and make.

CC      ?= cc
CFLAGS  ?= -O2
WARN     = -Wall -Wextra -Wpedantic -std=c99
DEFS     = -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -D_FILE_OFFSET_BITS=64
LDLIBS   = -lpthread -lm -ldl

SRCDIR   = src
OBJDIR   = build
BIN      = eul
PREFIX   ?= /usr/local

SRCS = $(SRCDIR)/main.c $(SRCDIR)/stats.c $(SRCDIR)/crypto.c \
       $(SRCDIR)/json.c $(SRCDIR)/mqtt.c $(SRCDIR)/peer.c
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))
HDRS = $(SRCDIR)/*.h

.PHONY: all clean install uninstall test compat static

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) $(DEFS) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(OBJDIR)/%.o: $(SRCDIR)/%.c $(HDRS) | $(OBJDIR)
	$(CC) $(CFLAGS) $(WARN) $(DEFS) -c -o $@ $<

$(OBJDIR):
	mkdir -p $(OBJDIR)

# fully static binary (needs a static libc; on glibc some NSS warnings are
# expected — for a clean static build use musl: make CC=musl-gcc static).
# A static binary cannot load NVML, so NVIDIA GPUs show no gpu row there.
static: clean
	$(MAKE) LDFLAGS=-static

test: $(BIN)
	$(MAKE) -C tests run

# macOS-only: cross-checks our key derivation and sealing against the Swift
# implementation the eul app ships (CryptoKit ChaChaPoly + PBKDF2/HKDF)
compat: $(BIN)
	$(MAKE) -C tests compat

install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(BIN) $(DESTDIR)$(PREFIX)/bin/eul

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/eul

clean:
	rm -rf $(OBJDIR) $(BIN)
	$(MAKE) -C tests clean
