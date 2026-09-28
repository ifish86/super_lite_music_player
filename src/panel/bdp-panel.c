/*
 * bdp-panel.c - front panel link for super_lite_music_player.
 *
 * Protocol reverse-engineered from assets/old_programs/brystonpanel.php,
 * the stock firmware's panel daemon. That program only ever sends three
 * things to the panel, so the whole wire format fits here:
 *
 *   TX   0x1C <version> \n      enable. Must be the first thing sent.
 *        0x11 <text>    \n      write line 1
 *        0x12 <text>    \n      write line 2
 *
 *   RX   BDP_POLL \n             heartbeat, sent continuously
 *        BDP_PLAY BDP_PAUSE BDP_STOP BDP_NEXT BDP_PREVIOUS BDP_TOGGLE
 *        BDP_UP BDP_DOWN BDP_LEFT BDP_RIGHT BDP_SHUTDOWN
 *
 * Line 2 conventionally carries a status icon in its first byte:
 *   0x91 play  0x92 stop  0x93 pause  0x95 directory  0x96 file
 *
 * Port is 9600 8N1, no flow control, and RAW. See panel_open() for why
 * the flow control part is not optional.
 *
 * Built with -DHAVE_MPD it is also the player front end: it shows what
 * MPD is playing on the two lines and maps the transport keys onto MPD
 * commands. Without it, it is still the link layer and a way to prove the
 * link works, which is what the host build is for.
 *
 * Phase 3 folds the rest in - the menu tree, the settings web UI and
 * petting the watchdog - around this same poll loop.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#ifdef HAVE_MPD
#include <mpd/client.h>
#endif

/* Commands sent to the panel. */
#define PANEL_ENABLE 0x1Cu
#define PANEL_LINE1  0x11u
#define PANEL_LINE2  0x12u

/* Status icons, used as the first byte of line 2. */
#define ICON_PLAY  0x91u
#define ICON_STOP  0x92u
#define ICON_PAUSE 0x93u
#define ICON_DIR   0x95u
#define ICON_FILE  0x96u

#define DEFAULT_DEVICE "/dev/ttyS1"

/*
 * Display geometry.
 *
 * Two lines of an unknown number of columns, and deliberately not guessed
 * at. A line longer than the panel just runs off the end, so clipping to
 * a guess cannot help and can only throw away characters the display
 * would have shown. Text is sent whole.
 *
 * What bounds it is UI_TEXT_MAX, and that is a limit on how long one
 * title may monopolise a 9600 baud link, not a claim about the hardware.
 *
 * -w imposes a real column limit for when the width is known and worth
 * respecting. Scrolling long titles will need it; clipping does not.
 * Find the number with a ruler and count what appears:
 *     bdp-panel -1 '....5...10...15...20...25'
 */
#define DEFAULT_WIDTH 0        /* 0 = send the whole line, do not clip */
#define MIN_WIDTH     2        /* line 2 spends a column on the icon */
#define MAX_WIDTH     64

/* Shown while MPD is not reachable, and once it is. */
#define TEXT_NO_MPD  "Waiting for MPD"
#define DEFAULT_READY "BDP-1 Ready"

/* How often to retry a dead MPD connection, in poll ticks of TICK_MS. */
#define TICK_MS       1000
#define RECONNECT_TICKS 2

#define DEFAULT_MPD_HOST "localhost"
#define DEFAULT_MPD_PORT 6600u

/*
 * Command terminator.
 *
 * LF then CR, in that order. Note this is not CRLF: the bytes are 0A 0D,
 * confirmed against a panel that accepts the handshake. brystonpanel.php
 * appends only "\n", so either the stock serial layer added the CR or the
 * PHP was relying on something else to supply it. Sending LF alone gets
 * the message rejected.
 *
 * Applied to all three commands. Only the enable message is confirmed;
 * if line writes misbehave, -L sends LF alone so the two can be compared
 * without a rebuild.
 */
#define TERM_CRLF "\n\r"
#define TERM_LF   "\n"

/*
 * The stock firmware built this from /ver and /datecode as
 * "S" + <ver> + " " + <datecode>, e.g. "S2.62 20160321", and sent it as
 * the payload of the enable command.
 *
 * Whether the panel parses this or merely logs it is not known. If your
 * unit is fussy, run the original firmware and read the first line it
 * prints on stdout: that is the exact string it handshakes with, and
 * -v will reproduce it byte for byte.
 */
#define DEFAULT_VERSION "S3.00 2023-04-08"

static const char *terminator = TERM_CRLF;

static volatile sig_atomic_t stop_requested = 0;

static void on_signal(int sig)
{
	(void)sig;
	stop_requested = 1;
}

/* write() until the whole buffer is gone, or fail. */
static int write_all(int fd, const unsigned char *buf, size_t len)
{
	size_t off = 0;

	while (off < len) {
		ssize_t n = write(fd, buf + off, len - off);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			/*
			 * The port is O_NONBLOCK, so a write big enough to
			 * fill the tty's output buffer returns EAGAIN rather
			 * than blocking, and at 9600 baud that buffer drains
			 * slowly. Wait for room instead of reporting a
			 * failure that has not happened.
			 *
			 * This could not fire while lines were clipped to
			 * twenty-odd bytes. Now that a title is sent whole it
			 * is merely unlikely, which is not the same thing.
			 */
			if (errno == EAGAIN) {
				struct pollfd pfd = { .fd = fd, .events = POLLOUT };
				if (poll(&pfd, 1, 2000) > 0)
					continue;
			}
			return -1;
		}
		off += (size_t)n;
	}
	return 0;
}

/*
 * Build "<cmd><text>\n" into buf.
 *
 * Embedded newlines would split one command into two and desynchronise
 * the panel, so they are replaced rather than passed through. Everything
 * else is left alone, including bytes above 0x7F: those are the status
 * icons and they must reach the panel unmodified.
 */
static size_t frame(unsigned char *buf, size_t cap, unsigned cmd, const char *text)
{
	size_t n = 0;

	if (cap < 2)
		return 0;

	buf[n++] = (unsigned char)cmd;
	for (; *text && n < cap - 1; text++) {
		unsigned char c = (unsigned char)*text;
		buf[n++] = (c == '\n' || c == '\r') ? ' ' : c;
	}
	for (const char *t = terminator; *t && n < cap; t++)
		buf[n++] = (unsigned char)*t;
	return n;
}

static int panel_send(int fd, unsigned cmd, const char *text)
{
	unsigned char buf[512];
	size_t n = frame(buf, sizeof buf, cmd, text);

	if (n == 0)
		return -1;
	return write_all(fd, buf, n);
}

static void hexdump(const char *label, const unsigned char *buf, size_t len)
{
	printf("%-10s %2zu bytes:", label, len);
	for (size_t i = 0; i < len; i++)
		printf(" %02X", buf[i]);
	printf("\n%-10s ", "");
	for (size_t i = 0; i < len; i++)
		printf("%c", (buf[i] >= 0x20 && buf[i] < 0x7F) ? buf[i] : '.');
	printf("\n");
}

/*
 * Open and configure the panel UART.
 *
 * cfmakeraw() does the heavy lifting, but two of the things it turns off
 * matter enough to be worth stating, because with either one left on the
 * display simply does not work and the cause is not obvious:
 *
 *   IXON/IXOFF - software flow control. The line 1 command byte is 0x11,
 *                which is XON. With software flow control enabled the
 *                tty layer eats it as a flow control character and line
 *                1 writes vanish. The stock firmware set flow control to
 *                "none" for the same reason.
 *
 *   ISTRIP     - strips the high bit. The status icons are 0x91 to 0x96,
 *                so stripping leaves 0x11 to 0x16, which are themselves
 *                command bytes. That corrupts the stream rather than
 *                merely losing a glyph.
 *
 * O_NOCTTY keeps the panel from becoming this process's controlling
 * terminal. There is deliberately no getty on this port.
 */
static int panel_open(const char *dev)
{
	struct termios tio;
	int fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);

	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return -1;
	}

	if (tcgetattr(fd, &tio) < 0) {
		fprintf(stderr, "tcgetattr %s: %s\n", dev, strerror(errno));
		close(fd);
		return -1;
	}

	/* Raw mode, set out longhand rather than with cfmakeraw(), which
	 * is a BSD extension: it is not declared under _POSIX_C_SOURCE,
	 * and on the musl target toolchain that is a compile error rather
	 * than the warning glibc gives you. Doing it by hand also keeps
	 * the two failure modes above visible instead of implied. */
	tio.c_iflag &= (tcflag_t)~(IXON | IXOFF | IXANY | ISTRIP | INLCR |
				   ICRNL | IGNCR | BRKINT | PARMRK | IGNBRK |
				   INPCK);
	tio.c_oflag &= (tcflag_t)~OPOST;
	tio.c_lflag &= (tcflag_t)~(ECHO | ECHOE | ECHONL | ICANON | ISIG | IEXTEN);
	tio.c_cflag &= (tcflag_t)~(PARENB | CSTOPB | CSIZE);
	tio.c_cflag |= CS8 | CLOCAL | CREAD;
#ifdef CRTSCTS
	tio.c_cflag &= (tcflag_t)~CRTSCTS;
#endif
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 0;

	if (cfsetispeed(&tio, B9600) < 0 || cfsetospeed(&tio, B9600) < 0) {
		fprintf(stderr, "cfsetspeed: %s\n", strerror(errno));
		close(fd);
		return -1;
	}

	if (tcsetattr(fd, TCSANOW, &tio) < 0) {
		fprintf(stderr, "tcsetattr %s: %s\n", dev, strerror(errno));
		close(fd);
		return -1;
	}

	tcflush(fd, TCIOFLUSH);
	return fd;
}

/* Read a file, trim trailing whitespace, fold interior newlines to spaces. */
static int read_trimmed(const char *path, char *out, size_t cap)
{
	FILE *f = fopen(path, "r");
	size_t n;

	if (!f)
		return -1;
	n = fread(out, 1, cap - 1, f);
	fclose(f);
	out[n] = '\0';

	for (size_t i = 0; i < n; i++)
		if (out[i] == '\n' || out[i] == '\r')
			out[i] = ' ';
	while (n > 0 && out[n - 1] == ' ')
		out[--n] = '\0';
	return 0;
}

/*
 * Reproduce the stock firmware's version string: "S" + /ver + " " +
 * /datecode. Falls back to DEFAULT_VERSION when those files are absent,
 * which they will be on this firmware.
 */
static void default_version(char *out, size_t cap)
{
	char ver[64], date[64];

	if (read_trimmed("/ver", ver, sizeof ver) == 0 &&
	    read_trimmed("/datecode", date, sizeof date) == 0 &&
	    ver[0] != '\0') {
		snprintf(out, cap, "S%s %s", ver, date);
		return;
	}
	snprintf(out, cap, "%s", DEFAULT_VERSION);
}

/*
 * Map an icon name to its byte.
 *
 * This exists because passing the byte itself through argv is a trap:
 * in a UTF-8 locale a shell turns \x91 into the two bytes C2 91, and the
 * panel gets mojibake instead of a play symbol. A name cannot be
 * re-encoded on the way in.
 */
static int icon_byte(const char *name)
{
	if (!strcmp(name, "play"))  return (int)ICON_PLAY;
	if (!strcmp(name, "stop"))  return (int)ICON_STOP;
	if (!strcmp(name, "pause")) return (int)ICON_PAUSE;
	if (!strcmp(name, "dir"))   return (int)ICON_DIR;
	if (!strcmp(name, "file"))  return (int)ICON_FILE;
	if (!strcmp(name, "none"))  return -1;
	return -2;
}

/*
 * Parse a hex payload, ignoring anything that is not a hex digit, so
 * "1C 53 33" and "x1C x53 x33" and "1c5333" all mean the same thing.
 *
 * This exists so an exact byte sequence captured from a working panel
 * can be replayed without arguing about string encoding, terminators or
 * what a shell did to the argument on the way in.
 */
static long parse_hex(const char *in, unsigned char *out, size_t cap)
{
	size_t n = 0;
	int hi = -1;

	for (; *in; in++) {
		int v;
		if (*in >= '0' && *in <= '9') v = *in - '0';
		else if (*in >= 'a' && *in <= 'f') v = *in - 'a' + 10;
		else if (*in >= 'A' && *in <= 'F') v = *in - 'A' + 10;
		else continue;

		if (hi < 0) {
			hi = v;
		} else {
			if (n >= cap)
				return -1;
			out[n++] = (unsigned char)((hi << 4) | v);
			hi = -1;
		}
	}
	if (hi >= 0)
		return -1;   /* odd number of digits */
	return (long)n;
}

/* ------------------------------------------------------------------ *
 * Display state
 *
 * The UART is 9600 baud, which is 960 bytes a second, and a full line
 * costs about 23 of them. Redrawing on every MPD event would keep the
 * link permanently busy for no gain, so the last thing written to each
 * line is remembered and a write only happens when the rendered text
 * actually differs.
 * ------------------------------------------------------------------ */

#define UI_TEXT_MAX 128

struct ui {
	int fd;
	unsigned width;
	const char *ready;
	char shown1[UI_TEXT_MAX];
	char shown2[UI_TEXT_MAX];
	int primed;            /* has anything been written yet? */
};

/*
 * Copy at most `width` columns of `in` into `out`.
 *
 * Control bytes become spaces: 0x11, 0x12 and 0x1C are commands, so a
 * track title containing one would desynchronise the panel rather than
 * merely look wrong. Bytes above 0x7F are passed through untouched -
 * they are the icon range and whatever else the panel's character set
 * holds, and MPD tags are UTF-8, so this is where a non-ASCII title will
 * either render or not. Which it does is unknown until a unit shows
 * something.
 */
static void clip(char *out, size_t cap, const char *in, unsigned width)
{
	size_t n = 0;

	if (cap == 0)
		return;
	/* 0 means no column limit, which is the default; the buffer is
	 * still the backstop. */
	if (width == 0 || (size_t)width > cap - 1)
		width = (unsigned)(cap - 1);
	for (; in && *in && n < width; in++) {
		unsigned char c = (unsigned char)*in;
		out[n++] = (c < 0x20 || c == 0x7F) ? ' ' : (char)c;
	}
	out[n] = '\0';
}

/*
 * Render both lines. `icon` is a status byte for the first column of
 * line 2, or -1 for none.
 */
static void ui_show(struct ui *u, const char *l1, int icon, const char *l2)
{
	char b1[UI_TEXT_MAX], b2[UI_TEXT_MAX];

	clip(b1, sizeof b1, l1, u->width);

	if (icon >= 0) {
		/* The icon occupies a column, so a limited line 2 gets one
		 * less. Unlimited stays unlimited: -w is validated to be 0 or
		 * at least MIN_WIDTH, so this cannot land on 0 by accident. */
		b2[0] = (char)(unsigned char)icon;
		clip(b2 + 1, sizeof b2 - 1, l2,
		     u->width ? u->width - 1 : 0);
	} else {
		clip(b2, sizeof b2, l2, u->width);
	}

	if (!u->primed || strcmp(b1, u->shown1) != 0) {
		if (panel_send(u->fd, PANEL_LINE1, b1) == 0)
			snprintf(u->shown1, sizeof u->shown1, "%s", b1);
	}
	if (!u->primed || strcmp(b2, u->shown2) != 0) {
		if (panel_send(u->fd, PANEL_LINE2, b2) == 0)
			snprintf(u->shown2, sizeof u->shown2, "%s", b2);
	}
	u->primed = 1;
}

#ifdef HAVE_MPD
/* ------------------------------------------------------------------ *
 * MPD link
 *
 * One connection, held in idle so the kernel wakes us when something
 * changes rather than us asking. The catch with idle is that a
 * connection sitting in it cannot accept another command, so anything
 * that wants to talk - a button press, a status read - has to cancel it
 * first. That is what mpd_quiesce() is for, and forgetting it produces a
 * protocol error rather than anything helpful.
 * ------------------------------------------------------------------ */

struct mpdlink {
	struct mpd_connection *conn;
	const char *host;
	unsigned port;
	int idling;
};

static void mpd_drop(struct mpdlink *m)
{
	if (m->conn) {
		mpd_connection_free(m->conn);
		m->conn = NULL;
	}
	m->idling = 0;
}

/* Non-fatal: MPD not being up yet is the normal case at boot. */
static int mpd_up(struct mpdlink *m)
{
	if (m->conn)
		return 1;
	m->conn = mpd_connection_new(m->host, m->port, 3000);
	if (!m->conn)
		return 0;
	if (mpd_connection_get_error(m->conn) != MPD_ERROR_SUCCESS) {
		mpd_drop(m);
		return 0;
	}
	return 1;
}

static void mpd_arm(struct mpdlink *m)
{
	if (!m->conn || m->idling)
		return;
	if (!mpd_send_idle_mask(m->conn, MPD_IDLE_PLAYER))
		mpd_drop(m);
	else
		m->idling = 1;
}

/* Leave idle so a command can be sent. */
static int mpd_quiesce(struct mpdlink *m)
{
	if (!m->conn)
		return 0;
	if (m->idling) {
		mpd_run_noidle(m->conn);
		m->idling = 0;
		if (mpd_connection_get_error(m->conn) != MPD_ERROR_SUCCESS) {
			mpd_drop(m);
			return 0;
		}
	}
	return 1;
}

/* Read state and put it on the display. */
static void mpd_render(struct mpdlink *m, struct ui *u)
{
	struct mpd_status *st;
	enum mpd_state state;

	if (!mpd_quiesce(m)) {
		ui_show(u, "BDP-1", (int)ICON_STOP, TEXT_NO_MPD);
		return;
	}

	st = mpd_run_status(m->conn);
	if (!st) {
		mpd_drop(m);
		ui_show(u, "BDP-1", (int)ICON_STOP, TEXT_NO_MPD);
		return;
	}
	state = mpd_status_get_state(st);
	mpd_status_free(st);

	if (state == MPD_STATE_PLAY || state == MPD_STATE_PAUSE) {
		struct mpd_song *song = mpd_run_current_song(m->conn);
		const char *title = NULL, *artist = NULL;

		if (song) {
			title = mpd_song_get_tag(song, MPD_TAG_TITLE, 0);
			artist = mpd_song_get_tag(song, MPD_TAG_ARTIST, 0);
			/* An untagged file still has a name. Show the last
			 * path component rather than the whole URI, which
			 * would be all directory and no filename once
			 * clipped to the width. */
			if (!title) {
				const char *uri = mpd_song_get_uri(song);
				const char *slash = uri ? strrchr(uri, '/') : NULL;
				title = slash ? slash + 1 : uri;
			}
		}
		ui_show(u, title ? title : "Playing",
			state == MPD_STATE_PLAY ? (int)ICON_PLAY : (int)ICON_PAUSE,
			artist ? artist : "");
		if (song)
			mpd_song_free(song);
	} else {
		ui_show(u, u->ready, (int)ICON_STOP, "");
	}

	mpd_arm(m);
}

/*
 * Act on a button.
 *
 * Returns 1 if the token was one of ours, so the caller knows whether to
 * treat it as handled.
 */
static int mpd_button(struct mpdlink *m, const char *tok)
{
	if (!strcmp(tok, "BDP_PLAY")     || !strcmp(tok, "BDP_PAUSE") ||
	    !strcmp(tok, "BDP_STOP")     || !strcmp(tok, "BDP_NEXT")  ||
	    !strcmp(tok, "BDP_PREVIOUS") || !strcmp(tok, "BDP_TOGGLE")) {
		if (!mpd_quiesce(m))
			return 1;   /* ours, but there is nothing to send it to */
	} else {
		return 0;
	}

	if      (!strcmp(tok, "BDP_PLAY"))     mpd_run_play(m->conn);
	else if (!strcmp(tok, "BDP_PAUSE"))    mpd_run_pause(m->conn, true);
	else if (!strcmp(tok, "BDP_STOP"))     mpd_run_stop(m->conn);
	else if (!strcmp(tok, "BDP_NEXT"))     mpd_run_next(m->conn);
	else if (!strcmp(tok, "BDP_PREVIOUS")) mpd_run_previous(m->conn);
	else if (!strcmp(tok, "BDP_TOGGLE"))   mpd_run_toggle_pause(m->conn);

	if (mpd_connection_get_error(m->conn) != MPD_ERROR_SUCCESS)
		mpd_drop(m);
	return 1;
}
#endif /* HAVE_MPD */

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [options]\n"
		"\n"
		"  -d DEV     panel serial port (default %s)\n"
		"  -v STR     version string sent with the enable command\n"
		"  -1 TEXT    write TEXT to line 1 and exit\n"
		"  -2 TEXT    write TEXT to line 2 and exit\n"
		"  -i ICON    prepend a status icon to line 2:\n"
		"             play, stop, pause, dir, file, none\n"
		"  -L         terminate with LF only instead of LF CR\n"
		"  -X HEX     send exactly these bytes as the enable message,\n"
		"             verbatim: no command byte, no terminator added.\n"
		"             e.g. -X '1C 53 33 2E 30 30 0A 0D'\n"
		"  -n         do not send the enable command\n"
		"  -D         dump the bytes that would be sent, touch no hardware\n"
		"  -w COLS    clip display text at COLS; 0 means do not clip,\n"
		"             which is the default - an over-long line just\n"
		"             runs off the end of the panel\n"
		"  -R TEXT    idle message once MPD is up (default \"%s\")\n"
#ifdef HAVE_MPD
		"  -m HOST    MPD host (default %s)\n"
		"  -p PORT    MPD port (default %u)\n"
		"  -M         do not talk to MPD; just report button events\n"
#endif
		"  -h         this\n"
		"\n"
#ifdef HAVE_MPD
		"With no -1/-2, sends enable, then follows MPD on the display\n"
		"and maps the transport keys onto it. Button events are still\n"
		"printed, so the log stays useful.\n",
#else
		"With no -1/-2, sends enable and then reports button events\n"
		"until interrupted. Built without MPD support.\n",
#endif
		argv0, DEFAULT_DEVICE, DEFAULT_READY
#ifdef HAVE_MPD
		, DEFAULT_MPD_HOST, DEFAULT_MPD_PORT
#endif
		);
}

int main(int argc, char **argv)
{
	const char *dev = DEFAULT_DEVICE;
	const char *line1 = NULL, *line2 = NULL;
	char version[256];
	char line2buf[256];
	int opt, fd, no_enable = 0, dump_only = 0, icon = -1;
	unsigned char rawbuf[256];
	long rawlen = -1;
	unsigned width = DEFAULT_WIDTH;
	const char *ready = DEFAULT_READY;
	const char *mpd_host = DEFAULT_MPD_HOST;
	unsigned mpd_port = DEFAULT_MPD_PORT;
	int no_mpd = 0;

	default_version(version, sizeof version);

	while ((opt = getopt(argc, argv, "d:v:1:2:i:X:w:R:m:p:LnDMh")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 'v': snprintf(version, sizeof version, "%s", optarg); break;
		case '1': line1 = optarg; break;
		case '2': line2 = optarg; break;
		case 'i':
			icon = icon_byte(optarg);
			if (icon == -2) {
				fprintf(stderr, "unknown icon \"%s\"\n", optarg);
				return 2;
			}
			break;
		case 'L': terminator = TERM_LF; break;
		case 'X':
			rawlen = parse_hex(optarg, rawbuf, sizeof rawbuf);
			if (rawlen <= 0) {
				fprintf(stderr, "bad hex payload\n");
				return 2;
			}
			break;
		case 'w': {
			long w = strtol(optarg, NULL, 10);
			if (w != 0 && (w < MIN_WIDTH || w > MAX_WIDTH)) {
				fprintf(stderr,
					"width must be 0 (no limit) or %d..%d\n",
					MIN_WIDTH, MAX_WIDTH);
				return 2;
			}
			width = (unsigned)w;
			break;
		}
		case 'R': ready = optarg; break;
		case 'm': mpd_host = optarg; break;
		case 'p': {
			long p = strtol(optarg, NULL, 10);
			if (p < 1 || p > 65535) {
				fprintf(stderr, "bad port\n");
				return 2;
			}
			mpd_port = (unsigned)p;
			break;
		}
		case 'M': no_mpd = 1; break;
		case 'n': no_enable = 1; break;
		case 'D': dump_only = 1; break;
		case 'h': usage(argv[0]); return 0;
		default:  usage(argv[0]); return 2;
		}
	}

	if (icon >= 0) {
		snprintf(line2buf, sizeof line2buf, "%c%s",
			 (char)(unsigned char)icon, line2 ? line2 : "");
		line2 = line2buf;
	}

	if (dump_only) {
		unsigned char buf[512];
		size_t n;

		printf("device     %s @ 9600 8N1, raw, no flow control\n\n", dev);
		if (rawlen > 0) {
			hexdump("enable(-X)", rawbuf, (size_t)rawlen);
		} else {
			n = frame(buf, sizeof buf, PANEL_ENABLE, version);
			hexdump("enable", buf, n);
		}
		if (line1) {
			n = frame(buf, sizeof buf, PANEL_LINE1, line1);
			hexdump("line1", buf, n);
		}
		if (line2) {
			n = frame(buf, sizeof buf, PANEL_LINE2, line2);
			hexdump("line2", buf, n);
		}
		return 0;
	}

	fd = panel_open(dev);
	if (fd < 0)
		return 1;

	/*
	 * The enable command, first, before anything else touches the
	 * port. Per the stock firmware this is what brings the panel up
	 * and keeps the unit powered on.
	 */
	if (!no_enable && rawlen > 0) {
		if (write_all(fd, rawbuf, (size_t)rawlen) < 0) {
			fprintf(stderr, "enable: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
		tcdrain(fd);
		fprintf(stderr, "panel enabled with %ld raw bytes\n", rawlen);
	} else if (!no_enable) {
		if (panel_send(fd, PANEL_ENABLE, version) < 0) {
			fprintf(stderr, "enable: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
		/* Do not return before it is on the wire. */
		tcdrain(fd);
		fprintf(stderr, "panel enabled with \"%s\"\n", version);
	}

	if (line1 || line2) {
		if (line1 && panel_send(fd, PANEL_LINE1, line1) < 0)
			fprintf(stderr, "line1: %s\n", strerror(errno));
		if (line2 && panel_send(fd, PANEL_LINE2, line2) < 0)
			fprintf(stderr, "line2: %s\n", strerror(errno));
		tcdrain(fd);
		close(fd);
		return 0;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

#ifdef HAVE_MPD
	if (!no_mpd)
		fprintf(stderr, "following MPD at %s:%u, ^C to stop\n",
			mpd_host, mpd_port);
	else
		fprintf(stderr, "monitoring %s, ^C to stop\n", dev);
#else
	(void)no_mpd; (void)mpd_host; (void)mpd_port;
	fprintf(stderr, "monitoring %s, ^C to stop\n", dev);
#endif

	{
		struct ui u = { .fd = fd, .width = width, .ready = ready };
		char acc[256];
		size_t used = 0;
		/*
		 * The panel repeats a token for as long as the button is
		 * held and never reports a release, so the first sight of a
		 * token is a press and every identical one after it is the
		 * same press still happening. BDP_POLL resuming is the only
		 * signal that the finger came off, so it is what re-arms.
		 *
		 * Acting on the press rather than on the release is a
		 * deliberate difference from the stock firmware, which waited
		 * so it could tell a tap from a hold and turn a held NEXT
		 * into a seek. Seeking is not implemented, and skipping one
		 * track per press is worth more than the option of adding it
		 * later - which would mean going back to release-based
		 * handling.
		 */
		/* Sized from acc so a long token cannot be truncated into
		 * looking like a different one, which would swallow a press. */
		char held[sizeof acc];

		held[0] = '\0';
		int ticks = 0;
#ifdef HAVE_MPD
		struct mpdlink m = { .host = mpd_host, .port = mpd_port };

		if (!no_mpd) {
			if (mpd_up(&m))
				mpd_render(&m, &u);
			else
				ui_show(&u, "BDP-1", (int)ICON_STOP, TEXT_NO_MPD);
		}
#else
		ui_show(&u, "BDP-1", (int)ICON_STOP, TEXT_NO_MPD);
#endif

		while (!stop_requested) {
			struct pollfd pfd[2];
			int nfd = 1;
			char buf[128];
			ssize_t n;
			int r;

			pfd[0].fd = fd;
			pfd[0].events = POLLIN;
			pfd[0].revents = 0;
#ifdef HAVE_MPD
			/* Only worth polling while idle is actually
			 * outstanding; at any other moment the socket
			 * readable means a response we are about to read
			 * ourselves. */
			if (!no_mpd && m.conn && m.idling) {
				pfd[1].fd = mpd_connection_get_fd(m.conn);
				pfd[1].events = POLLIN;
				pfd[1].revents = 0;
				nfd = 2;
			}
#endif
			r = poll(pfd, (nfds_t)nfd, TICK_MS);
			if (r < 0) {
				if (errno == EINTR)
					continue;
				fprintf(stderr, "poll: %s\n", strerror(errno));
				break;
			}

			if (r == 0) {
#ifdef HAVE_MPD
				/* MPD is not up, or went away. Keep trying,
				 * slowly, and say so on the display. */
				if (!no_mpd && !m.conn &&
				    ++ticks >= RECONNECT_TICKS) {
					ticks = 0;
					if (mpd_up(&m))
						mpd_render(&m, &u);
					else
						ui_show(&u, "BDP-1",
							(int)ICON_STOP,
							TEXT_NO_MPD);
				}
#else
				(void)ticks;
#endif
				continue;
			}

#ifdef HAVE_MPD
			if (nfd == 2 && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) {
				mpd_recv_idle(m.conn, false);
				m.idling = 0;
				if (mpd_connection_get_error(m.conn) != MPD_ERROR_SUCCESS) {
					mpd_drop(&m);
					ui_show(&u, "BDP-1", (int)ICON_STOP,
						TEXT_NO_MPD);
				} else {
					mpd_response_finish(m.conn);
					mpd_render(&m, &u);
				}
			}
#endif

			if (!(pfd[0].revents & POLLIN))
				continue;

			n = read(fd, buf, sizeof buf);
			if (n < 0) {
				if (errno == EINTR || errno == EAGAIN)
					continue;
				fprintf(stderr, "read: %s\n", strerror(errno));
				break;
			}
			if (n == 0)
				continue;

			for (ssize_t i = 0; i < n; i++) {
				if (buf[i] != '\n' && buf[i] != '\r') {
					if (used < sizeof acc - 1)
						acc[used++] = buf[i];
					continue;
				}
				if (used == 0)
					continue;
				acc[used] = '\0';
				used = 0;

				if (!strcmp(acc, "BDP_POLL")) {
					/* Heartbeat. Not an event, but it is
					 * what tells us the button came up. */
					held[0] = '\0';
					continue;
				}

				if (!strcmp(acc, held))
					continue;   /* still held down */
				snprintf(held, sizeof held, "%s", acc);

				/* Logged once per press, not once per repeat.
				 * The panel repeats for as long as a button is
				 * down, and /var/log is a tmpfs: a leaned-on
				 * key should not cost a hundred lines. */
				printf("%s\n", acc);
				fflush(stdout);

#ifdef HAVE_MPD
				if (!no_mpd) {
					if (!m.conn)
						(void)mpd_up(&m);
					if (m.conn && mpd_button(&m, acc))
						mpd_render(&m, &u);
				}
#endif
			}
		}
#ifdef HAVE_MPD
		mpd_drop(&m);
#endif
	}

	close(fd);
	return 0;
}
