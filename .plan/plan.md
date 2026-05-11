# Translation Plan: git-remote-s3 Python → Haskell

## 1. Source Language & Framework

| Attribute | Detail |
|-----------|--------|
| Source language | Python 3.10+ |
| Package manager | Poetry (`pyproject.toml`) |
| Runtime dependencies | `boto3 / botocore` (AWS SDK), `urllib3` |
| Dev dependencies | `pytest`, `mock`, `flake8`, `black`, `mypy`, `coverage` |
| Entry points (executables) | `git-remote-s3`, `git-remote-s3+zip`, `git-lfs-s3`, `git-s3` |
| Key patterns | subprocess calls to `git`, stdin/stdout-based protocol, S3 API via AWS SDK, threading, regex URL parsing |

---

## 2. Target Language & Toolchain

| Attribute | Detail |
|-----------|--------|
| Target language | Haskell (GHC 9.4+) |
| Build system | Cabal (`git-remote-s3.cabal` + optional `cabal.project`) |
| AWS SDK | `amazonka-s3` (≥ 2.0) + `amazonka` core |
| Regex | `regex-tdfa` |
| JSON | `aeson` |
| CLI arg parsing | `optparse-applicative` |
| Concurrency | `async` (parallel fetch) + `MVar` (thread-safe ref list) |
| Temporary files | `temporary` |
| Logging | `fast-logger` / `System.IO` (stderr) |
| Subprocess | `process` (standard) |
| File I/O | `bytestring`, `text` |
| Time | `time` |
| UUID | `uuid` |
| Tests | `HUnit` + `hspec` (mirrors pytest structure) |

---

## 3. File-by-File Mapping

### Source → Target

| Source path | Target path | Notes |
|-------------|-------------|-------|
| `pyproject.toml` | `git-remote-s3.cabal` | Cabal project file replacing Poetry. Declares 4 executable targets and 1 library. |
| `git_remote_s3/__init__.py` | `src/GitRemoteS3.hs` | Re-export module; Haskell module just re-exports the public API. |
| `git_remote_s3/enums.py` | `src/GitRemoteS3/Enums.hs` | `UriScheme` becomes an ADT `data UriScheme = S3 \| S3Zip`. |
| `git_remote_s3/common.py` | `src/GitRemoteS3/Common.hs` | `parseGitUrl` with `regex-tdfa`; returns `Maybe (UriScheme, Maybe String, String, Maybe String)`. |
| `git_remote_s3/git.py` | `src/GitRemoteS3/Git.hs` | All subprocess wrappers (`archive`, `bundle`, `unbundle`, `revParse`, `isAncestor`, `getRemoteUrl`, `validateRefName`, `getLastCommitMessage`). Uses `System.Process`. |
| `git_remote_s3/lfs.py` | `src/GitRemoteS3/Lfs.hs` + `app/GitLfsS3Main.hs` | LFS custom-transfer agent: reads JSON events from stdin, uploads/downloads via `amazonka-s3`. `main` lives in `app/`. |
| `git_remote_s3/manage.py` | `src/GitRemoteS3/Manage.hs` + `app/GitS3Main.hs` | `Doctor` and `ManageBranch` classes become record types with functions. `main` with `optparse-applicative` lives in `app/`. |
| `git_remote_s3/remote.py` | `src/GitRemoteS3/Remote.hs` + `app/GitRemoteS3Main.hs` | `S3Remote` becomes a record. `processCmd` main loop. `main` lives in `app/`. |
| `test/parse_url_test.py` | `test/ParseUrlSpec.hs` | HSpec tests mirroring all `test_parse_url_*` cases. |
| `test/remote_test.py` | `test/RemoteSpec.hs` | HSpec tests for push/fetch/list/options/capabilities using mocking stubs (IORef-based fakes). |
| `test/parallel_fetch_test.py` | `test/ParallelFetchSpec.hs` | HSpec tests for parallel fetch, thread safety, batch processing. |
| *(new)* | `cabal.project` | Top-level cabal project file (optional, for multi-package layout). |
| *(new)* | `NOTICE` / `LICENSE` | Kept as-is (not modified). |

---

## 4. Module Architecture

```
git-remote-s3 (Haskell)
├── src/
│   ├── GitRemoteS3.hs                  ← public API re-exports
│   ├── GitRemoteS3/
│   │   ├── Enums.hs                    ← UriScheme ADT
│   │   ├── Common.hs                   ← parseGitUrl
│   │   ├── Git.hs                      ← subprocess wrappers
│   │   ├── Lfs.hs                      ← LFS transfer agent logic
│   │   ├── Manage.hs                   ← Doctor + ManageBranch
│   │   └── Remote.hs                   ← S3Remote + protocol loop
├── app/
│   ├── GitRemoteS3Main.hs              ← git-remote-s3 / git-remote-s3+zip binary
│   ├── GitLfsS3Main.hs                 ← git-lfs-s3 binary
│   └── GitS3Main.hs                    ← git-s3 binary
└── test/
    ├── ParseUrlSpec.hs
    ├── RemoteSpec.hs
    ├── ParallelFetchSpec.hs
    └── Spec.hs                         ← hspec runner discovery
```

---

## 5. Key Translation Decisions

### 5.1 `UriScheme` (Enums.hs)
```haskell
data UriScheme = S3 | S3Zip deriving (Eq, Show)
```

### 5.2 `parseGitUrl` (Common.hs)
- Uses `Text.Regex.TDFA` to match `(s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?`
- Returns `Maybe (UriScheme, Maybe String, String, Maybe String)` (scheme, profile, bucket, prefix) instead of a 4-tuple with `None` sentinels.
- Strips trailing `/` from prefix and strips `@` from profile.

### 5.3 `S3Remote` (Remote.hs)
- The Python class becomes a Haskell record:
```haskell
data S3Remote = S3Remote
  { uriScheme      :: UriScheme
  , profile        :: Maybe Text
  , bucket         :: Text
  , prefix         :: Text
  , s3Client       :: Amazonka.Env      -- amazonka Env
  , fetchedRefs    :: MVar [Text]
  , pushCmds       :: IORef [Text]
  , fetchCmds      :: IORef [Text]
  , mode           :: IORef (Maybe Mode)
  , lockTtlSeconds :: Int
  }
```
- `processCmd` is an `IO ()` function reading from `S3Remote` state.
- Push/fetch modes collected in `IORef` lists, flushed on empty line.
- Parallel fetch via `Control.Concurrent.Async.mapConcurrently`.

### 5.4 `LFSProcess` (Lfs.hs)
- Becomes a Haskell record with `bucket`, `prefix`, `profile` fields + an `IORef` for the lazily-initialized S3 session.
- `ProgressPercentage` callback becomes a closure over an `IORef Int64` + `MVar ()`.
- Event loop reads JSON lines from stdin with `Data.Aeson`.

### 5.5 `Doctor` / `ManageBranch` (Manage.hs)
- Both classes become records with pure functions and IO actions.
- Interactive `input()` calls → `hFlush stdout >> getLine`.
- `datetime.datetime.now()` → `Data.Time.getCurrentTime`.

### 5.6 Subprocess wrappers (Git.hs)
- `subprocess.run` → `System.Process.readProcessWithExitCode` / `createProcess`.
- `sys.stderr` redirect for unbundle → `CreateProcess { std_out = UseHandle stderr }`.
- Custom exception type:
```haskell
newtype GitError = GitError String deriving (Show)
instance Exception GitError
```

### 5.7 AWS SDK (amazonka-s3)
- `boto3.Session(profile_name=...).client("s3")` → `Amazonka.newEnv` with optional `AWS_PROFILE` / credential provider.
- `s3.list_objects_v2` → `Amazonka.send env (S3.newListObjectsV2 bucket)`
- `s3.put_object` with `IfNoneMatch="*"` → custom header via `Amazonka.Core.Header`.
- `s3.download_file` with `TransferConfig` (multipart) → `Amazonka.S3.getObject` + streaming to file.
- Botocore exceptions map to `SomeException` caught with `try`.

### 5.8 Logging
- `logging.basicConfig` → `System.IO` writes to `stderr`; controlled by `IORef LogLevel`.
- `GIT_REMOTE_S3_VERBOSE` env var → `System.Environment.lookupEnv`.

### 5.9 Entry Points (Cabal executables)
Four Cabal `executable` stanzas:
- `git-remote-s3` → `app/GitRemoteS3Main.hs`
- `git-remote-s3-zip` (renamed from `git-remote-s3+zip` which is invalid as a Cabal name; the installed binary is renamed via a wrapper script note)
- `git-lfs-s3` → `app/GitLfsS3Main.hs`
- `git-s3` → `app/GitS3Main.hs`

---

## 6. Dependency Substitutions

| Python | Haskell |
|--------|---------|
| `boto3` / `botocore` | `amazonka` + `amazonka-s3` (≥ 2.0) |
| `re` (regex) | `regex-tdfa` |
| `json` | `aeson` |
| `argparse` | `optparse-applicative` |
| `threading.Lock` | `Control.Concurrent.MVar` |
| `concurrent.futures.ThreadPoolExecutor` | `Control.Concurrent.Async` (`mapConcurrently`) |
| `tempfile` | `System.IO.Temp` (`temporary` package) |
| `datetime` | `Data.Time` |
| `uuid` | `Data.UUID` + `Data.UUID.V4` (`uuid` package) |
| `sys.stdout` / `sys.stderr` | `System.IO` (`hPutStr`, `hFlush`) |
| `os.environ` | `System.Environment` |
| `subprocess` | `System.Process` |
| `pytest` + `mock` | `hspec` + `HUnit` + `IORef`-based stubs |

---

## 7. Risks, Ambiguities & Manual-Review Items

| # | Risk / Ambiguity | Mitigation |
|---|-----------------|------------|
| R1 | `amazonka-s3` v2 API differs significantly from boto3; `IfNoneMatch="*"` conditional put may need a custom request modifier. | Use `Amazonka.Core.overrideHeader` or `Network.HTTP.Client` directly for the conditional put header. Mark with `TODO` in code. |
| R2 | `boto3.s3.transfer.TransferConfig` multipart download has no direct amazonka equivalent without manual chunked-range download. | Use `amazonka-s3` streaming `getObject` + write to file handle; multipart is handled by S3 transparently on download. Note as simplification. |
| R3 | `git-remote-s3+zip` is not a valid Cabal executable name (the `+` is forbidden). | The Cabal executable is named `git-remote-s3-zip`; a post-install symlink or wrapper is noted in the README. |
| R4 | Python tests use `mock.patch` to replace boto3 internals; Haskell tests must use a different strategy. | Use `IORef`-based in-memory fake S3 store passed as a parameter to functions; the `S3Remote` record is given a `sendRequest` field that can be swapped in tests. |
| R5 | `ProgressPercentage.__call__` is a Python callable-object pattern. | In Haskell, use a closure `:: Int64 -> IO ()` capturing an `IORef Int64` + `MVar ()`. |
| R6 | Interactive `input()` calls in `Doctor.fix_multiple_bundles` and `fix_head` may hang in non-TTY contexts. | Preserved as `hFlush stdout >> getLine`; document that doctor commands require a TTY. |
| R7 | `os.dup2(devnull, sys.stdout.fileno())` for broken-pipe handling is Unix-specific. | Use `System.IO.Error.isDoesNotExistError` + catch `IOException` containing `EPIPE`; on Windows use a no-op. |
| R8 | `import datetime` inside a method body (in `acquire_lock`) is a Python quirk. | No issue in Haskell; `Data.Time` is imported at the module level. |
| R9 | `boto3.Session.resource("s3")` (used in LFS) vs `.client("s3")` (used elsewhere). | Both map to the same `amazonka-s3` send environment; unified in Haskell. |
| R10 | The `s3+zip` scheme string contains `+`, which Python handles fine in enum values but needs special treatment in Haskell `Show`/`Read`. | Implement custom `Show` instance: `show S3Zip = "s3+zip"`. |

---

## 8. Implementation Order (Phase 2)

1. **`git-remote-s3.cabal`** — declare library, executables, test suite, all dependencies.
2. **`src/GitRemoteS3/Enums.hs`** — `UriScheme` ADT.
3. **`src/GitRemoteS3/Common.hs`** — `parseGitUrl` with regex.
4. **`src/GitRemoteS3/Git.hs`** — subprocess wrappers, `GitError`.
5. **`src/GitRemoteS3/Remote.hs`** — `S3Remote` record, all `cmd_*` methods, `processCmd` loop.
6. **`app/GitRemoteS3Main.hs`** — `main` for `git-remote-s3` / `git-remote-s3+zip`.
7. **`src/GitRemoteS3/Lfs.hs`** — `LFSProcess`, `ProgressPercentage`, `install`, `main` logic.
8. **`app/GitLfsS3Main.hs`** — `main` for `git-lfs-s3`.
9. **`src/GitRemoteS3/Manage.hs`** — `Doctor`, `ManageBranch`.
10. **`app/GitS3Main.hs`** — `main` for `git-s3`.
11. **`src/GitRemoteS3.hs`** — top-level re-export module.
12. **`test/ParseUrlSpec.hs`** — URL parsing tests.
13. **`test/RemoteSpec.hs`** — remote push/fetch/list tests.
14. **`test/ParallelFetchSpec.hs`** — parallel fetch tests.
15. **`test/Spec.hs`** — hspec runner.
