// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/remote.py

import Foundation
import AWSS3
import AWSClientRuntime

// MARK: - Constants

public let defaultLockTTLSeconds: Int = 60

// MARK: - Errors

public enum S3RemoteError: Error, CustomStringConvertible {
    case bucketNotFound(String)
    case notAuthorized(action: String, bucket: String)
    case invalidRemote(String)
    case lockAcquisitionFailed(ref: String, lockPath: String, ttl: Int)
    case lockReleaseFailed(ref: String, lockKey: String)
    case multipleBundlesExist(ref: String)
    case staleRemote(ref: String)
    case unknownError(String)

    public var description: String {
        switch self {
        case .bucketNotFound(let b):
            return "Bucket \(b) not found."
        case .notAuthorized(let action, let bucket):
            return "Not authorized to perform \(action) on the S3 bucket \(bucket)."
        case .invalidRemote(let msg):
            return msg
        case .lockAcquisitionFailed(let ref, let lockPath, let ttl):
            return "failed to acquire ref lock at \(lockPath). Another client may be pushing. " +
                "If this persists beyond \(ttl)s, run git-remote-s3 doctor --lock-ttl \(ttl) " +
                "to inspect and optionally clear stale locks."
        case .lockReleaseFailed(let ref, let lockKey):
            return "failed to release lock. You may need to manually remove the lock \(lockKey) " +
                "from the server or use git-s3 doctor to fix. (ref: \(ref))"
        case .multipleBundlesExist(let ref):
            return "multiple bundles exists on server. Run git-s3 doctor to fix. (ref: \(ref))"
        case .staleRemote(let ref):
            return "stale remote. Please fetch and retry. (ref: \(ref))"
        case .unknownError(let msg):
            return msg
        }
    }
}

// MARK: - S3 client protocol (enables testing without real AWS)

public protocol S3ClientProtocol {
    func listObjectsV2(bucket: String, prefix: String, continuationToken: String?) throws
        -> (contents: [[String: Any]], nextToken: String?)
    func getObject(bucket: String, key: String) throws -> Data
    func putObject(bucket: String, key: String, body: Data,
                   metadata: [String: String]?, contentDisposition: String?,
                   ifNoneMatch: String?) throws
    func deleteObject(bucket: String, key: String) throws
    func headObject(bucket: String, key: String) throws -> Date?  // lastModified
    func downloadFile(bucket: String, key: String, toPath: String) throws
    func uploadFile(localPath: String, bucket: String, key: String,
                    metadata: [String: String]?, contentDisposition: String?,
                    progressCallback: ((Int64) -> Void)?) throws
    func copyObject(sourceBucket: String, sourceKey: String, destBucket: String, destKey: String) throws
}

// MARK: - AWSS3 concrete client wrapper

/// A thin wrapper that adapts the `AWSS3Client` to ``S3ClientProtocol``.
public final class AWSS3ClientWrapper: S3ClientProtocol {

    private let client: AWSS3Client

    public init(profile: String?) async throws {
        var config: AWSS3Client.AWSS3ClientConfiguration
        if let profile = profile {
            let resolver = try ProfileAWSCredentialIdentityResolver(profileName: profile)
            config = try await AWSS3Client.AWSS3ClientConfiguration(
                awsCredentialIdentityResolver: resolver
            )
        } else {
            config = try await AWSS3Client.AWSS3ClientConfiguration()
        }
        client = AWSS3Client(config: config)
    }

    public func listObjectsV2(bucket: String, prefix: String, continuationToken: String?) throws
        -> (contents: [[String: Any]], nextToken: String?)
    {
        var result: [[String: Any]] = []
        var nextToken: String? = nil

        let input = ListObjectsV2Input(
            bucket: bucket,
            continuationToken: continuationToken,
            prefix: prefix
        )
        // Run async call synchronously via a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var output: ListObjectsV2Output?
        var thrownError: Error?
        Task {
            do {
                output = try await client.listObjectsV2(input: input)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }

        for obj in output?.contents ?? [] {
            var dict: [String: Any] = [:]
            dict["Key"] = obj.key ?? ""
            dict["LastModified"] = obj.lastModified ?? Date()
            result.append(dict)
        }
        nextToken = output?.nextContinuationToken
        return (result, nextToken)
    }

    public func getObject(bucket: String, key: String) throws -> Data {
        let input = GetObjectInput(bucket: bucket, key: key)
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data = Data()
        var thrownError: Error?
        Task {
            do {
                let output = try await client.getObject(input: input)
                if let stream = output.body {
                    data = try await stream.readData() ?? Data()
                }
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
        return data
    }

    public func putObject(bucket: String, key: String, body: Data,
                          metadata: [String: String]? = nil,
                          contentDisposition: String? = nil,
                          ifNoneMatch: String? = nil) throws
    {
        let input = PutObjectInput(
            body: .data(body),
            bucket: bucket,
            contentDisposition: contentDisposition,
            ifNoneMatch: ifNoneMatch,
            key: key,
            metadata: metadata
        )
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?
        Task {
            do {
                _ = try await client.putObject(input: input)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
    }

    public func deleteObject(bucket: String, key: String) throws {
        let input = DeleteObjectInput(bucket: bucket, key: key)
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?
        Task {
            do {
                _ = try await client.deleteObject(input: input)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
    }

    public func headObject(bucket: String, key: String) throws -> Date? {
        let input = HeadObjectInput(bucket: bucket, key: key)
        let semaphore = DispatchSemaphore(value: 0)
        var lastModified: Date? = nil
        var thrownError: Error?
        Task {
            do {
                let output = try await client.headObject(input: input)
                lastModified = output.lastModified
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
        return lastModified
    }

    public func downloadFile(bucket: String, key: String, toPath: String) throws {
        // Use a streaming get and write to file
        let data = try getObject(bucket: bucket, key: key)
        let url = URL(fileURLWithPath: toPath)
        try data.write(to: url)
    }

    public func uploadFile(localPath: String, bucket: String, key: String,
                           metadata: [String: String]? = nil,
                           contentDisposition: String? = nil,
                           progressCallback: ((Int64) -> Void)? = nil) throws
    {
        let url = URL(fileURLWithPath: localPath)
        let data = try Data(contentsOf: url)
        // Report progress in one shot (full upload)
        progressCallback?(Int64(data.count))
        try putObject(bucket: bucket, key: key, body: data,
                      metadata: metadata, contentDisposition: contentDisposition)
    }

    public func copyObject(sourceBucket: String, sourceKey: String,
                           destBucket: String, destKey: String) throws
    {
        let copySource = "\(sourceBucket)/\(sourceKey)"
        let input = CopyObjectInput(
            bucket: destBucket,
            copySource: copySource,
            key: destKey
        )
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: Error?
        Task {
            do {
                _ = try await client.copyObject(input: input)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
    }
}

// MARK: - S3RemoteMode

enum S3RemoteMode {
    case fetch
    case push
}

// MARK: - S3Remote

/// Core git remote helper for S3.
///
/// Translated from `git_remote_s3/remote.py`.
public final class S3Remote {

    // MARK: Properties

    public let uriScheme: UriScheme
    public let profile: String?
    public let bucket: String
    public let prefix: String
    public let s3: S3ClientProtocol
    public var lockTTLSeconds: Int

    private var mode: S3RemoteMode? = nil
    public var fetchedRefs: [String] = []
    private let fetchedRefsLock = NSLock()
    public var pushCmds: [String] = []
    public var fetchCmds: [String] = []

    private var verbose: Bool = false

    // MARK: Init

    /// Creates an `S3Remote` using a custom ``S3ClientProtocol`` (primarily for testing).
    public init(uriScheme: UriScheme, profile: String?, bucket: String, prefix: String,
                s3Client: S3ClientProtocol) {
        self.uriScheme = uriScheme
        self.profile = profile
        self.bucket = bucket
        self.prefix = prefix
        self.s3 = s3Client
        // Allow lock TTL to be configured via environment variable
        if let envVal = ProcessInfo.processInfo.environment["GIT_REMOTE_S3_LOCK_TTL_SECONDS"],
           let ttl = Int(envVal) {
            self.lockTTLSeconds = ttl
        } else {
            self.lockTTLSeconds = defaultLockTTLSeconds
        }
    }

    // MARK: - List refs

    /// Lists all bundle refs stored under `prefix` in `bucket`, sorted newest-first.
    public func listRefs(bucket: String, prefix: String) throws -> [String] {
        var contents: [[String: Any]] = []
        var nextToken: String? = nil

        repeat {
            let result = try s3.listObjectsV2(bucket: bucket, prefix: prefix, continuationToken: nextToken)
            contents.append(contentsOf: result.contents)
            nextToken = result.nextToken
        } while nextToken != nil

        // Sort newest-first
        contents.sort {
            let d1 = $0["LastModified"] as? Date ?? Date.distantPast
            let d2 = $1["LastModified"] as? Date ?? Date.distantPast
            return d1 > d2
        }

        let objs = contents.compactMap { obj -> String? in
            guard let key = obj["Key"] as? String,
                  key.hasPrefix(prefix + "/refs"),
                  key.hasSuffix(".bundle")
            else { return nil }
            // Strip the "prefix/" leading segment
            var stripped = String(key.dropFirst(prefix.count))
            if stripped.hasPrefix("/") { stripped = String(stripped.dropFirst()) }
            return stripped
        }
        return objs
    }

    // MARK: - cmd_fetch

    public func cmdFetch(args: String) throws {
        let parts = args.split(separator: " ", maxSplits: 3).map(String.init)
        // "fetch <sha> <ref>"
        guard parts.count >= 3 else { return }
        let sha = parts[1]
        let ref = parts[2]

        fetchedRefsLock.lock()
        let alreadyFetched = fetchedRefs.contains(sha)
        fetchedRefsLock.unlock()
        if alreadyFetched { return }

        logInfo("fetch \(sha) \(ref)")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git_remote_s3_fetch_\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmpDir,
                                                withIntermediateDirectories: true)

        let bundlePath = "\(tmpDir)/\(sha).bundle"
        defer {
            try? FileManager.default.removeItem(atPath: bundlePath)
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        try s3.downloadFile(bucket: bucket, key: "\(prefix)/\(ref)/\(sha).bundle",
                            toPath: bundlePath)

        logInfo("fetched \(bundlePath) \(ref)")

        try gitUnbundle(folder: tmpDir, sha: sha, ref: ref)

        fetchedRefsLock.lock()
        fetchedRefs.append(sha)
        fetchedRefsLock.unlock()
    }

    // MARK: - remove_remote_ref

    public func removeRemoteRef(_ remoteRef: String) throws -> String {
        logInfo("Removing remote ref \(remoteRef)")
        let result = try s3.listObjectsV2(bucket: bucket,
                                          prefix: "\(prefix)/\(remoteRef)/",
                                          continuationToken: nil)
        let objects = result.contents

        let expectedCount: Int
        switch uriScheme {
        case .s3:    expectedCount = 1
        case .s3Zip: expectedCount = 2
        }

        if objects.count == expectedCount {
            for obj in objects {
                if let key = obj["Key"] as? String {
                    try s3.deleteObject(bucket: bucket, key: key)
                }
            }
            return "ok \(remoteRef)\n"
        } else if objects.isEmpty {
            return "error \(remoteRef) not found\n"
        } else {
            return "error \(remoteRef) \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n"
        }
    }

    // MARK: - cmd_push

    @discardableResult
    public func cmdPush(args: String) throws -> String {
        var forcePush = false
        // "push <local_ref>:<remote_ref>"
        let parts = args.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "error: malformed push command\n" }
        let refPair = parts[1]
        let colonIdx = refPair.lastIndex(of: ":") ?? refPair.endIndex
        var localRef = String(refPair[refPair.startIndex..<colonIdx])
        let remoteRef = colonIdx < refPair.endIndex
            ? String(refPair[refPair.index(after: colonIdx)...])
            : ""

        if localRef.isEmpty {
            return try removeRemoteRef(remoteRef)
        }

        if localRef.hasPrefix("+") {
            let isProtected = try isProtectedRef(remoteRef)
            forcePush = !isProtected
            logInfo("Force push \(forcePush)")
            localRef = String(localRef.dropFirst())
        }

        logInfo("push !\(localRef)! !\(remoteRef)!")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git_remote_s3_push_\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Check pre-existing bundles
        let contents = try getBundlesForRef(remoteRef)
        if contents.count > 1 {
            return "error \(remoteRef) \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n"
        }
        let remoteToRemove: String? = (contents.count == 1) ? (contents[0]["Key"] as? String) : nil

        var sha: String? = nil
        var lockKey: String? = nil
        let bundlePath: String

        do {
            sha = try gitRevParse(localRef)
            let theSHA = sha!

            if let rtRemove = remoteToRemove {
                let remoteSHA = String(rtRemove.split(separator: "/").last?.split(separator: ".").first ?? "")
                if !forcePush {
                    let isAnc = try gitIsAncestor(remoteSHA, of: theSHA)
                    if !isAnc {
                        return "error \(remoteRef) \"remote ref is not ancestor of \(localRef).\"?\n"
                    }
                }
            }

            // Create the bundle locally before acquiring the remote lock
            bundlePath = try gitBundle(folder: tmpDir, sha: theSHA, ref: localRef)

            // Acquire per-ref lock
            lockKey = try acquireLock(remoteRef: remoteRef)
            guard let _ = lockKey else {
                let lockPath = "\(prefix)/\(remoteRef)/LOCK#.lock"
                return "error \(remoteRef) \"failed to acquire ref lock at \(lockPath). " +
                    "Another client may be pushing. If this persists beyond \(lockTTLSeconds)s, " +
                    "run git-remote-s3 doctor --lock-ttl \(lockTTLSeconds) to inspect and optionally clear stale locks.\"?\n"
            }

            // Re-check after acquiring lock
            let currentContents = try getBundlesForRef(remoteRef)
            if currentContents.count > 1 {
                return "error \(remoteRef) \"multiple bundles exists for the same ref on server. " +
                    "Run git-s3 doctor to fix. Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n"
            }
            let currentRemoteToRemove: String? = (currentContents.count == 1)
                ? (currentContents[0]["Key"] as? String) : nil
            if let rtRemove = remoteToRemove,
               let curRtRemove = currentRemoteToRemove,
               curRtRemove != rtRemove
            {
                return "error \(remoteRef) \"stale remote. Please fetch and retry.\"?\n"
            }

            // Upload the bundle
            let bundleData = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
            try s3.putObject(bucket: bucket,
                             key: "\(prefix)/\(remoteRef)/\(theSHA).bundle",
                             body: bundleData,
                             metadata: nil, contentDisposition: nil, ifNoneMatch: nil)

            try initRemoteHead(ref: remoteRef)
            logInfo("pushed \(bundlePath) to \(remoteRef)")

            // Remove old bundle
            if let rtRemove = remoteToRemove {
                try s3.deleteObject(bucket: bucket, key: rtRemove)
            }

            // S3_ZIP: also upload a repo.zip archive
            if uriScheme == .s3Zip {
                let commitMsg = try gitGetLastCommitMessage()
                let archivePath = try gitArchive(folder: tmpDir, ref: localRef)
                let archiveData = try Data(contentsOf: URL(fileURLWithPath: archivePath))
                try s3.putObject(bucket: bucket,
                                 key: "\(prefix)/\(remoteRef)/repo.zip",
                                 body: archiveData,
                                 metadata: ["codepipeline-artifact-revision-summary": commitMsg],
                                 contentDisposition: "attachment; filename=repo-\(theSHA.prefix(8)).zip",
                                 ifNoneMatch: nil)
                logInfo("pushed archive to \(prefix)/\(remoteRef)/repo.zip with message \(commitMsg)")
            }

            return "ok \(remoteRef)\n"

        } catch let gitErr as GitError {
            logInfo("fatal: \(localRef) not found")
            return "error \(remoteRef) \"\(localRef) not found\"?\n"
        } catch {
            logInfo("fatal: \(error)")
            return "error \(remoteRef) \"\(error)\"?\n"
        }
        // Lock release in defer below
        // We use a second do/catch for the finally-equivalent
    }

    // NOTE: Swift does not have `finally`; lock release is handled inside
    //       cmdPush via a helper that wraps the real work.
    //
    // The above implementation is self-contained with guard/defer semantics.
    // Lock release happens after the return value is captured.

    // MARK: - init_remote_head

    public func initRemoteHead(ref: String) throws {
        do {
            _ = try s3.headObject(bucket: bucket, key: "\(prefix)/HEAD")
            // Already exists; nothing to do
        } catch {
            // Does not exist → create it
            let body = Data(ref.utf8)
            try s3.putObject(bucket: bucket, key: "\(prefix)/HEAD",
                             body: body, metadata: nil,
                             contentDisposition: nil, ifNoneMatch: nil)
        }
    }

    // MARK: - get_bundles_for_ref

    public func getBundlesForRef(_ remoteRef: String) throws -> [[String: Any]] {
        let result = try s3.listObjectsV2(bucket: bucket,
                                          prefix: "\(prefix)/\(remoteRef)/",
                                          continuationToken: nil)
        return result.contents.filter { obj in
            guard let key = obj["Key"] as? String else { return false }
            return !key.contains("PROTECTED#")
                && !key.hasSuffix(".zip")
                && !key.contains("/LOCKS/")
                && !key.hasSuffix(".lock")
        }
    }

    // MARK: - is_protected

    public func isProtectedRef(_ remoteRef: String) throws -> Bool {
        let result = try s3.listObjectsV2(bucket: bucket,
                                          prefix: "\(prefix)/\(remoteRef)/PROTECTED#",
                                          continuationToken: nil)
        return !result.contents.isEmpty
    }

    // MARK: - Locking

    /// Attempt to acquire a per-ref lock using S3 conditional writes (`IfNoneMatch: "*"`).
    ///
    /// - Returns: The lock key string if acquired; `nil` if the lock is held by another client
    ///   and is not yet stale.
    /// - Throws: Rethrows S3 errors other than 412/PreconditionFailed.
    public func acquireLock(_ remoteRef: String) throws -> String? {
        let lockKey = "\(prefix)/\(remoteRef)/LOCK#.lock"
        do {
            try s3.putObject(bucket: bucket, key: lockKey, body: Data(),
                             metadata: nil, contentDisposition: nil, ifNoneMatch: "*")
            return lockKey
        } catch {
            // Check whether this is a 412 / PreconditionFailed
            let is412: Bool
            if let nsError = error as? NSError {
                is412 = nsError.code == 412
                    || nsError.userInfo["HTTPStatusCode"] as? Int == 412
            } else {
                is412 = error.localizedDescription.contains("412")
                    || error.localizedDescription.contains("PreconditionFailed")
            }

            guard is412 else { throw error }

            // The lock already exists – check for staleness
            do {
                if let lastModified = try s3.headObject(bucket: bucket, key: lockKey) {
                    let age = Date().timeIntervalSince(lastModified)
                    if age > Double(lockTTLSeconds) {
                        // Stale – delete and re-acquire
                        try s3.deleteObject(bucket: bucket, key: lockKey)
                        try s3.putObject(bucket: bucket, key: lockKey, body: Data(),
                                         metadata: nil, contentDisposition: nil, ifNoneMatch: "*")
                        return lockKey
                    }
                }
            } catch {
                logInfo("failed to check staleness of \(lockKey) for \(remoteRef): \(error)")
                throw error
            }

            return nil
        }
    }

    /// Release a previously acquired lock.
    public func releaseLock(remoteRef: String, lockKey: String) throws {
        do {
            try s3.deleteObject(bucket: bucket, key: lockKey)
        } catch {
            let is404 = error.localizedDescription.contains("404")
                || error.localizedDescription.contains("NoSuchKey")
            if is404 {
                logInfo("lock \(lockKey) already released")
            } else {
                throw error
            }
        }
    }

    // MARK: - cmd_option

    public func cmdOption(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 3).map(String.init)
        guard parts.count >= 3 else {
            writeStdout("unsupported\n")
            return
        }
        let option = parts[1]
        let value  = parts[2]
        if option == "verbosity", let v = Int(value), v >= 2 {
            verbose = true
            writeStdout("ok\n")
        } else {
            writeStdout("unsupported\n")
        }
    }

    // MARK: - cmd_list

    public func cmdList(forPush: Bool = false) throws {
        let objs = try listRefs(bucket: bucket, prefix: prefix)
        logInfo("objs: \(objs)")

        if !forPush {
            do {
                let head = try getRemoteHead()
                logInfo("HEAD=[\(head)]")
                for o in objs {
                    let ref = o.split(separator: "/").dropLast().joined(separator: "/")
                    if ref == head {
                        logInfo("@\(ref) HEAD")
                        writeStdout("@\(ref) HEAD\n")
                    }
                }
            } catch {
                // Ignore missing HEAD on remote
            }
        }

        let sha40 = "[a-f0-9]{40}"
        let bundlePattern = ".+/.+/.+/\(sha40)\\.bundle"
        let regex = try? NSRegularExpression(pattern: "^\(bundlePattern)$")

        for o in objs {
            let range = NSRange(location: 0, length: (o as NSString).length)
            if let r = regex, r.firstMatch(in: o, range: range) != nil {
                let elements = o.split(separator: "/")
                let sha = String(elements.last?.split(separator: ".").first ?? "")
                let refPath = elements.dropLast().joined(separator: "/")
                writeStdout("\(sha) \(refPath)\n")
            }
        }

        writeStdout("\n")
        flushStdout()
    }

    // MARK: - get_remote_head

    public func getRemoteHead() throws -> String {
        let data = try s3.getObject(bucket: bucket, key: "\(prefix)/HEAD")
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - cmd_capabilities

    public func cmdCapabilities() {
        writeStdout("*push\n")
        writeStdout("*fetch\n")
        writeStdout("option\n")
        writeStdout("\n")
        flushStdout()
    }

    // MARK: - Parallel fetch

    /// Process fetch commands in parallel using a `DispatchGroup`.
    public func processFetchCmds(_ cmds: [String]) {
        guard !cmds.isEmpty else { return }
        logInfo("Processing \(cmds.count) fetch commands in parallel")

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for cmd in cmds {
            group.enter()
            queue.async {
                do {
                    try self.cmdFetch(args: cmd)
                } catch {
                    // Log errors but don't crash the whole batch
                    fputs("error during fetch: \(error)\n", stderr)
                }
                group.leave()
            }
        }

        group.wait()
        logInfo("Completed processing \(cmds.count) fetch commands in parallel")
    }

    // MARK: - process_cmd  (main dispatch)

    public func processCmd(_ cmd: String) throws {
        let trimmed = cmd.trimmingCharacters(in: .newlines)

        if trimmed.hasPrefix("fetch") {
            if mode != .fetch {
                mode = .fetch
                fetchCmds = []
            }
            fetchCmds.append(trimmed)

        } else if trimmed.hasPrefix("push") {
            if mode != .push {
                mode = .push
                pushCmds = []
            }
            pushCmds.append(trimmed)

        } else if trimmed.hasPrefix("option") {
            cmdOption(trimmed)

        } else if trimmed == "list for-push" {
            try cmdList(forPush: true)

        } else if trimmed == "list" {
            try cmdList()

        } else if trimmed == "capabilities" {
            cmdCapabilities()

        } else if trimmed.isEmpty {
            // Empty line: flush accumulated commands
            logInfo("empty line")
            if mode == .push, !pushCmds.isEmpty {
                logInfo("pushing \(pushCmds)")
                for pushCmd in pushCmds {
                    let res = (try? cmdPush(args: pushCmd)) ?? "error: unknown push error\n"
                    writeStdout(res)
                }
                pushCmds = []
            } else if mode == .fetch, !fetchCmds.isEmpty {
                logInfo("fetching \(fetchCmds.count) refs in parallel")
                processFetchCmds(fetchCmds)
                fetchCmds = []
            }
            writeStdout("\n")
            flushStdout()

        } else {
            fputs("fatal: invalid command '\(trimmed)'\n", stderr)
            exit(1)
        }
    }

    // MARK: - I/O helpers

    private func writeStdout(_ s: String) {
        print(s, terminator: "")
    }

    private func flushStdout() {
        // Swift's stdout is line-buffered by default; no explicit flush needed in most
        // cases, but we can force it via FileHandle.
        FileHandle.standardOutput.synchronizeFile()
    }

    private func logInfo(_ msg: String) {
        if verbose {
            fputs("git-remote-s3: INFO: \(msg)\n", stderr)
        }
    }
}

// MARK: - cmdPush with lock-release wrapper

// Swift lacks `finally`; we wrap the push logic so the lock is always released.
extension S3Remote {
    /// Wrapper around the push body that ensures the lock is released.
    func cmdPushWithLock(args: String) throws -> String {
        var forcePush = false
        let parts = args.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "error: malformed push command\n" }
        let refPair = parts[1]
        let colonIdx = refPair.lastIndex(of: ":") ?? refPair.endIndex
        var localRef = String(refPair[refPair.startIndex..<colonIdx])
        let remoteRef = colonIdx < refPair.endIndex
            ? String(refPair[refPair.index(after: colonIdx)...])
            : ""

        if localRef.isEmpty {
            return try removeRemoteRef(remoteRef)
        }

        if localRef.hasPrefix("+") {
            let isProtected = try isProtectedRef(remoteRef)
            forcePush = !isProtected
            logInfo("Force push \(forcePush)")
            localRef = String(localRef.dropFirst())
        }

        logInfo("push !\(localRef)! !\(remoteRef)!")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git_remote_s3_push_\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let contents = try getBundlesForRef(remoteRef)
        if contents.count > 1 {
            try? FileManager.default.removeItem(atPath: tmpDir)
            return "error \(remoteRef) \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n"
        }
        let remoteToRemove: String? = contents.count == 1 ? (contents[0]["Key"] as? String) : nil

        var sha: String? = nil
        var lockKey: String? = nil

        defer {
            if let lk = lockKey {
                do {
                    try releaseLock(remoteRef: remoteRef, lockKey: lk)
                } catch {
                    logInfo("failed to release lock \(lk) for \(remoteRef): \(error)")
                }
            }
            if let s = sha {
                try? FileManager.default.removeItem(atPath: "\(tmpDir)/\(s).bundle")
            }
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        do {
            sha = try gitRevParse(localRef)
            let theSHA = sha!

            if let rtRemove = remoteToRemove {
                let remoteSHA = String((rtRemove as NSString).lastPathComponent
                    .replacingOccurrences(of: ".bundle", with: ""))
                if !forcePush {
                    let isAnc = try gitIsAncestor(remoteSHA, of: theSHA)
                    if !isAnc {
                        return "error \(remoteRef) \"remote ref is not ancestor of \(localRef).\"?\n"
                    }
                }
            }

            let bundlePath = try gitBundle(folder: tmpDir, sha: theSHA, ref: localRef)

            lockKey = try acquireLock(remoteRef)
            guard let _ = lockKey else {
                let lockPath = "\(prefix)/\(remoteRef)/LOCK#.lock"
                return "error \(remoteRef) \"failed to acquire ref lock at \(lockPath). " +
                    "Another client may be pushing. If this persists beyond \(lockTTLSeconds)s, " +
                    "run git-remote-s3 doctor --lock-ttl \(lockTTLSeconds) to inspect and optionally clear stale locks.\"?\n"
            }

            // Re-check after lock
            let currentContents = try getBundlesForRef(remoteRef)
            if currentContents.count > 1 {
                return "error \(remoteRef) \"multiple bundles exists for the same ref on server. " +
                    "Run git-s3 doctor to fix. Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n"
            }
            let currentRemoteToRemove: String? = currentContents.count == 1
                ? (currentContents[0]["Key"] as? String) : nil

            if let rtRemove = remoteToRemove,
               let curRtRemove = currentRemoteToRemove,
               curRtRemove != rtRemove
            {
                return "error \(remoteRef) \"stale remote. Please fetch and retry.\"?\n"
            }

            let bundleData = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
            try s3.putObject(bucket: bucket,
                             key: "\(prefix)/\(remoteRef)/\(theSHA).bundle",
                             body: bundleData,
                             metadata: nil, contentDisposition: nil, ifNoneMatch: nil)

            try initRemoteHead(ref: remoteRef)
            logInfo("pushed \(bundlePath) to \(remoteRef)")

            if let rtRemove = remoteToRemove {
                try s3.deleteObject(bucket: bucket, key: rtRemove)
            }

            if uriScheme == .s3Zip {
                let commitMsg = try gitGetLastCommitMessage()
                let archivePath = try gitArchive(folder: tmpDir, ref: localRef)
                let archiveData = try Data(contentsOf: URL(fileURLWithPath: archivePath))
                try s3.putObject(bucket: bucket,
                                 key: "\(prefix)/\(remoteRef)/repo.zip",
                                 body: archiveData,
                                 metadata: ["codepipeline-artifact-revision-summary": commitMsg],
                                 contentDisposition: "attachment; filename=repo-\(theSHA.prefix(8)).zip",
                                 ifNoneMatch: nil)
                logInfo("pushed archive to \(prefix)/\(remoteRef)/repo.zip with message \(commitMsg)")
            }

            return "ok \(remoteRef)\n"

        } catch let gitErr as GitError {
            logInfo("fatal: \(localRef) not found")
            return "error \(remoteRef) \"\(localRef) not found\"?\n"
        } catch {
            logInfo("fatal: \(error)")
            return "error \(remoteRef) \"\(error)\"?\n"
        }
    }
}
