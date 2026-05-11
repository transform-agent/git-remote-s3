# Translation Plan: git-remote-s3 → Rust

## 1. Source Language & Framework

| Item | Detail |
|------|--------|
| Language | Python 3.10+ |
| Package manager | Poetry (`pyproject.toml`) |
| Runtime deps | `boto3` / `botocore` (AWS SDK for Python), `urllib3` |
| Dev deps | pytest, mock, mypy, flake8, black, coverage |
| Entry-points | `git-remote-s3` / `git-remote-s3+zip` → `remote:main`; `git-lfs-s3` → `lfs:main`; `git-s3` → `manage:main` |

---

## 2. Target Language: Rust

| Item | Detail |
|------|--------|
| Toolchain | Rust 2021 edition (stable) |
| Build / package manager | Cargo (`Cargo.toml`) |
| Workspace layout | Single Cargo workspace with three binary crates (targets): `git-remote-s3`, `git-lfs-s3`, `git-s3` |

---

## 3. Dependency / Library Substitutions

| Python | Rust crate | Notes |
|--------|-----------|-------|
| `boto3` / `botocore` | `aws-sdk-s3` (from `aws-sdk-rust`) | Official AWS SDK for Rust |
| `argparse` | `clap` (feature `derive`) | CLI argument parsing |
| `re` (regex) | `regex` | Same semantics |
| `threading.Lock` / `concurrent.futures.ThreadPoolExecutor` | `std::sync::Mutex` + `rayon` or `tokio::task::spawn` | Parallel fetch; we use `tokio` since the AWS SDK already requires it |
| `subprocess` | `std::process::Command` | Wraps `git` binary |
| `tempfile` | `tempfile` crate | Temporary directories/files |
| `json` | `serde_json` | JSON serialisation for LFS protocol |
| `uuid` | `uuid` crate | UUID generation in `manage` |
| `datetime` | `chrono` | Date/time arithmetic for lock TTL |
| `logging` | `tracing` + `tracing-subscriber` | Structured logging to stderr |
| `enum` | `enum` (Rust native) | `UriScheme` maps directly |

---

## 4. File-by-File Mapping

| Source (Python) | Target (Rust) | Approach |
|-----------------|---------------|---------|
| `git_remote_s3/enums.py` | `rust/src/enums.rs` | `enum UriScheme { S3, S3Zip }` with `Display`/`FromStr` |
| `git_remote_s3/common.py` | `rust/src/common.rs` | `parse_git_url()` using the `regex` crate |
| `git_remote_s3/git.py` | `rust/src/git.rs` | Thin wrappers over `std::process::Command`; custom `GitError` |
| `git_remote_s3/remote.py` | `rust/src/remote.rs` + `rust/src/bin/git_remote_s3.rs` | `S3Remote` struct; async via `tokio`; parallel fetch with `tokio::task::spawn` |
| `git_remote_s3/lfs.py` | `rust/src/lfs.rs` + `rust/src/bin/git_lfs_s3.rs` | `LFSProcess` struct; stdin event loop; AWS SDK S3 |
| `git_remote_s3/manage.py` | `rust/src/manage.rs` + `rust/src/bin/git_s3.rs` | `Doctor` + `ManageBranch` structs; `clap` CLI |
| `git_remote_s3/__init__.py` | `rust/src/lib.rs` | Re-exports of public items |
| `pyproject.toml` | `rust/Cargo.toml` | Workspace manifest, three `[[bin]]` targets |
| `test/parse_url_test.py` | `rust/tests/parse_url_test.rs` | Cargo integration tests |
| `test/parallel_fetch_test.py` | `rust/tests/parallel_fetch_test.rs` | Tests using `mockall` / direct struct construction |
| `test/remote_test.py` | `rust/tests/remote_test.rs` | Comprehensive S3Remote tests using `mockall` |

All source files remain untouched; Rust code is written into a new `rust/` subdirectory.

---

## 5. Architecture Notes

### Binary structure
```
rust/
├── Cargo.toml               # workspace / package manifest
├── src/
│   ├── lib.rs               # crate root — re-exports
│   ├── enums.rs             # UriScheme
│   ├── common.rs            # parse_git_url
│   ├── git.rs               # git subprocess helpers + GitError
│   ├── remote.rs            # S3Remote + BucketNotFoundError + NotAuthorizedError
│   ├── lfs.rs               # LFSProcess + ProgressCallback
│   └── manage.rs            # Doctor + ManageBranch
└── src/bin/
    ├── git_remote_s3.rs     # main() for git-remote-s3 / git-remote-s3+zip
    ├── git_lfs_s3.rs        # main() for git-lfs-s3
    └── git_s3.rs            # main() for git-s3
```

### Async runtime
`tokio` (multi-threaded) is used throughout because `aws-sdk-s3` is async. The `#[tokio::main]` macro wraps every `main()`.

### Parallel fetch
`cmd_fetch` is an `async fn`. `process_fetch_cmds` spawns one `tokio::task` per command and joins them — mirrors the Python `ThreadPoolExecutor`.

### Locking (acquire / release)
S3 conditional write (`IfNoneMatch: "*"`) is reproduced using the `aws-sdk-s3` `put_object` builder's `.if_none_match("*")`. The staleness check uses `chrono::Utc::now()`.

### Error handling
Python `sys.exit(1)` → `std::process::exit(1)`. Python exceptions → `anyhow::Error` or custom typed errors.

---

## 6. Risks & Ambiguities

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | `boto3.Session.client` mock pattern in Python tests is hard to replicate exactly | Use `mockall` trait mocking with a thin `S3Client` trait; unit tests verify the same observable outcomes |
| 2 | `IfNoneMatch` on `PutObject` requires S3 server-side support (and newer SDK) | Use `aws-sdk-s3` 1.x which surfaces the `if_none_match` builder method |
| 3 | Python's `subprocess.run` captures exit codes; Rust `Command` does too — but `check=True` equivalent needs manual check | Mirror with `status().success()` checks + `GitError` |
| 4 | `s3.resource("s3")` (LFS) vs `s3.client("s3")` (remote) — both map to `aws_sdk_s3::Client` | Use same SDK client for both |
| 5 | `manage.py` uses interactive stdin (`input()`) — must be reproduced in Rust with `std::io::stdin().read_line()` | Direct translation; no third-party crate needed |
| 6 | Test infrastructure: Python `mock.patch` — Rust has no runtime monkey-patching | Define a `S3ClientTrait` and inject it; tests pass a mock implementation |
| 7 | Progress callback in LFS (`ProgressPercentage`) is a closure with shared mutable state | `Arc<Mutex<u64>>` for the counter |

---

## 7. Implementation Order (Phase 2)

1. `rust/Cargo.toml` — manifest with all dependencies
2. `rust/src/enums.rs` — `UriScheme` (no deps)
3. `rust/src/common.rs` — `parse_git_url` (depends on `enums`)
4. `rust/src/git.rs` — subprocess helpers (no AWS deps)
5. `rust/src/remote.rs` — `S3Remote` (core logic; depends on enums, common, git)
6. `rust/src/lfs.rs` — `LFSProcess` (depends on common, git)
7. `rust/src/manage.rs` — `Doctor` + `ManageBranch` (depends on remote, common, git)
8. `rust/src/lib.rs` — re-exports
9. `rust/src/bin/git_remote_s3.rs` — entry-point
10. `rust/src/bin/git_lfs_s3.rs` — entry-point
11. `rust/src/bin/git_s3.rs` — entry-point
12. `rust/tests/parse_url_test.rs` — URL parsing tests
13. `rust/tests/remote_test.rs` — S3Remote tests
14. `rust/tests/parallel_fetch_test.rs` — parallel fetch tests
