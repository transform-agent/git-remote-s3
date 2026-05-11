// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Thin wrappers around the `git` command-line tool.
//!
//! Mirrors `git_remote_s3/git.py`.

use std::process::{Command, Stdio};

use regex::Regex;
use thiserror::Error;

/// Errors returned by git helper functions.
#[derive(Debug, Error)]
pub enum GitError {
    #[error("fatal: {0}")]
    Git(String),
    #[error("I/O error running git: {0}")]
    Io(#[from] std::io::Error),
}

/// Archive the content of `folder` into `<folder>/repo.zip` for the given ref.
///
/// Returns the path to the created archive file.
pub fn archive(folder: &str, ref_: &str) -> Result<String, GitError> {
    let file_path = format!("{}/repo.zip", folder);
    let output = Command::new("git")
        .args([
            "archive",
            "--format",
            "zip",
            "--output",
            &file_path,
            ref_,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if output.status.success() {
        Ok(file_path)
    } else {
        Err(GitError::Git(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ))
    }
}

/// Bundle `ref_` into `<folder>/<sha>.bundle`.
///
/// Returns the path to the created bundle file.
pub fn bundle(folder: &str, sha: &str, ref_: &str) -> Result<String, GitError> {
    let file_path = format!("{}/{}.bundle", folder, sha);
    let output = Command::new("git")
        .args(["bundle", "create", &file_path, ref_])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if output.status.success() {
        Ok(file_path)
    } else {
        Err(GitError::Git(
            String::from_utf8_lossy(&output.stderr).to_string(),
        ))
    }
}

/// Unbundle `<folder>/<sha>.bundle` and check out `ref_`.
pub fn unbundle(folder: &str, sha: &str, ref_: &str) -> Result<(), GitError> {
    // git bundle unbundle prints to stdout; mirror the Python version which
    // redirects stdout to stderr (sys.stderr).
    let status = Command::new("git")
        .args(["bundle", "unbundle", &format!("{}/{}.bundle", folder, sha), ref_])
        .stdout(Stdio::inherit()) // matches Python's `stdout=sys.stderr` (visible)
        .stderr(Stdio::inherit())
        .status()?;

    if status.success() {
        Ok(())
    } else {
        Err(GitError::Git(format!(
            "git bundle unbundle failed for {}/{}.bundle",
            folder, sha
        )))
    }
}

/// Resolve a ref to its SHA-1.
pub fn rev_parse(ref_: &str) -> Result<String, GitError> {
    let output = Command::new("git")
        .args(["rev-parse", ref_])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(GitError::Git(format!("fatal: {} not found", ref_)))
    }
}

/// Return `true` if `ancestor` is an ancestor of `descendant`.
pub fn is_ancestor(ancestor: &str, descendant: &str) -> bool {
    Command::new("git")
        .args(["merge-base", "--is-ancestor", ancestor, descendant])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Return the URL configured for `remote`.
pub fn get_remote_url(remote: &str) -> Result<String, GitError> {
    let output = Command::new("git")
        .args(["remote", "get-url", remote])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(GitError::Git(format!("fatal: {} not found", remote)))
    }
}

/// Validate a ref name according to git's own rules.
///
/// See <https://github.com/git/git/blob/406f326d271e0bacecdb00425422c5fa3f314930/refs.c#L170>
pub fn validate_ref_name(name: &str) -> bool {
    use std::sync::OnceLock;
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r"(^\.)|(\.\.)|([:\?\[\\\^\~\s\*\]])|(\.lock$)|(/$)|(@\{)|([\x00-\x1f])")
            .expect("hardcoded regex must compile")
    });
    re.is_match(name) == false
}

/// Return the short log of the last commit (`git log -1 --pretty=%h %s`).
pub fn get_last_commit_message() -> Result<String, GitError> {
    let output = Command::new("git")
        .args(["log", "-1", "--pretty=%h %s"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(GitError::Git("fatal: an error has occurred".to_owned()))
    }
}
