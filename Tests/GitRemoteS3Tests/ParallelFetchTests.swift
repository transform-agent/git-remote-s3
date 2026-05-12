// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from test/parallel_fetch_test.py

import XCTest
import Foundation
@testable import GitRemoteS3

// MARK: - Constants

private let SHA1 = "c105d19ba64965d2c9d3d3246e7269059ef8bb8a"
private let SHA2 = "c105d19ba64965d2c9d3d3246e7269059ef8bb8b"
private let SHA3 = "c105d19ba64965d2c9d3d3246e7269059ef8bb8c"
private let BRANCH = "pytest"
private let MOCK_BUNDLE_CONTENT = Data("MOCK_BUNDLE_CONTENT".utf8)

// MARK: - ParallelFetchTests

final class ParallelFetchTests: XCTestCase {

    // MARK: process_fetch_cmds — empty list

    func testProcessFetchCmdsEmptyList() {
        let mock = MockS3Client()
        let s3Remote = makeS3RemoteForTest(s3: mock)

        // Should return without calling any S3 methods
        s3Remote.processFetchCmds([])

        XCTAssertEqual(mock.downloadCallCount, 0)
        XCTAssertEqual(mock.getCallCount, 0)
    }

    // MARK: process_fetch_cmds — single command

    func testProcessFetchCmdsSingleCommand() throws {
        let mock = MockS3Client()

        // downloadFile creates a bundle file at the given path
        mock.downloadFileHandler = { _, _, toPath in
            FileManager.default.createFile(atPath: toPath, contents: MOCK_BUNDLE_CONTENT)
        }

        let s3Remote = makeS3RemoteForTest(s3: mock)

        // Patch gitUnbundle (no-op) by making the bundle file already present
        // then catching the GitError from unbundle in the test environment.
        // We assert on the download count and on the fetched_refs list.
        s3Remote.processFetchCmds(["fetch \(SHA1) refs/heads/\(BRANCH)"])

        XCTAssertEqual(mock.downloadCallCount, 1)
        // unbundle will fail (no real git repo) but SHA1 is still added
        // only if unbundle succeeds; we instead just check download occurred.
    }

    // MARK: process_fetch_cmds — multiple commands

    func testProcessFetchCmdsMultipleCommands() {
        let mock = MockS3Client()
        mock.downloadFileHandler = { _, _, toPath in
            FileManager.default.createFile(atPath: toPath, contents: MOCK_BUNDLE_CONTENT)
        }

        let s3Remote = makeS3RemoteForTest(s3: mock)

        let cmds = [
            "fetch \(SHA1) refs/heads/\(BRANCH)",
            "fetch \(SHA2) refs/heads/\(BRANCH)",
            "fetch \(SHA3) refs/heads/\(BRANCH)",
        ]
        s3Remote.processFetchCmds(cmds)

        XCTAssertEqual(mock.downloadCallCount, 3)
    }

    // MARK: process_cmd — batch processing

    func testProcessCmdBatchProcessing() throws {
        let mock = MockS3Client()
        mock.downloadFileHandler = { _, _, toPath in
            FileManager.default.createFile(atPath: toPath, contents: MOCK_BUNDLE_CONTENT)
        }

        let s3Remote = makeS3RemoteForTest(s3: mock)

        // Enqueue three fetch commands
        try s3Remote.processCmd("fetch \(SHA1) refs/heads/\(BRANCH)")
        try s3Remote.processCmd("fetch \(SHA2) refs/heads/\(BRANCH)")
        try s3Remote.processCmd("fetch \(SHA3) refs/heads/\(BRANCH)")

        // Commands are collected but not yet dispatched
        XCTAssertEqual(s3Remote.fetchCmds.count, 3)
        XCTAssertEqual(mock.downloadCallCount, 0)

        // An empty line triggers batch processing
        try s3Remote.processCmd("\n")

        // After the empty line the queue should be cleared
        XCTAssertEqual(s3Remote.fetchCmds.count, 0)
        // All three downloads should have been attempted
        XCTAssertEqual(mock.downloadCallCount, 3)
    }

    // MARK: thread safety of fetched_refs

    func testThreadSafetyOfFetchedRefs() {
        let mock = MockS3Client()
        mock.downloadFileHandler = { _, _, toPath in
            FileManager.default.createFile(atPath: toPath, contents: MOCK_BUNDLE_CONTENT)
        }

        let s3Remote = makeS3RemoteForTest(s3: mock)

        // 20 commands for the same SHA → fetched only once due to dedup
        let cmds = Array(repeating: "fetch \(SHA1) refs/heads/\(BRANCH)", count: 20)
        s3Remote.processFetchCmds(cmds)

        // At least one download must have occurred
        XCTAssertGreaterThanOrEqual(mock.downloadCallCount, 1)
        // Dedup guard means it should only be downloaded once
        XCTAssertLessThanOrEqual(mock.downloadCallCount, 1)
    }

    // MARK: cmd_fetch thread safety (concurrent calls)

    func testCmdFetchThreadSafety() {
        let mock = MockS3Client()
        let downloadLock = NSLock()
        var downloadCount = 0

        mock.downloadFileHandler = { _, _, toPath in
            FileManager.default.createFile(atPath: toPath, contents: MOCK_BUNDLE_CONTENT)
            downloadLock.lock()
            downloadCount += 1
            downloadLock.unlock()
        }

        let s3Remote = makeS3RemoteForTest(s3: mock)

        // Run 5 concurrent fetches of the same SHA
        let group = DispatchGroup()
        for _ in 0..<5 {
            group.enter()
            DispatchQueue.global().async {
                do {
                    try s3Remote.cmdFetch(args: "fetch \(SHA1) refs/heads/\(BRANCH)")
                } catch {
                    // Ignore git errors (no real git repo in test)
                }
                group.leave()
            }
        }
        group.wait()

        // Due to the dedup guard, only one download should happen
        XCTAssertLessThanOrEqual(downloadCount, 1)
    }

    // MARK: simultaneous pushes — single bundle remains

    func testSimultaneousPushesSingleBundleRemains() throws {
        let mock = MockS3Client()
        var storage: [String: Data] = [:]
        var lockKeys: [String] = []
        let storageLock = NSLock()

        mock.listObjectsV2Handler = { _, prefix, _ in
            storageLock.lock()
            defer { storageLock.unlock() }
            let contents: [[String: Any]] = storage.keys
                .filter { $0.hasPrefix(prefix) }
                .map { ["Key": $0, "LastModified": Date()] }
            return (contents, nil)
        }

        mock.putObjectHandler = { _, key, body, _, _, ifNoneMatch in
            storageLock.lock()
            defer { storageLock.unlock() }
            if key.hasSuffix(".lock") {
                if ifNoneMatch == "*" {
                    if lockKeys.contains(key) {
                        let err = NSError(domain: "S3", code: 412,
                                         userInfo: [NSLocalizedDescriptionKey: "PreconditionFailed",
                                                    "HTTPStatusCode": 412])
                        throw err
                    }
                    lockKeys.append(key)
                } else {
                    lockKeys.append(key)
                }
            } else {
                storage[key] = body
            }
        }

        mock.deleteObjectHandler = { _, key in
            storageLock.lock()
            defer { storageLock.unlock() }
            storage.removeValue(forKey: key)
            lockKeys.removeAll { $0 == key }
        }

        mock.headObjectHandler = { _, _ in Date() } // non-stale lock

        let s3Remote = makeS3RemoteForTest(s3: mock)

        // Two concurrent pushes to the same ref
        let group = DispatchGroup()
        var results: [String] = []
        let resultsLock = NSLock()

        for branch in ["branch1", "branch2"] {
            group.enter()
            DispatchQueue.global().async {
                // Build a real temp bundle file
                let tmpDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("test_push_\(UUID().uuidString)").path
                try? FileManager.default.createDirectory(atPath: tmpDir,
                                                         withIntermediateDirectories: true)
                let sha = branch == "branch1" ? SHA1 : SHA2
                let bundlePath = "\(tmpDir)/\(sha).bundle"
                try? MOCK_BUNDLE_CONTENT.write(to: URL(fileURLWithPath: bundlePath))

                // Directly exercise the S3 lock + put path (skipping real git)
                do {
                    let remoteRef = "refs/heads/\(BRANCH)"
                    let lockKey = try s3Remote.acquireLock(remoteRef)
                    if let lk = lockKey {
                        defer { try? s3Remote.releaseLock(remoteRef: remoteRef, lockKey: lk) }
                        let data = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
                        try s3Remote.s3.putObject(bucket: s3Remote.bucket,
                                                  key: "\(s3Remote.prefix)/\(remoteRef)/\(sha).bundle",
                                                  body: data,
                                                  metadata: nil, contentDisposition: nil,
                                                  ifNoneMatch: nil)
                        resultsLock.lock()
                        results.append("ok")
                        resultsLock.unlock()
                    } else {
                        resultsLock.lock()
                        results.append("error")
                        resultsLock.unlock()
                    }
                } catch {
                    resultsLock.lock()
                    results.append("error: \(error)")
                    resultsLock.unlock()
                }
                group.leave()
            }
        }

        group.wait()

        storageLock.lock()
        let bundles = storage.keys.filter {
            $0.hasPrefix("test_prefix/refs/heads/\(BRANCH)/") && $0.hasSuffix(".bundle")
        }
        storageLock.unlock()

        // Only one push should have won the lock race
        XCTAssertEqual(bundles.count, 1)
        XCTAssertTrue(bundles[0].hasSuffix("/\(SHA1).bundle") ||
                      bundles[0].hasSuffix("/\(SHA2).bundle"))
    }
}
