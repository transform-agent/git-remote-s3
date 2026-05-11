// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! URL parsing helpers.
//!
//! Mirrors `git_remote_s3/common.py`.

use regex::Regex;

use crate::enums::UriScheme;

/// Parsed components of an `s3://` or `s3+zip://` remote URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedGitUrl {
    pub uri_scheme: UriScheme,
    /// AWS profile name (the `profile@` portion of the URL), if present.
    pub profile: Option<String>,
    /// S3 bucket name.
    pub bucket: String,
    /// Key prefix inside the bucket (trailing `/` stripped).  May be `None`
    /// if the URL has no path component.
    pub prefix: Option<String>,
}

/// Parse the elements of an `s3://` remote origin URI.
///
/// Returns `None` if `url` is invalid or does not match the expected pattern.
///
/// # Examples
/// ```
/// use git_remote_s3::common::parse_git_url;
/// use git_remote_s3::enums::UriScheme;
///
/// let parsed = parse_git_url("s3://my-profile@my-bucket/path/to").unwrap();
/// assert_eq!(parsed.uri_scheme, UriScheme::S3);
/// assert_eq!(parsed.profile.as_deref(), Some("my-profile"));
/// assert_eq!(parsed.bucket, "my-bucket");
/// assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
/// ```
pub fn parse_git_url(url: &str) -> Option<ParsedGitUrl> {
    // Regex mirrors the Python version:
    //   (s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?
    // We use a `std::sync::OnceLock` so the regex is compiled only once.
    use std::sync::OnceLock;
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(
            r"^(s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9.\-]{2,62})/?(.+)?$",
        )
        .expect("hardcoded regex must compile")
    });

    let caps = re.captures(url)?;

    // Group 1: scheme
    let scheme_str = caps.get(1)?.as_str();
    let uri_scheme = match scheme_str {
        "s3" => UriScheme::S3,
        "s3+zip" => UriScheme::S3Zip,
        _ => return None,
    };

    // Group 2: optional `profile@`
    let profile = caps.get(2).map(|m| {
        let s = m.as_str();
        // Strip trailing '@'
        s.trim_end_matches('@').to_owned()
    });

    // Reject an empty profile (i.e. the URL started with `@`)
    if let Some(ref p) = profile {
        if p.is_empty() {
            return None;
        }
    }

    // Group 3: bucket
    let bucket = caps.get(3)?.as_str().to_owned();

    // Group 4: optional prefix
    let prefix = caps.get(4).map(|m| m.as_str().trim_matches('/').to_owned());
    // A prefix that is empty after stripping slashes becomes None
    let prefix = prefix.and_then(|p| if p.is_empty() { None } else { Some(p) });

    Some(ParsedGitUrl {
        uri_scheme,
        profile,
        bucket,
        prefix,
    })
}
