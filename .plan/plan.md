# Translation Plan: git-remote-s3 → Clojure

## 1. Source Language(s) & Frameworks

| Item | Detail |
|------|--------|
| Language | Python 3.10+ |
| Package manager | Poetry (`pyproject.toml`) |
| Runtime dependencies | `boto3 ≥ 1.42`, `botocore ≥ 1.42`, `urllib3 ≥ 2.6` |
| Dev / test | `pytest`, `mock`, `coverage`, `flake8`, `mypy`, `black` |
| Entry points | `git-remote-s3` / `git-remote-s3+zip` → `remote:main`, `git-lfs-s3` → `lfs:main`, `git-s3` → `manage:main` |
| Concurrency model | `threading.Lock` + `concurrent.futures.ThreadPoolExecutor` |
| I/O model | Reads git-remote-helper protocol lines from `stdin`; replies on `stdout`; diagnostic output on `stderr` |

---

## 2. Target Language & Tooling

| Item | Detail |
|------|--------|
| Language | Clojure 1.11 (JVM) |
| Build tool | Leiningen (`project.clj`) |
| AWS SDK | [`com.amazonaws/aws-java-sdk-s3`](https://mvnrepository.com/artifact/com.amazonaws/aws-java-sdk-s3) 1.12.x **or** AWS SDK for Java v2 `software.amazon.awssdk/s3` 2.x — plan uses AWS SDK v2 for parity with boto3 feature set (multipart, conditional puts) |
| HTTP / URL | `clojure.java.shell` for subprocess calls; `java.util.regex` for regex |
| Concurrency | `clojure.core/future`, `java.util.concurrent.locks.ReentrantLock`, `atom` |
| CLI arg parsing | `clojure.tools.cli` |
| Test framework | `clojure.test` (built-in) |
| JSON | `cheshire` (replaces Python's `json` module) |
| Logging | `clojure.tools.logging` + `log4j2` backend |
| Temp files | `java.io.File/createTempFile`, `java.nio.file.Files` |

---

## 3. File-by-File Mapping

### Production code

| Source path | Target path | Notes |
|---|---|---|
| `pyproject.toml` | `clojure/project.clj` | Leiningen project file. Declares all deps + three `uberjar` profiles producing the three executables. |
| `git_remote_s3/__init__.py` | *(namespace is implicit in Clojure; nothing to generate)* | Public vars are simply `require`d from other namespaces. |
| `git_remote_s3/enums.py` | `clojure/src/git_remote_s3/enums.clj` | Two-value enum → Clojure keyword constants + a set for validation. |
| `git_remote_s3/common.py` | `clojure/src/git_remote_s3/common.clj` | `parse-git-url` regex function returning a 4-tuple map `{:uri-scheme :profile :bucket :prefix}`. Returns `nil` values on bad input. |
| `git_remote_s3/git.py` | `clojure/src/git_remote_s3/git.clj` | All six subprocess-wrapping functions (`archive`, `bundle`, `unbundle`, `rev-parse`, `is-ancestor`, `get-remote-url`, `validate-ref-name`, `get-last-commit-message`). Uses `clojure.java.shell/sh` or `ProcessBuilder`. |
| `git_remote_s3/lfs.py` | `clojure/src/git_remote_s3/lfs.clj` | `LFSProcess` → defrecord + protocol; `ProgressPercentage` callback → fn closed over an atom; `install`, `main` functions. Reads JSON from stdin in a loop. |
| `git_remote_s3/remote.py` | `clojure/src/git_remote_s3/remote.clj` | `S3Remote` → defrecord + helper fns; all `cmd_*` methods → functions taking the record; `main` entry point. Parallel fetch with `future`/`pmap`; lock/unlock via S3 conditional `put-object`. |
| `git_remote_s3/manage.py` | `clojure/src/git_remote_s3/manage.clj` | `Doctor`, `ManageBranch` → defrecords + functions; `main` with `tools.cli` argument parsing. |

### Tests

| Source path | Target path | Notes |
|---|---|---|
| `test/parse_url_test.py` | `clojure/test/git_remote_s3/common_test.clj` | Direct translation of all 18 `test_parse_url_*` cases using `clojure.test/deftest` + `is`. |
| `test/parallel_fetch_test.py` | `clojure/test/git_remote_s3/parallel_fetch_test.clj` | Parallel-fetch tests; mocking via `with-redefs` (replaces `mock.patch`). |
| `test/remote_test.py` | `clojure/test/git_remote_s3/remote_test.clj` | Full remote push/fetch/list/lock test suite; heavy mocking via `with-redefs`. |

### CI / project metadata

| Source path | Target path | Notes |
|---|---|---|
| `.github/workflows/python-pytest.yml` | `clojure/.github/workflows/clojure-test.yml` | Replaces Poetry/pytest steps with `lein test` + `lein uberjar`. |
| `README.md`, `LICENSE`, `NOTICE`, etc. | Kept unchanged at repo root | No translation needed. |

---

## 4. Dependency / Library Substitutions

| Python | Clojure / Java |
|--------|----------------|
| `boto3` / `botocore` (S3 client) | `software.amazon.awssdk/s3` 2.x (AWS SDK v2 for Java); `software.amazon.awssdk/auth` |
| `boto3.Session(profile_name=…)` | `ProfileCredentialsProvider` / `DefaultCredentialsProvider` from AWS SDK v2 |
| `TransferConfig` multipart download | `S3TransferManager` (SDK v2 transfer manager) |
| `concurrent.futures.ThreadPoolExecutor` | `clojure.core/future` + `deref`, or `java.util.concurrent.ExecutorService` |
| `threading.Lock` | `java.util.concurrent.locks.ReentrantLock` wrapped in a Clojure atom, or `locking` macro |
| `subprocess.run` | `clojure.java.shell/sh` (simple cases) or `ProcessBuilder` for cases that pipe to `sys.stderr` |
| `argparse` | `clojure.tools.cli` |
| `json` | `cheshire.core` (encode/decode) |
| `logging` | `clojure.tools.logging` + SLF4J/Log4j2 |
| `re` (regex) | `clojure.core/re-find`, `re-matches`, `re-pattern` |
| `tempfile.mkdtemp` | `java.io.File/createTempFile` + `.getParent`; `Files/createTempDirectory` |
| `uuid.uuid4()` | `java.util.UUID/randomUUID` |
| `datetime.datetime.now()` | `java.time.Instant/now`, `java.time.ZonedDateTime` |
| `sys.stdin/stdout/stderr` | `*in*` / `*out*` / `*err*`, `System/out`, `System/err` |
| `pytest` + `mock` | `clojure.test` + `with-redefs` |

---

## 5. Architecture Notes & Translation Decisions

### 5.1 OO → Functional
Python classes (`S3Remote`, `LFSProcess`, `Doctor`, `ManageBranch`) become Clojure **records** (`defrecord`) whose "methods" are standalone functions that accept the record as their first argument. State that mutates (e.g. `fetched_refs`, `mode`, `push_cmds`, `fetch_cmds`) is held in **atoms** inside the record.

### 5.2 Enums
`UriScheme.S3` / `UriScheme.S3_ZIP` → Clojure keywords `:s3` and `:s3+zip`, exposed as `def` constants `uri-scheme-s3` and `uri-scheme-s3-zip`.

### 5.3 Git protocol I/O
The remote helper reads one line at a time from `stdin` and writes to `stdout`. In Clojure this is implemented as a `(loop [] (when-let [line (read-line)] …(recur)))` at the end of `main`. Stdout is `*out*` (wrapped in a `PrintWriter`/`flush` for correctness).

### 5.4 Parallel fetch
`concurrent.futures.ThreadPoolExecutor` → `mapv deref (map #(future (cmd-fetch s3r %)) cmds)`. The `fetched-refs` atom is updated under a `locking` call to give the same semantics as `threading.Lock`.

### 5.5 S3 conditional put (locking)
AWS SDK v2 `PutObjectRequest` supports `ifNoneMatch("*")` which mirrors Python's `IfNoneMatch="*"`. The 412 response maps to `S3Exception` with HTTP status 412.

### 5.6 Entry points
Leiningen `uberjar` produces fat JARs. Each entrypoint namespace exposes a `-main` function. Three separate Leiningen profiles (`remote`, `lfs`, `manage`) each produce a standalone JAR callable as  
`java -jar git-remote-s3.jar …`  
A thin shell-script wrapper (installed as `git-remote-s3`, `git-lfs-s3`, `git-s3`) delegates to the appropriate JAR, preserving the exact command names expected by git.

### 5.7 Exit codes
`sys.exit(N)` → `(System/exit N)`.

### 5.8 Logging initialisation guard
Python guards `if "remote" in __name__` → Clojure uses a top-level `(when (= *ns* 'git-remote-s3.remote) …)` or simply initialises logging unconditionally in `main`.

---

## 6. Risks & Manual-Review Items

| # | Risk | Severity | Notes |
|---|------|----------|-------|
| 1 | **AWS SDK v2 API surface** — the Python code uses `boto3` resource/client mix (e.g. `s3.Bucket().upload_file` in LFS but `s3.client()` in remote). The Java SDK v2 client-only model is used uniformly. The S3 Transfer Manager replaces `upload_file`/`download_file` with progress callbacks. | Medium | Functional parity maintained; callback signature differs slightly. |
| 2 | **Subprocess `stdout=sys.stderr`** — `git bundle unbundle` in Python routes subprocess stdout to `sys.stderr`. In Clojure/Java we use `ProcessBuilder.redirectOutput(ProcessBuilder.Redirect.INHERIT)` after redirecting stderr so git's output goes to the JVM's `System.err`. | Low | Behaviorally identical. |
| 3 | **Interactive prompts in `Doctor` / `ManageBranch`** — `input(…)` → `(read-line)` from `*in*`. Works when running in a terminal. | Low | Same behavior. |
| 4 | **`os.path.exists` / file cleanup** — cleanup of temp bundle files in `finally` blocks → Java `Files.delete` / `File.delete`. | Low | Equivalent. |
| 5 | **`removeprefix` (Python 3.9+)** — used in `list_refs`. In Clojure: `(subs s (count prefix))` guarded by `str/starts-with?`. | Low | Direct replacement. |
| 6 | **`BrokenPipeError` / `OSError errno 22`** — JVM does not surface these as distinct exception types in the same way. We catch `java.io.IOException` with a message check for "Broken pipe" and redirect stdout to `/dev/null`. | Medium | Behavior preserved; exact exception class differs. |
| 7 | **Thread-safety of `fetched_refs`** — Python uses `threading.Lock`; Clojure translation uses an `atom` with `swap!` (compare-and-swap semantics are equivalent). | Low | Equivalent. |
| 8 | **Classpath isolation** — three entry points share the same Clojure JAR namespace; they must not conflict. Solved by keeping three separate `-main` fns in three namespaces. | Low | Standard Clojure pattern. |
| 9 | **`IfNoneMatch` conditional put availability** — only supported on buckets with S3 versioning OR on buckets generally (GA'd in 2024). The Clojure SDK v2 exposes this natively. | Low | Same constraint as Python side. |
| 10 | **LFS progress callback** — `ProgressPercentage.__call__` maps progress bytes. AWS SDK v2 `AsyncResponseTransformer` / `ProgressListener` API used in Clojure. Behavior identical. | Medium | API shape different but semantics identical. |

---

## 7. Implementation Order

1. `clojure/project.clj` — Leiningen project with all dependencies.
2. `clojure/src/git_remote_s3/enums.clj` — keyword constants (no deps).
3. `clojure/src/git_remote_s3/common.clj` — `parse-git-url` (depends on enums).
4. `clojure/src/git_remote_s3/git.clj` — subprocess wrappers (no internal deps).
5. `clojure/src/git_remote_s3/remote.clj` — `S3Remote` record + `main` (depends on enums, common, git).
6. `clojure/src/git_remote_s3/lfs.clj` — `LFSProcess` + `main` (depends on common, git).
7. `clojure/src/git_remote_s3/manage.clj` — `Doctor`, `ManageBranch` + `main` (depends on common, remote for `DEFAULT_LOCK_TTL_SECONDS`).
8. `clojure/resources/log4j2.xml` — logging configuration.
9. `clojure/bin/git-remote-s3` — shell wrapper.
10. `clojure/bin/git-lfs-s3` — shell wrapper.
11. `clojure/bin/git-s3` — shell wrapper.
12. `clojure/test/git_remote_s3/common_test.clj` — parse-url tests.
13. `clojure/test/git_remote_s3/remote_test.clj` — remote push/fetch/list/lock tests.
14. `clojure/test/git_remote_s3/parallel_fetch_test.clj` — parallel fetch tests.
15. `clojure/.github/workflows/clojure-test.yml` — CI workflow.
