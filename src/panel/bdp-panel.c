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
 * Phase 3 folds this into the bdp-panel daemon proper, alongside the
 * menu tree, the settings web UI and the watchdog. This file is the
 * link layer and a way to prove it works.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

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
		"  -h         this\n"
		"\n"
		"With no -1/-2, sends enable and then reports button events\n"
		"until interrupted.\n",
		argv0, DEFAULT_DEVICE);
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

	default_version(version, sizeof version);

	while ((opt = getopt(argc, argv, "d:v:1:2:i:X:LnDh")) != -1) {
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

	fprintf(stderr, "monitoring %s, ^C to stop\n", dev);

	{
		char acc[256];
		size_t used = 0;

		while (!stop_requested) {
			struct pollfd pfd = { .fd = fd, .events = POLLIN };
			char buf[128];
			ssize_t n;

			int r = poll(&pfd, 1, 500);
			if (r < 0) {
				if (errno == EINTR)
					continue;
				fprintf(stderr, "poll: %s\n", strerror(errno));
				break;
			}
			if (r == 0)
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
				if (buf[i] == '\n' || buf[i] == '\r') {
					if (used > 0) {
						acc[used] = '\0';
						/* POLL is the panel's heartbeat and
						 * arrives constantly; it is not an
						 * event worth printing. */
						if (strcmp(acc, "BDP_POLL") != 0)
							printf("%s\n", acc);
						fflush(stdout);
						used = 0;
					}
				} else if (used < sizeof acc - 1) {
					acc[used++] = buf[i];
				}
			}
		}
	}

	close(fd);
	return 0;
}
