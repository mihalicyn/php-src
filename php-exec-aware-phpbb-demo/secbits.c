/*
 * secbits - set the exec securebits (Linux 6.14+), then run a command.
 *
 *   secbits restrict_file,deny_interactive -- php-fpm -F
 *
 * Bits: restrict_file, restrict_file_locked, deny_interactive,
 * deny_interactive_locked (comma separated). The bits are inherited by the
 * command and its children. A released setpriv(1) does not support them yet.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

/* from <linux/securebits.h> */
static const struct {
	const char *name;
	int bit;
} names[] = {
	{ "restrict_file",           1 << 8 },
	{ "restrict_file_locked",    1 << 9 },
	{ "deny_interactive",        1 << 10 },
	{ "deny_interactive_locked", 1 << 11 },
};

static void usage(void)
{
	fprintf(stderr, "usage: secbits BIT[,BIT...] [--] COMMAND [ARG...]\nbits:");
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		fprintf(stderr, " %s", names[i].name);
	}
	fputc('\n', stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	int mask = 0, cur;
	char *list, *tok, *save = NULL;

	if (argc < 3) {
		usage();
	}

	list = strdup(argv[1]);
	for (tok = strtok_r(list, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
		size_t i;

		if (*tok == '+') {
			tok++;
		}
		for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
			if (strcmp(tok, names[i].name) == 0) {
				mask |= names[i].bit;
				break;
			}
		}
		if (i == sizeof(names) / sizeof(names[0])) {
			fprintf(stderr, "secbits: unknown bit '%s'\n", tok);
			usage();
		}
	}
	free(list);

	argv += 2;
	if (*argv && strcmp(*argv, "--") == 0) {
		argv++;
	}
	if (!*argv) {
		usage();
	}

	cur = prctl(PR_GET_SECUREBITS);
	if (cur < 0 || prctl(PR_SET_SECUREBITS, (unsigned long) (cur | mask)) < 0) {
		/* Fail closed: don't run the command unrestricted */
		fprintf(stderr, "secbits: cannot set securebits 0x%x: %s (Linux 6.14+ required)\n",
			mask, strerror(errno));
		return 1;
	}
	fprintf(stderr, "secbits: securebits 0x%x -> 0x%x, running %s\n",
		cur, prctl(PR_GET_SECUREBITS), argv[0]);

	execvp(argv[0], argv);
	fprintf(stderr, "secbits: cannot execute %s: %s\n", argv[0], strerror(errno));
	return 127;
}
