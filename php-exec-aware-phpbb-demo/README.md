# PHP + AT_EXECVE_CHECK: phpBB demo

A proof of concept of PHP refusing to run code from files the kernel says
aren't executable (Linux 6.14+ `AT_EXECVE_CHECK`, enforced by the
`SECBIT_EXEC_RESTRICT_FILE` and `SECBIT_EXEC_DENY_INTERACTIVE` securebits),
field-tested with phpBB 3.3 and SQLite.

`run-local.sh` builds PHP from source (upstream php-src at the commit named in
`php-exec-check.patch`, with that patch applied), installs phpBB, and serves it
with PHP's built-in web server, all as the current user in `./local`.

## Requirements

- **Linux 6.14 or newer**. On older kernels the securebits can't be set and
  nothing is enforced.
- A C toolchain and PHP's build dependencies, plus `curl`, `patch`, and
  `unzip` or `python3`:

  ```sh
  # Debian, Ubuntu
  sudo apt install build-essential autoconf bison re2c pkg-config \
      libxml2-dev libsqlite3-dev zlib1g-dev curl patch unzip
  # Fedora
  sudo dnf install gcc make autoconf bison re2c pkgconf-pkg-config \
      libxml2-devel sqlite-devel zlib-devel curl patch unzip
  ```

## Steps

```sh
./run-local.sh setup      # build PHP, install phpBB, warm up its generated code
./run-local.sh check      # PHP scenarios against the kernel: all must pass
./run-local.sh serve      # http://127.0.0.1:8080/ with restrict_file enforced
```

`setup` takes a few minutes, mostly compiling PHP (log: `local/build.log`).
It runs `build`, `install` and `warmup`, which can also be run one by one.

The board is at http://127.0.0.1:8080/, admin login **admin / adminadmin**.
`HOST=0.0.0.0 PORT=8000 ./run-local.sh serve` serves it on another address.

In another terminal, check the whole board in one go (about 40 pages,
including 16 ACP modules):

```sh
./run-local.sh crawl
```

## Break it

```sh
chmod a-x local/phpbb/viewtopic.php
```

Opening a topic now fails (HTTP 500), and the server's terminal says why:

```
PHP Fatal error:  Failed to execute "/.../local/phpbb/viewtopic.php": blocked by EXEC_RESTRICT_FILE in Unknown on line 0
127.0.0.1:45630 [500]: GET /viewtopic.php?t=1 - Failed to execute ...
```

The same happens with an included file, which breaks every page using it:
`chmod a-x local/phpbb/includes/functions_display.php`. Restore with
`chmod a+x`.

Restart in audit mode, and everything runs: the checks still happen, but
aren't enforced:

```sh
./run-local.sh serve ""
```

To start over: `rm -rf local`.

## Securebits

`./run-local.sh serve BITS` runs the server with:

| BITS                             | Effect                                          |
|----------------------------------|-------------------------------------------------|
| `""`                             | audit mode: checked, never enforced             |
| `restrict_file` (default)        | non-executable PHP files are refused            |
| `deny_interactive`               | stdin, `php -r`, `php -a` are refused           |
| `restrict_file,deny_interactive` | both                                            |

The `*_locked` variants (e.g. `restrict_file_locked`) stop children from
clearing them. They are set by `secbits` (`secbits.c`, built into
`local/secbits`), since no released `setpriv` supports them yet, and inherited
by everything it starts:

```sh
local/secbits deny_interactive -- local/php-src/sapi/cli/php -r 'echo 1;'
# Could not execute command line code: blocked by EXEC_DENY_INTERACTIVE
```

`strace` shows every check PHP makes, enforced or not:

```sh
strace -f -qq -y -e trace=execveat -e signal=none -p "$(pgrep -d, -f 'php.* -S ')"
# execveat(7</.../viewtopic.php>, "", ["viewtopic.php"], NULL, AT_EMPTY_PATH|AT_EXECVE_CHECK) = 0
```

## phpBB generates PHP code at runtime

| File                                                      | Generated                                        |
|-----------------------------------------------------------|--------------------------------------------------|
| `config.php`                                              | by the installer                                 |
| `cache/production/container_*.php`, `autoload_*.php`      | on the first request, per entry point directory  |
| `cache/production/url_matcher.php`, `url_generator.php`   | on the first routed request                      |
| `cache/production/s9e_renderer_*.php`                     | on the first post rendered, and when BBCodes, smilies or censored words change |
| `cache/production/twig/**.php`                            | when a template is first rendered                |

Without the executable bit, `restrict_file` refuses them even when every
shipped file is executable: that's W^X doing its job. The warm-up
(`warmup.php`) generates all of them up front: it bootstraps phpBB from each
entry point directory (the board root and `adm/`: the compiled container and
Twig's cache keys depend on it) and compiles every template of the active
styles, the ACP and the e-mails, for all languages and enabled extensions.
Then all code is marked executable.

Anything that generates new code is refused until `./run-local.sh warmup`
runs again: purging the cache, installing styles or extensions, changing
BBCodes, smilies or censored words. Try it: purge the cache in the ACP, and
every page fails.

The data cache (`cache/production/data_*.php`, `sql_*.php`) is not code:
despite the `.php` extension, phpBB reads it with `fopen()` and
`unserialize()`, so it stays writable and non-executable.

Generated code must not stay writable by the web server: overwriting a file
keeps its executable bit, so an executable file the server can write would
defeat W^X. The warm-up makes it read-only, but here the server runs as the
same user that owns the files, which can make them writable again: fine for a
demo. A production setup runs the server as a user that doesn't own the code.

## Known limitations

- **opcache** is off: a cached script is not checked again, so `chmod a-x`
  only takes effect after a cache reset. Processes in different security
  domains should not share an opcache (shared memory or
  `opcache.file_cache`).
- **Whole-archive compressed phars** (`.phar.gz`, `.phar.bz2`) are refused
  under `restrict_file`: phar keeps no descriptor of the original archive.
- phpBB 3.3 predates this PHP version; deprecation notices are hidden.

## Building from a local php-src tree

```sh
PHP_SRC=~/git/php-src ./run-local.sh build
```

Uncommitted changes to tracked files are included (new files must be
`git add`ed).

## Files

| File                         | Purpose                                                  |
|------------------------------|----------------------------------------------------------|
| `run-local.sh`               | builds PHP, installs and serves phpBB, runs the checks   |
| `php-exec-check.patch`       | the PHP change, against the php-src commit in its header |
| `secbits.c`                  | sets the exec securebits, then runs a command            |
| `warmup.php`                 | precompiles phpBB's generated code                       |
| `tests/exec-check-matrix.sh` | PHP scenarios against the running kernel                 |
| `tests/crawl.php`            | crawls the board, fails on any error page                |
| `tests/install-config.yml`   | phpBB installer settings                                 |
