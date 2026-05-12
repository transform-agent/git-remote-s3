# git-remote-s3 (Elixir port)

This directory contains an **Elixir** translation of the
[`git-remote-s3`](https://github.com/awslabs/git-remote-s3) Python library.

It provides the same three executables as the original:

| Executable | Description |
|---|---|
| `git-remote-s3` | Git remote helper for `s3://` and `s3+zip://` remotes |
| `git-lfs-s3` | Git LFS custom transfer agent backed by S3 |
| `git-s3` | Management CLI (`doctor`, `delete-branch`, `protect`, `unprotect`) |

---

## Requirements

* Elixir ≥ 1.15 / OTP ≥ 26
* Erlang/OTP on PATH at runtime (needed to run escripts)
* AWS credentials (environment variables, `~/.aws/credentials`, or instance profile)

---

## Installation

```bash
cd elixir
mix deps.get
mix escript.build         # builds git-remote-s3 escript
```

Because `mix escript.build` only produces a single named escript, build the
other two entry points by temporarily changing the `:name` key in `mix.exs`:

```bash
# build git-lfs-s3
MIX_ENV=prod mix run --no-halt -e \
  "Mix.Tasks.Escript.Build.run([])"
```

Or add a Mix alias in `mix.exs` for each escript (see the Mix documentation for
multi-escript projects).

---

## Usage

### S3 remote

```bash
# Add a remote
git remote add origin s3://my-bucket/my-repo

# With an AWS profile
git remote add origin s3://my-profile@my-bucket/my-repo

# Push / pull
git push origin main
git pull origin main
```

### LFS transfer agent

```bash
git-lfs-s3 install    # configure git-lfs to use the S3 agent
git lfs push          # push LFS objects to S3
```

### Management CLI

```bash
git-s3 doctor     origin
git-s3 protect    origin main
git-s3 unprotect  origin main
git-s3 delete-branch origin feature/old
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GIT_REMOTE_S3_VERBOSE` | `""` | Set to `1`, `true`, or `yes` to enable `INFO` logging |
| `GIT_REMOTE_S3_LOCK_TTL_SECONDS` | `60` | Seconds after which a push lock is considered stale |

---

## Running tests

```bash
cd elixir
mix test
```

---

## Key differences from the Python implementation

| Python | Elixir |
|---|---|
| `boto3` / `botocore` | `ex_aws` + `ex_aws_s3` |
| `threading.Lock` | `Agent` (wraps fetched-refs list) |
| `concurrent.futures.ThreadPoolExecutor` | `Task.async_stream/3` |
| `logging` | Elixir `Logger` |
| `argparse` | stdlib `OptionParser` |
| `json` | `Jason` |
| `subprocess.run` | `System.cmd/3` |
| `pytest` + `mock` | `ExUnit` + `Mox` |
| Class with mutable state (`S3Remote`) | Immutable struct threaded through recursive loop |

### AWS Profile support

The Python SDK natively loads `~/.aws/credentials` profile sections.
The Elixir implementation provides `GitRemoteS3.AwsProfile` which reads the
same INI file format and passes the resulting credentials to `ExAws`.

### Conditional S3 writes (lock acquisition)

The `IfNoneMatch: "*"` header is passed via ExAws S3 `put_object` options.
Note: not all S3-compatible endpoints support conditional writes — check your
provider's documentation.

---

## License

Apache-2.0 — same as the original project.
