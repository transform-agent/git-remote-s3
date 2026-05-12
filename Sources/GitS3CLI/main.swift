// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Entry-point for the `git-s3` binary.
// Translated from git_remote_s3/manage.py::main()

import Foundation
import GitRemoteS3
import ArgumentParser

// MARK: - GitS3 command

struct GitS3: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "git-s3",
        abstract: "Manage an S3-hosted git remote.",
        subcommands: [DoctorCommand.self, BranchCommand.self],
        defaultSubcommand: nil
    )
}

// MARK: - doctor sub-command

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Analyse and repair an S3-hosted git repository."
    )

    @Argument(help: "The remote S3 URI (or git remote name) to analyse.")
    var remote: String

    @Flag(name: .shortAndLong, help: "Delete conflicting bundles instead of moving to a new branch.")
    var deleteBundle = false

    @Option(name: .long, help: "Seconds after which a lock is considered stale (default: \(defaultLockTTLSeconds)).")
    var lockTtl: Int = defaultLockTTLSeconds

    @Flag(name: .long, help: "Delete stale lock files found during the doctor run.")
    var deleteStaleLocks = false

    mutating func run() throws {
        let remoteURL = try resolveRemoteURL(remote)
        let components = parseGitURL(remoteURL)

        guard let bucket = components.bucket, let prefix = components.prefix else {
            fputs("fatal: invalid remote '\(remote)'. You need to have a bucket and a prefix.\n", stderr)
            throw ExitCode.failure
        }

        let doctor = try Doctor(
            profile: components.profile,
            bucket: bucket,
            prefix: prefix,
            deleteBundle: deleteBundle,
            lockTTLSeconds: lockTtl,
            deleteStaleLocks: deleteStaleLocks
        )
        try doctor.run()
    }
}

// MARK: - Branch management sub-commands (delete-branch, protect, unprotect)

struct BranchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "Manage branches on the S3 remote.",
        subcommands: [DeleteBranchCommand.self, ProtectCommand.self, UnprotectCommand.self]
    )
}

struct DeleteBranchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-branch",
        abstract: "Delete a branch from the S3 remote."
    )
    @Argument var remote: String
    @Argument var branch: String

    mutating func run() throws {
        try manageBranch(command: "delete-branch", remote: remote, branch: branch)
    }
}

struct ProtectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "protect",
        abstract: "Protect a branch on the S3 remote."
    )
    @Argument var remote: String
    @Argument var branch: String

    mutating func run() throws {
        try manageBranch(command: "protect", remote: remote, branch: branch)
    }
}

struct UnprotectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unprotect",
        abstract: "Remove protection from a branch on the S3 remote."
    )
    @Argument var remote: String
    @Argument var branch: String

    mutating func run() throws {
        try manageBranch(command: "unprotect", remote: remote, branch: branch)
    }
}

// MARK: - Helpers

/// Resolve a git remote name or a direct S3 URI.
private func resolveRemoteURL(_ remote: String) throws -> String {
    if remote.hasPrefix("s3://") || remote.hasPrefix("s3+zip://") {
        return remote
    }
    do {
        return try gitGetRemoteURL(remote)
    } catch {
        fputs("fatal: \(error)\n", stderr)
        throw ExitCode.failure
    }
}

private func manageBranch(command: String, remote: String, branch: String) throws {
    let remoteURL = try resolveRemoteURL(remote)
    let components = parseGitURL(remoteURL)

    guard let bucket = components.bucket, let prefix = components.prefix else {
        fputs("fatal: invalid remote '\(remote)'.\n", stderr)
        throw ExitCode.failure
    }

    do {
        let mgr = try ManageBranch(
            profile: components.profile,
            bucket: bucket,
            prefix: prefix,
            branch: branch
        )
        try mgr.processCmd(command)
    } catch ManageBranch.ManageBranchError.branchNotFound(let b) {
        fputs("fatal: Branch \(b) does not exist\n", stderr)
        throw ExitCode.failure
    }
}

// MARK: - Run

GitS3.main()
