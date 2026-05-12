# Translation Plan: git-remote-s3 → Swift

## 1. Source Language & Frameworks

| Item | Detail |
|---|---|
| **Language** | Python 3.10+ |
| **Package manager** | Poetry (`pyproject.toml`) |
| **Key runtime deps** | `boto3` / `botocore` (AWS SDK), `urllib3` |
| **Entry-points** | `git-remote-s3`, `git-remote-s3+zip`, `git-lfs-s3`, `git-s3` – four CLI binaries |
| **Test framework** | `pytest` + `mock` |
| **Concurrency** | `threading.Lock`, `concurrent.futures.ThreadPoolExecutor` |

---

## 2. Target Language & Tooling

| Item | Detail |
|---|---|
| **Language** | Swift 5.9+ |
| **Package manager** | Swift Package Manager (`Package.swift`) |
| **AWS SDK** | [aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift) (`AWSS3` module) |
| **Argument parsing** | [swift-argument-parser](https://github.com/apple/swift-argument-parser) |
| **Testing** | XCTest (built-in) |
| **Concurrency** | Swift `async`/`await` + `NSLock` / `DispatchQueue` for thread-safety |

---

## 3. Repository Layout → Swift Target Layout

```
Sources/
  GitRemoteS3/           ← library target (shared logic)
    Enums.swift          ← enums.py
    Common.swift         ← common.py
    GitHelpers.swift     ← git.py
    S3Remote.swift       ← remote.py  (S3Remote class)
    LFSProcess.swift     ← lfs.py     (LFSProcess class + helpers)
    Doctor.swift         ← manage.py  (Doctor + ManageBranch classes)
  GitRemoteS3CLI/        ← `git-remote-s3` / `git-remote-s3+zip` entry-point
    main.swift
  GitLFSS3CLI/           ← `git-lfs-s3` entry-point
    main.swift
  GitS3CLI/              ← `git-s3` entry-point
    main.swift
Tests/
  GitRemoteS3Tests/
    ParseURLTests.swift  ← parse_url_test.py
    RemoteTests.swift    ← remote_test.py  (unit tests)
    ParallelFetchTests.swift ← parallel_fetch_test.py
Package.swift
```

---

## 4. File-by-File Mapping

| Source path | Target path | Notes |
|---|---|---|
| `git_remote_s3/enums.py` | `Sources/GitRemoteS3/Enums.swift` | Python `Enum` → Swift `enum` with `String` raw value |
| `git_remote_s3/common.py` | `Sources/GitRemoteS3/Common.swift` | `parse_git_url` using `NSRegularExpression`; returns a named tuple modelled as a Swift struct/tuple |
| `git_remote_s3/git.py` | `Sources/GitRemoteS3/GitHelpers.swift` | `subprocess.run` → `Process` (Foundation); exceptions → `GitError` (`enum Error`) |
| `git_remote_s3/lfs.py` | `Sources/GitRemoteS3/LFSProcess.swift` + `Sources/GitLFSS3CLI/main.swift` | `threading.Lock` → `NSLock`; `sys.stdin.readline` → `readLine()`; `boto3.Session.resource("s3").Bucket(…)` → AWSS3 client calls |
| `git_remote_s3/remote.py` | `Sources/GitRemoteS3/S3Remote.swift` + `Sources/GitRemoteS3CLI/main.swift` | `concurrent.futures.ThreadPoolExecutor` → `DispatchQueue.concurrentPerform` / `DispatchGroup`; `TransferConfig` multipart → AWSS3 multipart upload/download |
| `git_remote_s3/manage.py` | `Sources/GitRemoteS3/Doctor.swift` + `Sources/GitS3CLI/main.swift` | `argparse` → `ArgumentParser` (swift-argument-parser); `input()` → `readLine()` |
| `git_remote_s3/__init__.py` | (no direct equivalent – public API re-exported from each Swift module file) | |
| `pyproject.toml` | `Package.swift` | Dependencies declared via SPM |
| `test/parse_url_test.py` | `Tests/GitRemoteS3Tests/ParseURLTests.swift` | pytest assertions → XCTest `XCTAssert*` |
| `test/remote_test.py` | `Tests/GitRemoteS3Tests/RemoteTests.swift` | `mock.patch` → protocol-based injection / manual stubs |
| `test/parallel_fetch_test.py` | `Tests/GitRemoteS3Tests/ParallelFetchTests.swift` | Same approach as RemoteTests |

---

## 5. Dependency / Library Substitutions

| Python | Swift |
|---|---|
| `boto3` / `botocore` | `aws-sdk-swift` (`AWSS3`, `AWSClientRuntime`) |
| `boto3.Session(profile_name=…)` | `ProfileAWSCredentialIdentityResolver` via `aws-sdk-swift` |
| `subprocess.run(["git", …])` | `Foundation.Process` |
| `concurrent.futures.ThreadPoolExecutor` | `DispatchQueue.global(qos:).async` + `DispatchGroup` |
| `threading.Lock` | `NSLock` |
| `argparse.ArgumentParser` | `swift-argument-parser` (`ArgumentParser` protocol) |
| `json.dumps` / `json.loads` | `JSONSerialization` / `Codable` structs |
| `re.match` | `NSRegularExpression` |
| `tempfile.mkdtemp` | `FileManager.default.temporaryDirectory` |
| `os.path.exists`, `os.remove` | `FileManager.default` |
| `logging` | `os.log` (Unified Logging) or simple `stderr` writes |
| `sys.stdout.write` / `sys.stdin.readline` | `print()` / `readLine()` (Foundation) |
| `datetime.datetime.now(tz=…)` | `Date()` + `Calendar` / `TimeInterval` |

---

## 6. Key Translation Decisions

### 6.1 Async vs Sync
The original code uses blocking I/O (stdin loop, blocking S3 calls).  
Swift entry-points will use synchronous Foundation `Process` for git sub-commands and the `aws-sdk-swift` **sync** wrappers (`try await` run from a top-level `@main` actor, or wrapped with `DispatchSemaphore` for synchronous bridging in the CLI).  
The library itself will expose `async` methods, and the CLIs will call them from `Task { … }.wait()` style entry-points.

### 6.2 Error handling
Python exceptions → Swift `throw`-able `Error` enums. Each module has its own `enum XxxError: Error`.

### 6.3 Mocking in Tests
Python `mock.patch` is not available in Swift. Tests will use **protocol-based dependency injection**:
- A `S3ClientProtocol` with the subset of methods used (`listObjectsV2`, `getObject`, `putObject`, `deleteObject`, `headObject`, `downloadFile`, `uploadFile`).
- Real `S3Remote` takes any `S3ClientProtocol`; tests pass a `MockS3Client` struct.
- Similarly `GitProtocol` for git subprocess calls.

### 6.4 ProgressPercentage
The LFS progress callback (`Callback=ProgressPercentage(oid)`) is modelled as a Swift closure passed to the AWSS3 multipart transfer.

### 6.5 Lock / Conditional Write
`IfNoneMatch: "*"` for S3 conditional put is supported by `aws-sdk-swift` via the `PutObjectInput.ifNoneMatch` field.

---

## 7. Risks & Ambiguities

| # | Risk | Mitigation |
|---|---|---|
| R1 | `aws-sdk-swift` is async-only; synchronous bridging is needed for the interactive stdin-loop CLIs | Use `RunLoop.main` + `DispatchSemaphore` or Swift Concurrency `Task` at top level |
| R2 | `s3.resource("s3").Bucket(…).upload_file(…, Callback=…)` progress API differs from AWSS3 SDK | Map to AWSS3 multipart upload with a `ByteStream` and `onProgress` closure |
| R3 | `boto3.Session(profile_name=…)` → `aws-sdk-swift` profile resolver requires the `~/.aws/credentials` `ProfileAWSCredentialIdentityResolver` | Implement via `DefaultAWSCredentialIdentityResolverChain` or explicit profile config |
| R4 | Python `argparse` nargs and positional/optional argument mixing in `manage.py` | `swift-argument-parser` handles this cleanly; re-check that optional `branch` arg (used as positional) translates correctly |
| R5 | Test isolation: tests patch `boto3.Session.client` globally | Swift mock protocol injected at construction; some behavioral parity differences may exist |
| R6 | `git archive --format zip` is called as a subprocess; on non-macOS this may not produce identical output | Behaviour preserved; documented in comments |
| R7 | `concurrent.futures.wait` semantics (all-completed) | `DispatchGroup.wait()` provides equivalent semantics |

---

## 8. Implementation Order (Phase 2)

1. `Package.swift` — project skeleton with all targets and dependencies
2. `Sources/GitRemoteS3/Enums.swift`
3. `Sources/GitRemoteS3/Common.swift`
4. `Sources/GitRemoteS3/GitHelpers.swift`
5. `Sources/GitRemoteS3/S3Remote.swift`
6. `Sources/GitRemoteS3/LFSProcess.swift`
7. `Sources/GitRemoteS3/Doctor.swift`
8. `Sources/GitRemoteS3CLI/main.swift`
9. `Sources/GitLFSS3CLI/main.swift`
10. `Sources/GitS3CLI/main.swift`
11. `Tests/GitRemoteS3Tests/ParseURLTests.swift`
12. `Tests/GitRemoteS3Tests/RemoteTests.swift`
13. `Tests/GitRemoteS3Tests/ParallelFetchTests.swift`
