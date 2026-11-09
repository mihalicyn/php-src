#!/bin/bash
# Runs the phpBB demo: PHP is built from source into ./local, and phpBB is
# served by PHP's built-in web server, as the current user.
#
# Usage: ./run-local.sh COMMAND [ARGS]
#
#   setup          build + install + warmup
#   build          build PHP (upstream php-src + php-exec-check.patch, or
#                  PHP_SRC=/path/to/php-src for a local git tree) and secbits
#   install        download phpBB and install it unattended (SQLite)
#   warmup         precompile the code phpBB generates, mark all code executable
#   serve [BITS]   serve phpBB on http://$HOST:$PORT (default 127.0.0.1:8080)
#                  with the given securebits: restrict_file (default),
#                  deny_interactive, both comma separated, or "" (audit mode)
#   check          PHP scenarios against the running kernel
#   crawl          crawl the running board, fail on any error page
#
# Everything is kept in ./local; rm -rf local to start over.
set -euo pipefail
cd "$(dirname "$0")"

TOP=$PWD
L=$TOP/local
PHP=$L/php-src/sapi/cli/php
SECBITS=$L/secbits
PHPBB=$L/phpbb
DATA=$L/data
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}
PHPBB_VERSION=3.3.19
PHPBB_SHA256=1530e5cabf7ecc9ecfaed3fa13da79f9e8a514623beafababc8800b5ce966de9

die() {
	echo "error: $*" >&2
	exit 1
}

need_php() {
	[ -x "$PHP" ] && [ -x "$SECBITS" ] || die "PHP is not built yet, run: ./run-local.sh build"
}

need_phpbb() {
	[ -s "$PHPBB/config.php" ] || die "phpBB is not installed yet, run: ./run-local.sh install"
}

cmd_build() {
	local missing=() t
	for t in cc make autoconf bison re2c pkg-config curl patch; do
		command -v "$t" >/dev/null || missing+=("$t")
	done
	for t in libxml-2.0 sqlite3; do
		pkg-config --exists "$t" 2>/dev/null || missing+=("$t (development files)")
	done
	[ ${#missing[@]} = 0 ] || die "missing: ${missing[*]} (see README.md, Requirements)"

	mkdir -p "$L"
	rm -rf "$L/php-src"
	if [ -n "${PHP_SRC:-}" ]; then
		# "git stash create" makes a commit of the working tree without
		# touching it or the stash list
		local rev
		rev=$(git -C "$PHP_SRC" stash create)
		echo "== PHP sources: $PHP_SRC$([ -n "$rev" ] && echo ' + uncommitted changes')"
		git -C "$PHP_SRC" archive --prefix=php-src/ "${rev:-HEAD}" | tar -x -C "$L"
	else
		local base
		base=$(sed -n 's/^Base: php\/php-src \([0-9a-f]\{40\}\)$/\1/p' php-exec-check.patch)
		echo "== PHP sources: php/php-src $base + php-exec-check.patch"
		curl -fsSL "https://github.com/php/php-src/archive/$base.tar.gz" | tar -xz -C "$L"
		mv "$L/php-src-$base" "$L/php-src"
		patch -d "$L/php-src" -p1 -s < php-exec-check.patch
	fi

	# phpBB needs mbstring; without its regex functions, it doesn't need
	# oniguruma. zlib is optional (compressed phars).
	local configure=(--disable-cgi --disable-phpdbg --enable-mbstring --disable-mbregex
		--with-sqlite3 --with-pdo-sqlite)
	pkg-config --exists zlib 2>/dev/null && configure+=(--with-zlib)

	echo "== Building PHP (log: local/build.log)"
	if ! (cd "$L/php-src" && ./buildconf --force && ./configure "${configure[@]}" && make -j"$(nproc)") > "$L/build.log" 2>&1; then
		tail -25 "$L/build.log" >&2
		die "PHP build failed, see local/build.log"
	fi
	grep -aq 'blocked by EXEC_RESTRICT_FILE' "$PHP" || die "the built PHP does not contain the exec check"

	cc -O2 -Wall -o "$SECBITS" secbits.c
	"$PHP" -v | head -1
	if "$SECBITS" restrict_file -- true 2>/dev/null; then
		echo "Kernel $(uname -r) supports the exec securebits"
	else
		echo "warning: kernel $(uname -r) can't set the exec securebits (Linux 6.14+ needed)" >&2
	fi
}

cmd_install() {
	need_php
	[ -s "$PHPBB/config.php" ] && die "phpBB is already installed (rm -rf local/phpbb local/data to reinstall)"

	if [ ! -e "$PHPBB/index.php" ]; then
		local zip="$L/phpBB-$PHPBB_VERSION.zip"
		echo "== Downloading phpBB $PHPBB_VERSION"
		curl -fSL -o "$zip" "https://download.phpbb.com/pub/release/3.3/$PHPBB_VERSION/phpBB-$PHPBB_VERSION.zip"
		echo "$PHPBB_SHA256  $zip" | sha256sum -c --quiet - || die "phpBB download checksum mismatch"
		rm -rf "$L/phpBB3"
		if command -v unzip >/dev/null; then
			unzip -q "$zip" -d "$L"
		else
			python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$L"
		fi
		mv "$L/phpBB3" "$PHPBB"
		rm -f "$zip"
	fi
	mkdir -p "$DATA"
	sed "s#dbhost: .*#dbhost: $DATA/phpbb.sqlite#" tests/install-config.yml > "$L/install-config.yml"

	echo "== Installing phpBB"
	(cd "$PHPBB" && "$PHP" -d error_reporting=24575 install/phpbbcli.php install "$L/install-config.yml")
	[ -s "$PHPBB/config.php" ] || die "the phpBB installer failed"
	# phpBB refuses to run while the installer exists
	rm -rf "$PHPBB/install"
	echo "Installed. Admin login: admin / adminadmin"
}

cmd_warmup() {
	need_php
	need_phpbb

	echo "== Purging the cache"
	find "$PHPBB/cache" -mindepth 1 -maxdepth 1 ! -name index.htm ! -name .htaccess -exec rm -rf {} +

	echo "== Precompiling"
	"$PHP" warmup.php "$PHPBB"

	echo "== Marking code executable"
	find "$PHPBB" -name '*.php' ! -path "$PHPBB/cache/*" -exec chmod a+x {} +
	# Generated code: executable and read-only. The data cache (data_*, sql_*)
	# is not code and stays writable and non-executable.
	find "$PHPBB/cache" -name '*.php' ! -name 'data_*' ! -name 'sql_*' -exec chmod 0555 {} +
	chmod 0555 "$PHPBB/config.php"
}

cmd_serve() {
	local bits=${1-restrict_file}
	need_php
	need_phpbb

	local args=(-d opcache.enable=0 -d memory_limit=256M -d error_reporting=24575
		-d display_errors=0 -d log_errors=1 -S "$HOST:$PORT" -t "$PHPBB")
	# Serve requests in parallel; workers inherit the securebits
	export PHP_CLI_SERVER_WORKERS=${PHP_CLI_SERVER_WORKERS:-4}

	echo "phpBB: http://$HOST:$PORT/  (admin / adminadmin), Ctrl-C to stop"
	echo "Securebits: ${bits:-none, audit mode}. opcache is off: cached scripts are not checked again."
	cd "$PHPBB"
	if [ -n "$bits" ]; then
		exec "$SECBITS" "$bits" -- "$PHP" "${args[@]}"
	fi
	exec "$PHP" "${args[@]}"
}

cmd_check() {
	need_php
	tests/exec-check-matrix.sh "$PHP" "$SECBITS"
}

cmd_crawl() {
	need_php
	"$PHP" tests/crawl.php "http://$HOST:$PORT" "$@"
}

cmd_setup() {
	cmd_build
	cmd_install
	cmd_warmup
	echo
	echo "Next: ./run-local.sh check, then ./run-local.sh serve"
}

case "${1:-}" in
	setup|build|install|warmup|serve|check|crawl)
		cmd=$1
		shift
		"cmd_$cmd" "$@"
		;;
	*)
		sed -n '2,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0"
		exit 2
		;;
esac
