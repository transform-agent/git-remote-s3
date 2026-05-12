// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/manage.py

import Foundation
import AWSS3
import AWSClientRuntime

// MARK: - Doctor

/// Analyses and repairs an S3-hosted git repository.
///
/// Translated from `git_remote_s3/manage.py::Doctor`.
public final class Doctor {

    public let bucket: String
    public let prefix: String
    public let deleteBundle: Bool
    public let lockTTLSeconds: Int
    public let deleteStaleLocks: Bool
    private let s3: S3ClientProtocol

    public init(profile: String?, bucket: String, prefix: String,
                deleteBundle: Bool, lockTTLSeconds: Int = 60,
                deleteStaleLocks: Bool = false,
                s3Client: S3ClientProtocol? = nil) throws
    {
        self.bucket = bucket
        self.prefix = prefix
        self.deleteBundle = deleteBundle
        self.lockTTLSeconds = lockTTLSeconds
        self.deleteStaleLocks = deleteStaleLocks

        if let provided = s3Client {
            self.s3 = provided
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var client: AWSS3ClientWrapper?
            var thrownError: Error?
            Task {
                do { client = try await AWSS3ClientWrapper(profile: profile) }
                catch { thrownError = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let e = thrownError { throw e }
            self.s3 = client!
        }
    }

    // MARK: run

    public func run() throws {
        let repos = try analyzeRepo()
        for repoName in repos.keys.sorted() {
            guard let repoInfo = repos[repoName] else { continue }
            print("\(repoName):")
            var headRef = "Invalid"
            let refs = repoInfo["refs"] as? [String: [String: Any]] ?? [:]
            let headValue = repoInfo["HEAD"] as? String ?? "Missing"

            for ref in refs.keys.sorted() {
                guard let refInfo = refs[ref] else { continue }
                if headValue == ref { headRef = ref }
                let isProtected = refInfo["protected"] as? Bool ?? false
                let bundles = refInfo["bundles"] as? [[String: Any]] ?? []
                let part1 = isProtected ? "*" : ""
                let part2 = bundles.count == 1 ? "Ok" : "Multiple refs"
                print(" \(part1) \(ref): \(part2)")
            }
            if headRef == "Invalid" {
                // repos[r]["HEAD"] = "Invalid" (informational only; dict is value type in Swift)
            }
            print("  HEAD: \(headRef)")
        }
        var mutableRepos = repos
        try fixIssues(&mutableRepos)
    }

    // MARK: fixIssues

    public func fixIssues(_ repos: inout [String: [String: Any]]) throws {
        for repoName in repos.keys {
            guard let repoInfo = repos[repoName] else { continue }
            let refs = repoInfo["refs"] as? [String: [String: Any]] ?? [:]
            for ref in refs.keys {
                guard let refInfo = refs[ref] else { continue }
                let bundles = refInfo["bundles"] as? [[String: Any]] ?? []
                if bundles.count > 1 {
                    try fixMultipleBundles(&repos, repo: repoName, ref: ref)
                }
            }
            let headValue = repos[repoName]?["HEAD"] as? String ?? "Missing"
            if headValue == "Invalid" {
                try fixHead(&repos, repo: repoName)
            }
        }
        try listAndHandleStaleLocks()
    }

    // MARK: listAndHandleStaleLocks

    public func listAndHandleStaleLocks() throws {
        print("\nScanning for stale locks...")
        let result = try s3.listObjectsV2(bucket: bucket, prefix: "\(prefix)/",
                                          continuationToken: nil)
        let now = Date()
        var stale: [(key: String, age: Int)] = []

        for obj in result.contents {
            guard let key = obj["Key"] as? String, key.hasSuffix(".lock") else { continue }
            if let lastModified = obj["LastModified"] as? Date {
                let age = Int(now.timeIntervalSince(lastModified))
                if age > lockTTLSeconds {
                    stale.append((key: key, age: age))
                }
            }
        }

        if stale.isEmpty {
            print("No stale locks found.")
            return
        }

        print("Found stale locks:")
        for item in stale {
            print(" - \(item.key) (age: \(item.age)s)")
        }

        if deleteStaleLocks {
            print("\nDeleting stale locks...")
            for item in stale {
                do {
                    try s3.deleteObject(bucket: bucket, key: item.key)
                    print("Deleted \(item.key)")
                } catch {
                    print("Failed to delete \(item.key): \(error)")
                }
            }
        } else {
            print("\nRun with --delete-stale-locks to remove them automatically.")
        }
    }

    // MARK: analyzeRepo

    public func analyzeRepo() throws -> [String: [String: Any]] {
        let result = try s3.listObjectsV2(bucket: bucket, prefix: "\(prefix)/",
                                          continuationToken: nil)
        var repos: [String: [String: Any]] = [:]

        for obj in result.contents {
            guard let key = obj["Key"] as? String else { continue }
            let keyParts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !keyParts.isEmpty else { continue }
            let repoName = keyParts[0]

            if repos[repoName] == nil {
                repos[repoName] = ["refs": [String: [String: Any]](), "HEAD": "Missing"]
            }

            guard keyParts.count > 1 else { continue }

            if keyParts[1] == "HEAD" {
                let headData = try s3.getObject(bucket: bucket, key: key)
                let headRef = (String(data: headData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                repos[repoName]?["HEAD"] = headRef
                continue
            }

            let refs = keyParts.dropFirst().dropLast().joined(separator: "/")
            var refsDict = repos[repoName]?["refs"] as? [String: [String: Any]] ?? [:]
            if refsDict[refs] == nil {
                refsDict[refs] = ["protected": false, "bundles": [[String: Any]]()]
            }

            if keyParts.last == "PROTECTED#" {
                refsDict[refs]?["protected"] = true
            } else {
                let sha = String(keyParts.last?.split(separator: ".").first ?? "")
                var bundles = refsDict[refs]?["bundles"] as? [[String: Any]] ?? []
                bundles.append([
                    "sha": sha,
                    "lastModified": obj["LastModified"] ?? Date(),
                ])
                refsDict[refs]?["bundles"] = bundles
            }
            repos[repoName]?["refs"] = refsDict
        }
        return repos
    }

    // MARK: fixMultipleBundles

    public func fixMultipleBundles(_ repos: inout [String: [String: Any]],
                                   repo: String, ref: String) throws
    {
        print("\nFix multiple bundles for repo \(repo) and ref \(ref)")
        let refs = repos[repo]?["refs"] as? [String: [String: Any]] ?? [:]
        let bundles = refs[ref]?["bundles"] as? [[String: Any]] ?? []

        for (i, bundle) in bundles.enumerated() {
            print("\(i + 1). \(bundle["sha"] ?? "") \(bundle["lastModified"] ?? "")")
        }

        while true {
            print("Enter the number of the bundle to keep: ", terminator: "")
            fflush(stdout)
            guard let line = readLine(), let idx = Int(line) else {
                print("Invalid input")
                continue
            }
            if idx > 0 && idx <= bundles.count {
                let keepSHA = bundles[idx - 1]["sha"] as? String ?? ""
                print("Keeping \(keepSHA)")
                print("Press enter to confirm or Ctrl+C to cancel")
                _ = readLine()

                for bundle in bundles {
                    guard let sha = bundle["sha"] as? String, sha != keepSHA else { continue }
                    if deleteBundle {
                        print("Removing \(sha)")
                        try s3.deleteObject(bucket: bucket,
                                            key: "\(prefix)/\(ref)/\(sha).bundle")
                    } else {
                        let tmpBranch = "\(ref)_\(UUID().uuidString.prefix(8).lowercased())"
                        print("Moving \(sha) to new branch \(tmpBranch)")
                        try s3.copyObject(sourceBucket: bucket,
                                          sourceKey: "\(prefix)/\(ref)/\(sha).bundle",
                                          destBucket: bucket,
                                          destKey: "\(prefix)/\(tmpBranch)/\(sha).bundle")
                        try s3.deleteObject(bucket: bucket,
                                            key: "\(prefix)/\(ref)/\(sha).bundle")
                    }
                }
                break
            } else {
                print("Invalid input")
            }
        }
    }

    // MARK: fixHead

    public func fixHead(_ repos: inout [String: [String: Any]], repo: String) throws {
        print("\nFix invalid HEAD for repo \(repo)")
        let refs = repos[repo]?["refs"] as? [String: [String: Any]] ?? [:]
        let heads = refs.keys.filter { $0.contains("heads") }.sorted()

        for (i, head) in heads.enumerated() {
            print("\(i + 1). \(head.split(separator: "/").last ?? "")")
        }

        while true {
            print("Enter the number of the branch to use as head: ", terminator: "")
            fflush(stdout)
            guard let line = readLine(), let idx = Int(line) else {
                print("Invalid input")
                continue
            }
            if idx > 0 && idx <= heads.count {
                let head = heads[idx - 1]
                print("Setting \(head) as HEAD")
                try s3.putObject(bucket: bucket, key: "\(prefix)/HEAD",
                                 body: Data(head.utf8),
                                 metadata: nil, contentDisposition: nil, ifNoneMatch: nil)
                break
            } else {
                print("Invalid input")
            }
        }
    }
}

// MARK: - ManageBranch

/// Manages individual branches in the remote S3 repository.
///
/// Translated from `git_remote_s3/manage.py::ManageBranch`.
public final class ManageBranch {

    public let bucket: String
    public let prefix: String
    public let branch: String
    private let s3: S3ClientProtocol

    public init(profile: String?, bucket: String, prefix: String, branch: String,
                s3Client: S3ClientProtocol? = nil) throws
    {
        self.bucket = bucket
        self.prefix = prefix
        self.branch = branch

        if let provided = s3Client {
            self.s3 = provided
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var client: AWSS3ClientWrapper?
            var thrownError: Error?
            Task {
                do { client = try await AWSS3ClientWrapper(profile: profile) }
                catch { thrownError = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let e = thrownError { throw e }
            self.s3 = client!
        }

        guard !(try getBranchContent().isEmpty) else {
            throw ManageBranchError.branchNotFound(branch)
        }
    }

    public enum ManageBranchError: Error {
        case branchNotFound(String)
    }

    // MARK: processCmd

    public func processCmd(_ cmd: String) throws {
        switch cmd {
        case "delete-branch": try deleteBranch()
        case "protect":       try protectBranch()
        case "unprotect":     try unprotectBranch()
        default: break
        }
    }

    // MARK: deleteBranch

    public func deleteBranch() throws {
        let objs = try getBranchContent()
        print("Delete \(branch) branch [yes/no]: ", terminator: "")
        fflush(stdout)
        if let resp = readLine(), resp.lowercased() == "yes" {
            for obj in objs {
                if let key = obj["Key"] as? String {
                    try s3.deleteObject(bucket: bucket, key: key)
                }
            }
            print("Branch \(branch) has been deleted")
        } else {
            print("Aborted")
        }
    }

    // MARK: getBranchContent

    public func getBranchContent() throws -> [[String: Any]] {
        let result = try s3.listObjectsV2(bucket: bucket,
                                          prefix: "\(prefix)/refs/heads/\(branch)/",
                                          continuationToken: nil)
        return result.contents
    }

    // MARK: protectBranch

    public func protectBranch() throws {
        try s3.putObject(bucket: bucket,
                         key: "\(prefix)/refs/heads/\(branch)/PROTECTED#",
                         body: Data(),
                         metadata: nil, contentDisposition: nil, ifNoneMatch: nil)
        print("Branch \(branch) is now protected")
    }

    // MARK: unprotectBranch

    public func unprotectBranch() throws {
        try s3.deleteObject(bucket: bucket,
                            key: "\(prefix)/refs/heads/\(branch)/PROTECTED#")
        print("Branch \(branch) is now unprotected")
    }
}
