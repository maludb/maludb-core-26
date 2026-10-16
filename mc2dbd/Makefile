### maludb_mc2dbd — MC2DB listener service
###
### Builds the C sidecar that exposes MaluDB as an MCP-compatible HTTP
### endpoint (default https://localhost:5329).
###
### Build deps on Ubuntu 24.04:
###   sudo apt-get install -y libpq-dev libmicrohttpd-dev libjansson-dev libgnutls28-dev libcurl4-openssl-dev pkg-config
###
### Build:    make -C mc2dbd
### Test:     make -C mc2dbd test     (requires a running PG with maludb_core installed)
### Install:  sudo make -C mc2dbd install
### Clean:    make -C mc2dbd clean
###
### This is intentionally NOT a PGXS build. The listener does not link
### into the PostgreSQL backend — it runs as a separate daemon and
### connects via libpq.

BIN          := maludb_mc2dbd
SRCDIR       := src
OBJDIR       := build
PREFIX       ?= /usr/local
SBINDIR      ?= $(PREFIX)/sbin
SYSCONFDIR   ?= /etc/maludb
SYSTEMD_UNIT_DIR ?= /etc/systemd/system

PG_CONFIG    ?= /usr/lib/postgresql/17/bin/pg_config
PG_INCDIR    := $(shell $(PG_CONFIG) --includedir)
PG_LIBDIR    := $(shell $(PG_CONFIG) --libdir)

CFLAGS       += -std=gnu11 -Wall -Wextra -Wno-unused-parameter -O2 -g -fPIC
CFLAGS       += -D_GNU_SOURCE
CFLAGS       += -I$(SRCDIR) -I$(PG_INCDIR)
CFLAGS       += $(shell pkg-config --cflags libmicrohttpd jansson libcurl 2>/dev/null)

LDFLAGS      += -L$(PG_LIBDIR)
LDLIBS       += -lpq
LDLIBS       += $(shell pkg-config --libs libmicrohttpd jansson libcurl 2>/dev/null || echo "-lmicrohttpd -ljansson -lcurl")

SRCS := $(wildcard $(SRCDIR)/*.c)
OBJS := $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

.PHONY: all clean install test test-unit print

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(OBJDIR):
	mkdir -p $@

clean:
	rm -rf $(OBJDIR) $(BIN)

install: $(BIN)
	install -d $(DESTDIR)$(SBINDIR)
	install -m 0755 $(BIN) $(DESTDIR)$(SBINDIR)/$(BIN)
	install -d $(DESTDIR)$(SYSCONFDIR)
	[ -f $(DESTDIR)$(SYSCONFDIR)/maludb-mc2dbd.conf ] || \
	  install -m 0640 etc/maludb-mc2dbd.conf.example $(DESTDIR)$(SYSCONFDIR)/maludb-mc2dbd.conf
	install -d $(DESTDIR)$(SYSTEMD_UNIT_DIR)
	install -m 0644 systemd/maludb-mc2dbd.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/maludb-mc2dbd.service

# Service tests: bring the daemon up against the local PG, exercise the
# four critical MCP paths via curl/jq, tear down. Requires that
# maludb_core is already installed and `make installcheck` has passed.
test: $(BIN)
	@bash tests/run_all.sh

print:
	@echo "BIN=$(BIN)"
	@echo "PG_CONFIG=$(PG_CONFIG)"
	@echo "PG_INCDIR=$(PG_INCDIR)"
	@echo "PG_LIBDIR=$(PG_LIBDIR)"
	@echo "CFLAGS=$(CFLAGS)"
	@echo "LDLIBS=$(LDLIBS)"
	@echo "SRCS=$(SRCS)"
