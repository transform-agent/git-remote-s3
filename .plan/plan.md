# Translation Plan: git-remote-s3 → PHP

## 1. Source Language & Frameworks

- **Language**: Python 3.10+
- **Package manager**: Poetry / pip
- **Key libraries**:
  - `boto3` / `botocore` — AWS SDK for Python (S3 access)
  - `subprocess` — spawning git/shell sub-processes
  - `threading` / `concurrent.futures` — parallel fetches
  - `argparse` — CLI argument parsing
  - `json`, `re`, `os`, `sys`, `tempfile`, `logging` — standard library
- **Entrypoints** (console scripts):
  - `git-remote-s3` / `git-remote-s3+zip` → `git_remote_s3.remote:main`
  - `git-lfs-s3` → `git_remote_s3.lfs:main`
  - `git-s3` → `git_remote_s3.manage:main`
- **Test framework**: `pytest` + `mock`

---

## 2. Target Language & Ecosystem

- **Language**: PHP 8.1+
- **Package manager**: Composer
- **Directory layout**: `src/` for library code, `bin/` for CLI entry-point scripts, `tests/` for PHPUnit tests
- **Key library substitutions**:

| Python | PHP |
|---|---|
| `boto3` / `botocore` | `aws/aws-sdk-php` (AWS SDK for PHP v3) |
| `subprocess.run(["git", …])` | `proc_open` / `exec` wrappers |
| `threading.Lock` + `concurrent.futures.ThreadPoolExecutor` | `parallel` extension or `amphp/amp` fibers — we use PHP's built-in `pthreads`-free approach via `pcntl` fork or simply serialize fetch (parallel fetch is a performance optimisation, not a correctness requirement); we keep the same interface but run fetches sequentially in the first version and note it as a manual-review item |
| `enum.Enum` | PHP 8.1 `enum` |
| `argparse.ArgumentParser` | manual `getopt` / hand-written argument parser |
| `pytest` + `mock` | `phpunit/phpunit` + `php-mock/php-mock-phpunit` |
| `logging` | `monolog/monolog` (PSR-3) |
| `tempfile.mkdtemp` | `sys_get_temp_dir()` + `tempnam()` |

---

## 3. File-by-File Mapping

| Source path | Target path | Notes |
|---|---|---|
| `git_remote_s3/__init__.py` | `src/GitRemoteS3/GitRemoteS3.php` | Namespace bootstrap / re-exports; becomes a simple PHP file that `use`-imports the classes |
| `git_remote_s3/enums.py` | `src/GitRemoteS3/UriScheme.php` | Python `Enum` → PHP 8.1 backed `enum UriScheme: string` |
| `git_remote_s3/common.py` | `src/GitRemoteS3/Common.php` | `parse_git_url()` static method using `preg_match`; returns array `[$uriScheme, $profile, $bucket, $prefix]` |
| `git_remote_s3/git.py` | `src/GitRemoteS3/Git.php` | All git subprocess helpers → PHP class `Git` with static methods; `GitError` → PHP `\RuntimeException` subclass |
| `git_remote_s3/lfs.py` | `src/GitRemoteS3/Lfs.php` | `LFSProcess` class + `install()` + `main()` translated; `ProgressPercentage` → closure callback; threading not used (sequential upload/download) |
| `git_remote_s3/remote.py` | `src/GitRemoteS3/Remote.php` | `S3Remote` class + `main()`; `BucketNotFoundError`, `NotAuthorizedError` → PHP Exception subclasses; parallel fetch → sequential (noted in risks); lock logic preserved |
| `git_remote_s3/manage.py` | `src/GitRemoteS3/Manage.php` | `Doctor` + `ManageBranch` classes + `main()`; interactive CLI prompts via `fgets(STDIN)` |
| `pyproject.toml` | `composer.json` | Declares dependencies: `aws/aws-sdk-php`, `monolog/monolog`; dev deps: `phpunit/phpunit` |
| `test/parse_url_test.py` | `tests/ParseUrlTest.php` | PHPUnit test class; all assertions translated 1:1 |
| `test/parallel_fetch_test.py` | `tests/ParallelFetchTest.php` | PHPUnit; mocking via `\PHPUnit\Framework\MockObject`; parallel threading tests become sequential (annotated) |
| `test/remote_test.py` | `tests/RemoteTest.php` | PHPUnit; mock AWS SDK client; all test functions translated |
| *(new)* | `bin/git-remote-s3` | Thin PHP CLI shim: `#!/usr/bin/env php` → calls `Remote::main()` |
| *(new)* | `bin/git-lfs-s3` | Thin PHP CLI shim → calls `Lfs::main()` |
| *(new)* | `bin/git-s3` | Thin PHP CLI shim → calls `Manage::main()` |
| `README.md` | `README.md` | Updated installation instructions for PHP/Composer |

Files **not** translated (kept as-is or skipped):
- `.github/workflows/` — GitHub CI configs (must not be written/modified per policy)
- `poetry.lock` — replaced by `composer.lock` (auto-generated; not hand-written)
- `.flake8` — Python linter config, irrelevant in PHP
- `Config` — Amazon-internal Brazil build config, no PHP equivalent needed

---

## 4. Dependency Substitutions

```json
{
  "require": {
    "php": ">=8.1",
    "aws/aws-sdk-php": "^3.0",
    "monolog/monolog": "^3.0"
  },
  "require-dev": {
    "phpunit/phpunit": "^11.0"
  }
}
```

---

## 5. Risks, Ambiguities & Manual-Review Items

1. **Parallel fetch**: Python uses `ThreadPoolExecutor` to download bundles concurrently. PHP lacks native threads in the standard SAPI. The translation runs fetches sequentially; a `pcntl_fork`-based or ReactPHP-based parallel implementation is out of scope but noted.
2. **S3 conditional writes (`IfNoneMatch: *`)**: The PHP AWS SDK v3 supports `IfNoneMatch` as a parameter to `putObject`. This is preserved. However, `412 PreconditionFailed` HTTP status handling must be mapped from the PHP SDK's exception mechanism (`S3Exception`). Needs careful testing.
3. **`boto3.Session.resource("s3")`** (used in LFS): The PHP SDK does not have a "resource" abstraction. The LFS code will be refactored to use `S3Client` directly (equivalent functionality via `putObject`, `getObject`, `listObjectsV2`).
4. **Stdin/stdout protocol**: The git remote helper protocol is line-based on stdin/stdout. PHP's `fgets(STDIN)` / `fwrite(STDOUT, …)` is a direct equivalent. Output buffering must be disabled (`ob_implicit_flush(true)`).
5. **`os.dup2(devnull, sys.stdout.fileno())`** for BrokenPipeError: PHP does not have a direct equivalent. A `try/catch` on `\Exception` with `@fclose(STDOUT)` is used as the closest approximation.
6. **Interactive prompts in `Doctor`/`ManageBranch`**: `input()` → `fgets(STDIN)` + `trim()`; identical UX.
7. **`argparse` with positional + optional `branch`**: Python's argparse has nuanced positional handling. The PHP CLI argument parser replicates the same argument names. The `branch` argument is optional/positional in Python but required for branch commands — preserved.
8. **`removeprefix()` (Python 3.9+)**: Translated to PHP `substr($str, strlen($prefix))` with a leading-slash guard.
9. **Logging** (`logging.basicConfig`): Translated to Monolog `StreamHandler` writing to `STDERR` for remote/manage, and to a file for LFS.
10. **Test mocking**: The Python tests mock `boto3.Session.client` at the module level. PHPUnit tests will mock the `S3Client` via constructor injection (the `S3Remote` class will accept an optional `S3Client` parameter to allow test injection). This requires a small refactor of the constructor signature.

---

## 6. Implementation Order (Phase 2)

1. `composer.json`
2. `src/GitRemoteS3/UriScheme.php` (enum — no dependencies)
3. `src/GitRemoteS3/Common.php` (depends on UriScheme)
4. `src/GitRemoteS3/Git.php` (standalone subprocess helpers)
5. `src/GitRemoteS3/Remote.php` (depends on UriScheme, Common, Git)
6. `src/GitRemoteS3/Lfs.php` (depends on Common, Git)
7. `src/GitRemoteS3/Manage.php` (depends on Remote, Git)
8. `src/GitRemoteS3/GitRemoteS3.php` (namespace entry point)
9. `bin/git-remote-s3`
10. `bin/git-lfs-s3`
11. `bin/git-s3`
12. `tests/ParseUrlTest.php`
13. `tests/ParallelFetchTest.php`
14. `tests/RemoteTest.php`
15. `README.md` update (PHP installation notes appended)
