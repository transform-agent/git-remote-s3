// SPDX-FileCopyrightText: Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

/// URI scheme variants understood by git-remote-s3.
///
/// Mirrors the Python `UriScheme` enum in `git_remote_s3/enums.py`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UriScheme {
    /// Plain `s3://` — bundle only.
    S3,
    /// `s3+zip://` — bundle **plus** a `repo.zip` archive (CodePipeline source).
    S3Zip,
}

impl std::fmt::Display for UriScheme {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            UriScheme::S3 => write!(f, "s3"),
            UriScheme::S3Zip => write!(f, "s3+zip"),
        }
    }
}

impl std::str::FromStr for UriScheme {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "s3" => Ok(UriScheme::S3),
            "s3+zip" => Ok(UriScheme::S3Zip),
            other => Err(format!("unknown URI scheme: {}", other)),
        }
    }
}
