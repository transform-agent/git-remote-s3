// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/git.py

import Foundation

// MARK: - Error type

public enum GitError: Error, CustomStringConvertible {
    case commandFailed(String)
    case refNotFound(String)
    case remoteNotFound(String)
    case unknownError(String)

    public var description: String {
        switch self {
        case .commandFailed(let msg):  return msg
        case .refNotFound(let ref):    return "fatal: \(ref) not found"
        case .remoteNotFound(let r):   return "fatal: \(r) not found"
        case .unknownError(let msg):   return msg
        }
    }
}

// MARK: - Helpers

/// Run a command synchronously; return `(exitCode, stdout, stderr)`.
private func run(_ arguments: [String], pipeStdout: Bool = true, pipeStderr: Bool = true,
                 stdoutHandle: FileHandle? = nil) throws -> (Int32, String, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments

    var stdoutData = Data()
    var stderrData = Data()

    if let handle = stdoutHandle {
        process.standardOutput = handle
    } else if pipeStdout {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipeStderr ? Pipe() : FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        stdoutData = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        if pipeStderr {
            stderrData = (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
        }
        return (process.terminationStatus,
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? "")
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return (process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "")
}

// MARK: - Public API

/// Archive the content of the current repository into a `repo.zip` file.
///
/// - Parameters:
///   - folder: Directory where the archive should be written.
///   - ref: The git ref to archive.
/// - Returns: Path to the created archive file.
/// - Throws: ``GitError`` on failure.
public func gitArchive(folder: String, ref: String) throws -> String {
    let filePath = "\(folder)/repo.zip"
    let (code, _, stderr) = try run(
        ["git", "archive", "--format", "zip", "--output", filePath, ref]
    )
    if code == 0 { return filePath }
    throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Bundle the current repository into a `<sha>.bundle` file.
///
/// - Parameters:
///   - folder: Directory where the bundle should be written.
///   - sha: SHA that names the bundle file.
///   - ref: The git ref to bundle.
/// - Returns: Path to the created bundle file.
/// - Throws: ``GitError`` on failure.
public func gitBundle(folder: String, sha: String, ref: String) throws -> String {
    let filePath = "\(folder)/\(sha).bundle"
    let (code, _, stderr) = try run(
        ["git", "bundle", "create", filePath, ref]
    )
    if code == 0 { return filePath }
    throw GitError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Unbundle a previously created bundle into the current repository.
///
/// - Parameters:
///   - folder: Directory containing the `<sha>.bundle` file.
///   - sha: SHA identifying the bundle file.
///   - ref: The ref to unbundle into.
/// - Throws: ``GitError`` on failure.
public func gitUnbundle(folder: String, sha: String, ref: String) throws {
    // stdout is forwarded to stderr (matching the Python original)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "bundle", "unbundle", "\(folder)/\(sha).bundle", ref]
    process.standardOutput = FileHandle.standardError

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8) ?? ""
        throw GitError.commandFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Return the full SHA of the given git ref.
///
/// - Parameter ref: The ref to resolve.
/// - Returns: The 40-character hex SHA.
/// - Throws: ``GitError/refNotFound(_:)`` when the ref does not exist.
public func gitRevParse(_ ref: String) throws -> String {
    let (code, stdout, _) = try run(["git", "rev-parse", ref])
    if code != 0 { throw GitError.refNotFound(ref) }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Check whether `ancestor` is an ancestor of `descendant`.
///
/// - Returns: `true` when the ancestry holds.
public func gitIsAncestor(_ ancestor: String, of descendant: String) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "merge-base", "--is-ancestor", ancestor, descendant]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Return the fetch URL of the named remote.
///
/// - Throws: ``GitError/remoteNotFound(_:)`` when the remote is not configured.
public func gitGetRemoteURL(_ remote: String) throws -> String {
    let (code, stdout, _) = try run(["git", "remote", "get-url", remote])
    if code != 0 { throw GitError.remoteNotFound(remote) }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Validate a git ref name according to git's own rules.
///
/// See: https://github.com/git/git/blob/406f326/refs.c#L170
///
/// - Returns: `true` when the name is valid.
public func validateRefName(_ name: String) -> Bool {
    // Disallow: leading ".", "..", ":", "?", "[", "\\", "^", "~", whitespace, "*",
    //           ".lock" suffix, trailing "/", "@{", or control characters.
    let pattern = #"(^\.)|(\.\.)|([:\?\[\\\^\~\s\*\]])|(\.lock$)|(/$)|(@\{)|([\x00-\x1f])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
    let range = NSRange(location: 0, length: (name as NSString).length)
    return regex.firstMatch(in: name, range: range) == nil
}

/// Return a short description of the last commit (`%h %s`).
///
/// - Throws: ``GitError`` on failure.
public func gitGetLastCommitMessage() throws -> String {
    let (code, stdout, _) = try run(["git", "log", "-1", "--pretty=%h %s"])
    if code != 0 { throw GitError.commandFailed("fatal: an error has occurred") }
    return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
