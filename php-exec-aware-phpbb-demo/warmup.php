<?php
/**
 * Precompiles the PHP code that phpBB generates at runtime, so that a
 * deployment can mark it executable before SECBIT_EXEC_RESTRICT_FILE is
 * enforced:
 *
 *  - the Symfony container and class autoloader (cache/<env>/container_*.php,
 *    autoload_*.php),
 *  - the router (cache/<env>/url_matcher.php, url_generator.php),
 *  - the s9e TextFormatter renderer for posts (cache/<env>/s9e_renderer_*.php),
 *  - the Twig templates of all active styles, the ACP and the e-mails, for
 *    all installed languages and enabled extensions (cache/<env>/twig/).
 *
 * The data cache (data_*.php, sql_*.php) is not code: phpBB reads it with
 * fopen() and unserialize(), so it doesn't need to be warmed up.
 *
 * Usage: php warmup.php [PHPBB_ROOT]
 *
 * Run it as the web server user, on the same phpBB path as the web server:
 * Twig's cache keys depend on the absolute path of the templates and on the
 * working directory, and phpBB's container cache on the relative root path.
 * That's why each entry point context runs in its own process, from the
 * directory its scripts run in.
 */

if (PHP_SAPI !== 'cli') {
	exit(1);
}

// Entry point contexts: the directory scripts run in, and their root path
const CONTEXTS = [
	// index.php, viewtopic.php, app.php, cron.php, ...
	'front' => ['dir' => '.', 'root' => './'],
	// adm/index.php (and download/file.php, which uses the same root path)
	'adm' => ['dir' => 'adm', 'root' => './../'],
];

if (($argv[1] ?? '') !== '--context') {
	$phpbb = realpath($argv[1] ?? '.');
	if ($phpbb === false || !is_file("$phpbb/common.php") || !is_file("$phpbb/config.php")) {
		fwrite(STDERR, "Usage: php {$argv[0]} [PHPBB_ROOT]\n");
		exit(1);
	}
	if (is_dir("$phpbb/install")) {
		fwrite(STDERR, "warning: $phpbb/install exists, phpBB refuses to run until it is removed\n");
	}

	$status = 0;
	foreach (CONTEXTS as $name => $context) {
		$cmd = [PHP_BINARY, '-d', 'error_reporting=' . (E_ALL & ~E_DEPRECATED), __FILE__, '--context', $name];
		$proc = proc_open($cmd, [STDIN, STDOUT, STDERR], $pipes, "$phpbb/{$context['dir']}");
		if (!is_resource($proc) || proc_close($proc) !== 0) {
			$status = 1;
		}
	}
	exit($status);
}

// --- In a context process, from the context's directory --------------------

$context = CONTEXTS[$argv[2]];
echo "[{$argv[2]}] ", getcwd(), "\n";

define('IN_PHPBB', true);
$phpbb_root_path = $context['root'];
$phpEx = 'php';
// Builds and caches the container and the autoloader
require $phpbb_root_path . 'common.php';
require_once $phpbb_root_path . 'includes/functions_messenger.php';

// Act as a visitor without a session: the anonymous user, default style
$result = $db->sql_query('SELECT * FROM ' . USERS_TABLE . ' WHERE user_id = ' . ANONYMOUS);
$user->data = $db->sql_fetchrow($result);
$db->sql_freeresult($result);
$result = $db->sql_query('SELECT * FROM ' . STYLES_TABLE . ' WHERE style_id = ' . (int) $config['default_style']);
$user->style = $db->sql_fetchrow($result);
$db->sql_freeresult($result);

/** @var \phpbb\di\service_collection $phpbb_container */
$router = $phpbb_container->get('router');
$router->get_matcher();
$router->get_generator();

// The s9e TextFormatter renderer that turns posts into HTML is compiled to
// cache/<env>/s9e_renderer_*.php when it is first needed
$phpbb_container->get('text_formatter.renderer');

/** @var \Twig\Environment $twig */
$twig = $phpbb_container->get('template.twig.environment');
$compiled = 0;
$errors = 0;

/**
 * Compiles every template file that the loader can currently reach. The
 * compiled file depends on the template's path, not on the name it is
 * loaded by, so loading each file once by any name is enough.
 */
function compile_reachable(\Twig\Environment $twig, string $what)
{
	global $compiled, $errors;

	$loader = $twig->getLoader();
	$count = 0;
	foreach ($loader->getNamespaces() as $namespace) {
		foreach ($loader->getPaths($namespace) as $path) {
			$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS));
			foreach ($it as $file) {
				if (!preg_match('/\.(html|twig|txt)$/', $file->getFilename())) {
					continue;
				}
				$relative = substr($file->getPathname(), strlen(rtrim($path, '/')) + 1);
				$name = ($namespace === \Twig\Loader\FilesystemLoader::MAIN_NAMESPACE ? '' : "@$namespace/") . $relative;
				try {
					$twig->load($name);
					$count++;
				} catch (\Throwable $e) {
					fwrite(STDERR, "  $what: $name: " . $e->getMessage() . "\n");
					$errors++;
				}
			}
		}
	}
	$compiled += $count;
	echo "  $what: $count templates\n";
}

// Styles. download/file.php renders them from the adm context's root path.
$sql = 'SELECT * FROM ' . STYLES_TABLE . ' WHERE style_active = 1';
$result = $db->sql_query($sql);
while ($row = $db->sql_fetchrow($result)) {
	$user->style = $row;
	$template->set_style();
	compile_reachable($twig, "style {$row['style_path']}");
}
$db->sql_freeresult($result);

// ACP, as adm/index.php sets it up
if ($argv[2] === 'adm') {
	$template->set_custom_style([['name' => 'adm', 'ext_path' => 'adm/style/']], './style');
	compile_reachable($twig, 'acp');
}

// E-mails, through phpBB's own messenger: it uses its own Twig environment,
// whose options (and so cache keys) differ from the main one.
class warmup_messenger extends messenger
{
	public function compile(string $file, string $lang, string $prefix): bool
	{
		$this->template($file, $lang, '', $prefix);
		$this->template->assign_display('body');
		return true;
	}
}

$messenger = new warmup_messenger(false);
$languages = [];
foreach (glob($phpbb_root_path . 'language/*/email', GLOB_ONLYDIR) as $dir) {
	$languages[] = basename(dirname($dir));
}
$extensions = $phpbb_container->get('ext.manager')->all_enabled();
foreach ($languages as $lang) {
	$sources = ['' => $phpbb_root_path . "language/$lang/email"];
	foreach ($extensions as $ext_name => $ext_path) {
		$sources['@' . str_replace('/', '_', $ext_name) . '/'] = $ext_path . "language/$lang/email";
	}
	$count = 0;
	foreach ($sources as $namespace => $dir) {
		if (!is_dir($dir)) {
			continue;
		}
		$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
		foreach ($it as $file) {
			if ($file->getExtension() !== 'txt') {
				continue;
			}
			$sub = trim(substr($file->getPath(), strlen($dir)), '/');
			try {
				$messenger->compile($namespace . $file->getBasename('.txt'), $lang, $sub);
				$count++;
			} catch (\Throwable $e) {
				fwrite(STDERR, "  e-mail $lang: $namespace$sub/{$file->getFilename()}: " . $e->getMessage() . "\n");
				$errors++;
			}
		}
	}
	$compiled += $count;
	echo "  e-mail $lang: $count templates\n";
}

echo "[{$argv[2]}] $compiled templates compiled, $errors errors\n";
exit($errors ? 1 : 0);
