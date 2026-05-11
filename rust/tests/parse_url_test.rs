// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! URL parsing tests — mirrors `test/parse_url_test.py`.

use git_remote_s3::common::parse_git_url;
use git_remote_s3::enums::UriScheme;

#[test]
fn test_parse_url_trailing_slash_no_profile() {
    let parsed = parse_git_url("s3://bucket-name/path/to/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile, None);
    assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
}

#[test]
fn test_parse_url_no_profile() {
    let parsed = parse_git_url("s3://bucket-name/path/to").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile, None);
    assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
}

#[test]
fn test_parse_url() {
    let parsed = parse_git_url("s3://profile-test@bucket-name/path/to").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile.as_deref(), Some("profile-test"));
    assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
}

#[test]
fn test_parse_url_issue5() {
    let parsed = parse_git_url("s3://er@bucket/path/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket");
    assert_eq!(parsed.profile.as_deref(), Some("er"));
    assert_eq!(parsed.prefix.as_deref(), Some("path"));
}

#[test]
fn test_parse_url_1_char_profile() {
    let parsed = parse_git_url("s3://A@bucket/path/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket");
    assert_eq!(parsed.profile.as_deref(), Some("A"));
    assert_eq!(parsed.prefix.as_deref(), Some("path"));
}

#[test]
fn test_parse_url_all_supported_symbols_in_profile() {
    let parsed = parse_git_url("s3://Ab-tr+54_quwww@bucket/path/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket");
    assert_eq!(parsed.profile.as_deref(), Some("Ab-tr+54_quwww"));
    assert_eq!(parsed.prefix.as_deref(), Some("path"));
}

#[test]
fn test_parse_url_unsupported_symbols_in_profile() {
    // The Python regex `[^@]+@` will match `A!` before the `@`
    let parsed = parse_git_url("s3://A!@bucket/path/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket");
    assert_eq!(parsed.profile.as_deref(), Some("A!"));
    assert_eq!(parsed.prefix.as_deref(), Some("path"));
}

#[test]
fn test_parse_url_empty_profile() {
    // `s3://@bucket/path/` — empty profile string → None
    let result = parse_git_url("s3://@bucket/path/");
    assert!(result.is_none());
}

#[test]
fn test_parse_url_no_prefix_trailing_slash() {
    let parsed = parse_git_url("s3://profile-test@bucket-name/").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile.as_deref(), Some("profile-test"));
    assert!(parsed.prefix.is_none());
}

#[test]
fn test_parse_url_no_prefix() {
    let parsed = parse_git_url("s3://profile-test@bucket-name").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile.as_deref(), Some("profile-test"));
    assert!(parsed.prefix.is_none());
}

#[test]
fn test_parse_url_no_prefix_no_profile() {
    let parsed = parse_git_url("s3://bucket-name").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile, None);
    assert!(parsed.prefix.is_none());
}

#[test]
fn test_parse_url_not_valid() {
    let result = parse_git_url("s4://bucket-name/path/to");
    assert!(result.is_none());
}

#[test]
fn test_parse_url_none_equivalent() {
    // Rust has no `None` URL, but an empty string should return None.
    let result = parse_git_url("");
    assert!(result.is_none());
}

#[test]
fn test_parse_url_uri_scheme_s3_zip_no_profile() {
    let parsed = parse_git_url("s3+zip://bucket-name/path/to").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3Zip);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile, None);
    assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
}

#[test]
fn test_parse_url_uri_scheme_s3_zip() {
    let parsed = parse_git_url("s3+zip://profile-test@bucket-name/path/to").unwrap();
    assert_eq!(parsed.uri_scheme, UriScheme::S3Zip);
    assert_eq!(parsed.bucket, "bucket-name");
    assert_eq!(parsed.profile.as_deref(), Some("profile-test"));
    assert_eq!(parsed.prefix.as_deref(), Some("path/to"));
}

#[test]
fn test_parse_url_uri_scheme_not_valid() {
    let result = parse_git_url("s3+foo://bucket-name/path/to");
    assert!(result.is_none());
}
