// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/lfs.py

import Foundation
import AWSS3
import AWSClientRuntime

// MARK: - Progress callback helper

/// Tracks upload/download progress and emits JSON progress events to stdout.
public final class ProgressTracker {
    private let oid: String
    private let lock = NSLock()
    private var seenSoFar: Int64 = 0

    public init(oid: String) {
        self.oid = oid
    }

    public func report(bytesAmount: Int64) {
        lock.lock()
        seenSoFar += bytesAmount
        let event: [String: Any] = [
            "event": "progress",
            "oid": oid,
            "bytesSoFar": seenSoFar,
            "bytesSinceLast": bytesAmount,
        ]
        lock.unlock()

        if let jsonData = try? JSONSerialization.data(withJSONObject: event),
           let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            print("\(jsonStr)")
            fflush(stdout)
        }
    }
}

// MARK: - Error event helpers

public func writeLFSErrorEvent(oid: String, errorMessage: String, flush: Bool = false) {
    let event: [String: Any] = [
        "event": "complete",
        "oid": oid,
        "error": ["code": 2, "message": errorMessage],
    ]
    if let jsonData = try? JSONSerialization.data(withJSONObject: event),
       let jsonStr = String(data: jsonData, encoding: .utf8)
    {
        print("\(jsonStr)")
        if flush { fflush(stdout) }
    }
}

// MARK: - LFSProcess

/// Handles the git-lfs custom transfer agent protocol over stdin/stdout.
///
/// Translated from `git_remote_s3/lfs.py::LFSProcess`.
public final class LFSProcess {

    public let prefix: String
    public let bucket: String
    public let profile: String?
    private var s3: S3ClientProtocol?

    // MARK: Init

    public init?(s3URI: String) {
        let components = parseGitURL(s3URI)
        guard let bucket = components.bucket, let prefix = components.prefix else {
            fputs("lfs: s3 uri \(s3URI) is invalid\n", stderr)
            let errorEvent: [String: Any] = [
                "error": ["code": 32, "message": "s3 uri \(s3URI) is invalid"]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: errorEvent),
               let str = String(data: data, encoding: .utf8)
            {
                print("\(str)")
                fflush(stdout)
            }
            return nil
        }
        self.prefix = prefix
        self.bucket = bucket
        self.profile = components.profile
        // Handshake: send empty JSON object to git-lfs
        print("{}")
        fflush(stdout)
    }

    // MARK: S3 client initialisation (lazy)

    private func initS3() throws {
        if s3 != nil { return }
        let semaphore = DispatchSemaphore(value: 0)
        var client: AWSS3ClientWrapper?
        var thrownError: Error?
        Task {
            do {
                client = try await AWSS3ClientWrapper(profile: profile)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let e = thrownError { throw e }
        s3 = client
    }

    // MARK: Upload

    public func upload(event: [String: Any]) {
        fputs("lfs: upload\n", stderr)
        guard let oid = event["oid"] as? String,
              let path = event["path"] as? String
        else { return }

        do {
            try initS3()
            guard let s3 = s3 else { return }

            // Check whether object already exists
            let prefix_ = self.prefix
            let bucket_ = self.bucket
            let result = try s3.listObjectsV2(bucket: bucket_,
                                              prefix: "\(prefix_)/lfs/\(oid)",
                                              continuationToken: nil)
            if !result.contents.isEmpty {
                fputs("lfs: object already exists\n", stderr)
                let doneEvent: [String: Any] = ["event": "complete", "oid": oid]
                if let data = try? JSONSerialization.data(withJSONObject: doneEvent),
                   let str = String(data: data, encoding: .utf8)
                {
                    print("\(str)")
                    fflush(stdout)
                }
                return
            }

            let tracker = ProgressTracker(oid: oid)
            try s3.uploadFile(localPath: path,
                              bucket: bucket_,
                              key: "\(prefix_)/lfs/\(oid)",
                              metadata: nil,
                              contentDisposition: nil,
                              progressCallback: { bytes in tracker.report(bytesAmount: bytes) })

            let doneEvent: [String: Any] = ["event": "complete", "oid": oid]
            if let data = try? JSONSerialization.data(withJSONObject: doneEvent),
               let str = String(data: data, encoding: .utf8)
            {
                print("\(str)")
            }
        } catch {
            fputs("lfs: error during upload: \(error)\n", stderr)
            writeLFSErrorEvent(oid: oid, errorMessage: error.localizedDescription)
        }
        fflush(stdout)
    }

    // MARK: Download

    public func download(event: [String: Any]) {
        fputs("lfs: download\n", stderr)
        guard let oid = event["oid"] as? String else { return }

        do {
            try initS3()
            guard let s3 = s3 else { return }

            let tmpDir = FileManager.default.currentDirectoryPath + "/.git/lfs/tmp"
            try FileManager.default.createDirectory(atPath: tmpDir,
                                                    withIntermediateDirectories: true)
            let destPath = "\(tmpDir)/\(oid)"
            let prefix_ = self.prefix
            let bucket_ = self.bucket

            let tracker = ProgressTracker(oid: oid)
            try s3.downloadFile(bucket: bucket_,
                                key: "\(prefix_)/lfs/\(oid)",
                                toPath: destPath)
            // Single progress event for the full download
            if let size = try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int64 {
                tracker.report(bytesAmount: size)
            }

            let doneEvent: [String: Any] = [
                "event": "complete",
                "oid": oid,
                "path": destPath,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: doneEvent),
               let str = String(data: data, encoding: .utf8)
            {
                print("\(str)")
            }
        } catch {
            fputs("lfs: error during download: \(error)\n", stderr)
            writeLFSErrorEvent(oid: oid, errorMessage: error.localizedDescription)
        }
        fflush(stdout)
    }
}

// MARK: - install

/// Configure git to use git-lfs-s3 as a custom LFS transfer agent.
public func lfsInstall() throws {
    func runGitConfig(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fputs(msg + "\n", stderr)
            fflush(stderr)
            exit(1)
        }
    }

    try runGitConfig([
        "git", "config", "--add",
        "lfs.customtransfer.git-lfs-s3.path", "git-lfs-s3",
    ])
    try runGitConfig([
        "git", "config", "--add",
        "lfs.standalonetransferagent", "git-lfs-s3",
    ])
    print("git-lfs-s3 installed")
    fflush(stdout)
}

// MARK: - lfsMain (entry-point logic)

public func lfsMain(arguments: [String]) throws {
    var debugMode = false

    if arguments.count > 1 {
        switch arguments[1] {
        case "install":
            try lfsInstall()
            exit(0)
        case "debug":
            debugMode = true
        case "enable-debug":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "config", "--add",
                                  "lfs.customtransfer.git-lfs-s3.args", "debug"]
            try process.run()
            process.waitUntilExit()
            print("debug enabled")
            exit(0)
        case "disable-debug":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "config", "--unset",
                                  "lfs.customtransfer.git-lfs-s3.args"]
            try process.run()
            process.waitUntilExit()
            print("debug disabled")
            exit(0)
        default:
            fputs("unknown command \(arguments[1])\n", stderr)
            exit(1)
        }
    }

    var lfsProcess: LFSProcess? = nil

    while true {
        if debugMode { fputs("git-lfs-s3 starting\n", stderr) }

        guard let line = readLine(strippingNewline: false) else { break }
        if debugMode { fputs(line, stderr) }

        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        switch event["event"] as? String {
        case "init":
            guard let remote = event["remote"] as? String else { continue }
            if !validateRefName(remote) {
                fputs("lfs: invalid ref \(remote)\n", stderr)
                print("{}")
                fflush(stdout)
                exit(1)
            }
            do {
                let url = try gitGetRemoteURL(remote)
                lfsProcess = LFSProcess(s3URI: url)
                if lfsProcess == nil { exit(1) }
            } catch {
                fputs("lfs: \(error)\n", stderr)
                let errEvent: [String: Any] = [
                    "error": ["code": 2, "message": "cannot resolve remote \"\(remote)\""]
                ]
                if let d = try? JSONSerialization.data(withJSONObject: errEvent),
                   let s = String(data: d, encoding: .utf8)
                {
                    print(s)
                    fflush(stdout)
                }
                exit(1)
            }

        case "upload":
            lfsProcess?.upload(event: event)

        case "download":
            lfsProcess?.download(event: event)

        default:
            break
        }
    }
}
