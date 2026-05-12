// SPDX-FileCopyrightText: Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/enums.py

/// URI schemes supported by git-remote-s3.
public enum UriScheme: String, Equatable {
    case s3    = "s3"
    case s3Zip = "s3+zip"
}
