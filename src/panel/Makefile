# bdp-panel
#
# Host build (for the -D dump and PTY testing):
#     make
#
# Target build, against the Buildroot toolchain:
#     make CROSS_COMPILE=<buildroot>/output/host/bin/i586-linux-
#
# -march=geode is not set here. The Buildroot toolchain wrapper already
# applies it from BR2_x86_geode, and hardcoding it would break the host
# build. Verify with:  objdump -d bdp-panel | grep -c nopl

CROSS_COMPILE ?=
CC       = $(CROSS_COMPILE)gcc
OBJDUMP  = $(CROSS_COMPILE)objdump
CFLAGS  ?= -O2 -std=c99 -Wall -Wextra -Wpedantic
BIN      = bdp-panel

all: $(BIN)

$(BIN): bdp-panel.c
	$(CC) $(CFLAGS) -o $@ $<

# Fails loudly if the target build emitted an instruction the Geode LX
# cannot execute.
check-geode: $(BIN)
	@n=$$($(OBJDUMP) -d $(BIN) | grep -c '\<nopl\>' || true); \
	 if [ "$$n" -ne 0 ]; then echo "FAIL: $$n nopl instruction(s)"; exit 1; \
	 else echo "OK: no nopl"; fi

clean:
	rm -f $(BIN)

.PHONY: all clean check-geode
