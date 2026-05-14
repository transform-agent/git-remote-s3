<?php

// SPDX-FileCopyrightText: Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

/**
 * URI scheme for git-remote-s3 remotes.
 *
 * Corresponds to the Python UriScheme enum in git_remote_s3/enums.py.
 */
enum UriScheme: string
{
    case S3     = 's3';
    case S3_ZIP = 's3+zip';
}
