// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Entry-point for the `git-remote-s3` and `git-remote-s3+zip` binaries.
// Translated from git_remote_s3/remote.py::main()

import Foundation
import GitRemoteS3
import AWSS3
import AWSClientRuntime

// --------------------------------------------------------------------------
// Helpers to produce a concrete S3Remote from a parsed S3 URI
// --------------------------------------------------------------------------

func makeS3Remote(uriScheme: UriScheme, profile: String?, bucket: String,
                  prefix: String) throws -> S3Remote
{
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

    return S3Remote(
        uriScheme: uriScheme,
        profile: profile,
        bucket: bucket,
        prefix: prefix,
        s3Client: client!
    )
}

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------

let args = CommandLine.arguments
// git calls the remote helper as:  git-remote-s3 <remote-name> <remote-url>
// CommandLine.arguments[0] = program path
// CommandLine.arguments[1] = remote name (unused)
// CommandLine.arguments[2] = remote URL  (the s3:// URI)

guard args.count >= 3 else {
    fputs("fatal: usage: git-remote-s3 <remote> <url>\n", stderr)
    exit(1)
}

let remote = args[2]
let components = parseGitURL(remote)

guard let bucket = components.bucket, let prefix = components.prefix,
      let uriScheme = components.uriScheme
else {
    fputs("fatal: invalid remote '\(remote)'. You need to have a bucket and a prefix.\n", stderr)
    exit(1)
}

do {
    let s3remote = try makeS3Remote(uriScheme: uriScheme,
                                    profile: components.profile,
                                    bucket: bucket,
                                    prefix: prefix)

    // Main stdin loop
    while let line = readLine(strippingNewline: false) {
        try s3remote.processCmd(line)
    }

} catch let err as S3RemoteError {
    switch err {
    case .bucketNotFound(let b):
        fputs("fatal: bucket not found \(b)\n", stderr)
    case .notAuthorized(let action, let bucket):
        fputs("fatal: user not authorized to perform \(action) on \(bucket)\n", stderr)
    default:
        fputs("fatal: \(err)\n", stderr)
    }
    fflush(stderr)
    exit(1)
} catch {
    // Map AWS credential / auth errors
    let description = error.localizedDescription
    if description.contains("credential") || description.contains("profile") ||
       description.contains("unauthorized") || description.contains("Unauthorized")
    {
        fputs("fatal: invalid credentials \(error)\n", stderr)
    } else if description.contains("BrokenPipe") || description.contains("brokenPipe") {
        // Broken pipe – silently exit
        exit(0)
    } else {
        fputs("fatal: unknown error. Run with verbosity option to get full log\n", stderr)
    }
    fflush(stderr)
    exit(1)
}
