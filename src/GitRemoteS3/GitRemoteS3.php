<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

/**
 * Namespace entry-point — re-exports the public API.
 *
 * Corresponds to git_remote_s3/__init__.py.
 *
 * Usage:
 *   use GitRemoteS3\UriScheme;
 *   use GitRemoteS3\Remote;
 *   use GitRemoteS3\Common;
 *   use GitRemoteS3\Doctor;
 *   use GitRemoteS3\Git;
 */

// Ensure all public classes are loaded (autoloader will handle this, but
// listing them here documents the public API surface).

// UriScheme  — src/GitRemoteS3/UriScheme.php
// Common     — src/GitRemoteS3/Common.php     (parseGitUrl)
// Git        — src/GitRemoteS3/Git.php        (GitError + subprocess helpers)
// Remote     — src/GitRemoteS3/Remote.php     (S3Remote class + main())
// Lfs        — src/GitRemoteS3/Lfs.php        (LFSProcess + lfsMain())
// Doctor     — src/GitRemoteS3/Manage.php     (Doctor + ManageBranch + manageMain())
