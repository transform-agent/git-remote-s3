// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Entry-point for the `git-lfs-s3` binary.
// Translated from git_remote_s3/lfs.py::main()

import Foundation
import GitRemoteS3

do {
    try lfsMain(arguments: CommandLine.arguments)
} catch {
    fputs("fatal: \(error)\n", stderr)
    fflush(stderr)
    exit(1)
}
