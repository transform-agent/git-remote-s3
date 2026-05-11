# git-remote-s3 — Rust translation

This directory contains a complete Rust re-implementation of the
[`git-remote-s3`](https://github.com/awslabs/git-remote-s3) project.

## Structure

```
rust/
├── Cargo.toml               # package manifest — three binaries + one library
├── src/
│   ├── lib.rs               # crate root with public re-exports
│   ├── enums.rs             # UriScheme (S3 / S3Zip)
│   ├── common.rs            # parse_git_url()
│   ├── git.rs               # git subprocess wrappers + GitError
│   ├── remote.rs            # S3Remote — core git-remote-helper state machine
│   ├── lfs.rs               # LFSProcess — git-lfs custom transfer agent
│   └── manage.rs            # Doctor + ManageBranch
└── src/bin/
    ├── git_remote_s3.rs     # entry-point: git-remote-s3 / git-remote-s3+zip
    ├── git_lfs_s3.rs        # entry-point: git-lfs-s3
    └── git_s3.rs            # entry-point: git-s3
```

## Building

```bash
cd rust
cargo build --release
```

The compiled binaries will be at:
- `target/release/git-remote-s3`
- `target/release/git-lfs-s3`
- `target/release/git-s3`

## Installing

Copy or symlink the binaries to a directory on your `$PATH`, e.g.:

```bash
cargo install --path .
```

or manually:

```bash
cp target/release/git-remote-s3 /usr/local/bin/
cp target/release/git-lfs-s3    /usr/local/bin/
cp target/release/git-s3        /usr/local/bin/
```

## Running tests

```bash
cd rust
cargo test
```

Tests that require a live AWS S3 bucket or a real git repository are
marked `#[ignore]` and can be run explicitly with:

```bash
cargo test -- --ignored
```

## Dependency mapping

| Python | Rust |
|--------|------|
| `boto3` / `botocore` | `aws-sdk-s3` (AWS SDK for Rust) |
| `argparse` | `clap` |
| `re` | `regex` |
| `threading` / `concurrent.futures` | `tokio::task::spawn` |
| `subprocess` | `std::process::Command` |
| `tempfile` | `tempfile` crate |
| `json` | `serde_json` |
| `uuid` | `uuid` crate |
| `datetime` | `chrono` |
| `logging` | `tracing` + `tracing-subscriber` |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GIT_REMOTE_S3_VERBOSE` | `""` | Set to `1`, `true`, or `yes` to enable INFO-level logging |
| `GIT_REMOTE_S3_LOCK_TTL_SECONDS` | `60` | Seconds after which an S3 lock is considered stale |

## Notes on the S3 locking mechanism

`git-remote-s3` uses S3 conditional writes (`If-None-Match: *`) to implement
per-ref locking.  The Rust SDK exposes this via `.if_none_match("*")` on the
`put_object` builder.  Staleness detection uses `chrono::Utc::now()` minus the
object's `LastModified` timestamp.
