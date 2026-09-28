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
#
# MPD support:
#     make            autodetect <mpd/client.h>, build without it if absent
#     make MPD=1      require it; fail the build if the header is missing
#     make MPD=0      leave it out
#
# The firmware build passes MPD=1. Autodetection is right for a developer
# machine that may not have libmpdclient installed, and wrong for the
# image, where silently shipping a panel daemon that cannot talk to MPD
# is exactly the sort of thing that gets discovered on the bench.

CROSS_COMPILE ?=
CC       = $(CROSS_COMPILE)gcc
OBJDUMP  = $(CROSS_COMPILE)objdump
CFLAGS  ?= -O2 -std=c99 -Wall -Wextra -Wpedantic
BIN      = bdp-panel

# Ask the compiler that will actually do the build, so the answer comes
# from its sysroot rather than from the host's /usr/include.
#
# -include rather than piping a #include line into the compiler, because
# a '#' in a makefile has to be escaped as '\#', make passes the
# backslash through to the shell, and gcc then sees a line that is not a
# preprocessor directive at all: it preprocesses it happily and exits 0.
# That probe reported success on a machine with no libmpdclient anywhere.
MPD_PROBE := $(shell $(CC) -E -x c -include mpd/client.h /dev/null >/dev/null 2>&1 && echo yes || echo no)

ifeq ($(MPD),1)
  ifneq ($(MPD_PROBE),yes)
    $(error MPD=1 but <mpd/client.h> was not found by $(CC). \
            libmpdclient is provided by BR2_PACKAGE_MPD_MPC.)
  endif
  MPD_ENABLED = yes
else ifeq ($(MPD),0)
  MPD_ENABLED = no
else
  MPD_ENABLED = $(MPD_PROBE)
endif

ifeq ($(MPD_ENABLED),yes)
  CPPFLAGS += -DHAVE_MPD
  LDLIBS   += -lmpdclient
endif

all: $(BIN)

$(BIN): bdp-panel.c
	@echo "bdp-panel: MPD support $(MPD_ENABLED)"
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDLIBS)

# Fails loudly if the target build emitted an instruction the Geode LX
# cannot execute. nopl is the long NOP the Geode lacks; endbr32 is the
# adjacent opcode in the same reserved-NOP group, which -fcf-protection
# emits and which cannot be assumed to decode either.
check-geode: $(BIN)
	@n=$$($(OBJDUMP) -d $(BIN) | grep -cE '\<(nopl|endbr32)\>' || true); \
	 if [ "$$n" -ne 0 ]; then echo "FAIL: $$n unsupported instruction(s)"; exit 1; \
	 else echo "OK: no nopl or endbr32"; fi

clean:
	rm -f $(BIN)

.PHONY: all clean check-geode
