# git-remote-s3 (PHP port)

> **This branch is a PHP 8.1+ translation** of the original Python package.
> The original Python source is at [awslabs/git-remote-s3](https://github.com/awslabs/git-remote-s3).

---

This library enables to use Amazon S3 as a git remote and LFS server.

It provides an implementation of a [git remote helper](https://git-scm.com/docs/gitremote-helpers) to use S3 as a serverless Git server.

It also provides an implementation of the [git-lfs custom transfer](https://github.com/git-lfs/git-lfs/blob/main/docs/custom-transfers.md) to enable pushing LFS managed files to the same S3 bucket used as remote.

## PHP Installation

### Requirements

- PHP 8.1+
- [Composer](https://getcomposer.org/)
- [AWS credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html) configured (via environment variables, `~/.aws/credentials`, or an IAM role)
- Git
- (Optional) git-lfs for LFS support

### Install dependencies

```bash
composer install
```

### Make executables available on your PATH

The three CLI entry-points live in `bin/`:

```bash
# Option 1 — symlink into a directory already on PATH
ln -s /path/to/git-remote-s3/bin/git-remote-s3   /usr/local/bin/git-remote-s3
ln -s /path/to/git-remote-s3/bin/git-lfs-s3      /usr/local/bin/git-lfs-s3
ln -s /path/to/git-remote-s3/bin/git-s3          /usr/local/bin/git-s3

# Option 2 — add bin/ to PATH
export PATH="$PATH:/path/to/git-remote-s3/bin"
```

### Running tests

```bash
composer require --dev phpunit/phpunit
vendor/bin/phpunit
```

---

## PHP-specific notes

### Parallel fetch

The Python implementation downloads git bundles concurrently using a thread
pool. PHP does not have standard native threads; the PHP port executes fetches
**sequentially**. Correctness is preserved; only throughput for large numbers
of simultaneous fetches may differ.

### AWS SDK

The Python `boto3` library is replaced by `aws/aws-sdk-php` (v3).
AWS credentials are resolved in the same order as the Python SDK:
environment variables → `~/.aws/credentials` → IAM instance profile.

### Logging

`monolog/monolog` is used as the PSR-3 logger, writing to `STDERR` for the
remote helper and to `.git/lfs/tmp/git-lfs-s3.log` for the LFS agent,
mirroring the Python `logging` configuration.

---

The rest of the documentation below is unchanged from the original Python README.

---

