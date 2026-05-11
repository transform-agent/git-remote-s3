// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Core git-remote helper — S3Remote implementation.
//!
//! Mirrors `git_remote_s3/remote.py`.

use std::io::Read;
use std::path::Path;
use std::sync::{Arc, Mutex};

use aws_sdk_s3::error::SdkError;
use aws_sdk_s3::operation::put_object::PutObjectError;
use aws_sdk_s3::Client as S3Client;
use chrono::Utc;
use regex::Regex;
use tempfile::TempDir;
use thiserror::Error;
use tokio::task::JoinHandle;
use tracing::{info, warn};

use crate::enums::UriScheme;
use crate::git;

/// Default time-to-live for a ref lock, in seconds.
pub const DEFAULT_LOCK_TTL_SECONDS: u64 = 60;

// ── Custom errors ─────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum RemoteError {
    #[error("Bucket {bucket} not found.")]
    BucketNotFound { bucket: String },

    #[error("Not authorized to perform {action} on the S3 bucket {bucket}.")]
    NotAuthorized { action: String, bucket: String },

    #[error("AWS SDK error: {0}")]
    Sdk(String),

    #[error("Git error: {0}")]
    Git(#[from] git::GitError),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

impl<E: std::fmt::Debug + std::fmt::Display, R: std::fmt::Debug> From<SdkError<E, R>>
    for RemoteError
{
    fn from(e: SdkError<E, R>) -> Self {
        RemoteError::Sdk(e.to_string())
    }
}

// ── Mode ──────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Fetch,
    Push,
}

// ── Object metadata returned by list_objects_v2 ───────────────────────────────

#[derive(Debug, Clone)]
pub struct S3Object {
    pub key: String,
    pub last_modified: Option<chrono::DateTime<Utc>>,
}

// ── S3Remote ──────────────────────────────────────────────────────────────────

/// The core remote-helper state machine.
///
/// Corresponds to `class S3Remote` in `remote.py`.
pub struct S3Remote {
    pub uri_scheme: UriScheme,
    pub profile: Option<String>,
    pub bucket: String,
    pub prefix: String,
    pub s3: S3Client,
    pub mode: Option<Mode>,
    /// SHAs that have already been fetched in this session (dedup).
    pub fetched_refs: Arc<Mutex<Vec<String>>>,
    pub push_cmds: Vec<String>,
    pub fetch_cmds: Vec<String>,
    /// Lock TTL in seconds.
    pub lock_ttl_seconds: u64,
}

impl S3Remote {
    /// Create a new `S3Remote` and verify that the bucket is reachable.
    pub async fn new(
        s3: S3Client,
        uri_scheme: UriScheme,
        profile: Option<String>,
        bucket: String,
        prefix: String,
    ) -> Result<Self, RemoteError> {
        // Verify bucket access
        let result = s3
            .list_objects_v2()
            .bucket(&bucket)
            .prefix(&prefix)
            .send()
            .await;

        match result {
            Ok(_) => {}
            Err(SdkError::ServiceError(se)) => {
                let code = se.err().meta().code().unwrap_or("");
                if code == "NoSuchBucket" {
                    return Err(RemoteError::BucketNotFound {
                        bucket: bucket.clone(),
                    });
                }
                if code == "AccessDenied" {
                    return Err(RemoteError::NotAuthorized {
                        action: "ListObjectsV2".to_owned(),
                        bucket: bucket.clone(),
                    });
                }
                return Err(RemoteError::Sdk(se.err().to_string()));
            }
            Err(e) => return Err(RemoteError::Sdk(e.to_string())),
        }

        let lock_ttl_seconds = std::env::var("GIT_REMOTE_S3_LOCK_TTL_SECONDS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(DEFAULT_LOCK_TTL_SECONDS);

        Ok(S3Remote {
            uri_scheme,
            profile,
            bucket,
            prefix,
            s3,
            mode: None,
            fetched_refs: Arc::new(Mutex::new(Vec::new())),
            push_cmds: Vec::new(),
            fetch_cmds: Vec::new(),
            lock_ttl_seconds,
        })
    }

    // ── list_refs ─────────────────────────────────────────────────────────────

    /// List all bundle objects under `prefix` in `bucket`, sorted newest-first.
    pub async fn list_refs(&self, bucket: &str, prefix: &str) -> Vec<String> {
        let mut contents: Vec<S3Object> = Vec::new();
        let mut continuation_token: Option<String> = None;

        loop {
            let mut req = self.s3.list_objects_v2().bucket(bucket).prefix(prefix);
            if let Some(token) = continuation_token.take() {
                req = req.continuation_token(token);
            }
            let res = match req.send().await {
                Ok(r) => r,
                Err(e) => {
                    warn!("list_refs error: {}", e);
                    break;
                }
            };

            for obj in res.contents() {
                if let Some(key) = obj.key() {
                    let last_modified = obj
                        .last_modified()
                        .and_then(|t| {
                            chrono::DateTime::from_timestamp(t.secs(), t.subsec_nanos())
                        });
                    contents.push(S3Object {
                        key: key.to_owned(),
                        last_modified,
                    });
                }
            }

            if res.next_continuation_token().is_some() {
                continuation_token = res.next_continuation_token().map(str::to_owned);
            } else {
                break;
            }
        }

        // Sort newest-first (mirrors Python's reverse-sorted-by-LastModified)
        contents.sort_by(|a, b| b.last_modified.cmp(&a.last_modified));

        let prefix_slash = format!("{}/", prefix);
        contents
            .iter()
            .filter(|o| {
                o.key.starts_with(&format!("{}/refs", prefix)) && o.key.ends_with(".bundle")
            })
            .map(|o| {
                o.key
                    .strip_prefix(&prefix_slash)
                    .unwrap_or(&o.key)
                    .to_owned()
            })
            .collect()
    }

    // ── cmd_fetch ─────────────────────────────────────────────────────────────

    /// Execute a single `fetch <sha> <ref>` command.
    pub async fn cmd_fetch(&self, args: &str) -> Result<(), RemoteError> {
        let parts: Vec<&str> = args.splitn(3, ' ').collect();
        // args format: "fetch <sha> <ref>"
        let sha = parts.get(1).copied().unwrap_or("");
        let ref_ = parts.get(2).copied().unwrap_or("");

        {
            let refs = self.fetched_refs.lock().unwrap();
            if refs.contains(&sha.to_owned()) {
                return Ok(());
            }
        }
        info!("fetch {} {}", sha, ref_);

        let temp_dir = TempDir::new()?;
        let bundle_path = temp_dir.path().join(format!("{}.bundle", sha));

        // Download the bundle
        let result = self
            .s3
            .get_object()
            .bucket(&self.bucket)
            .key(format!("{}/{}/{}.bundle", self.prefix, ref_, sha))
            .send()
            .await;

        match result {
            Ok(resp) => {
                // Write body to file
                let mut body = resp.body.collect().await.map_err(|e| {
                    RemoteError::Sdk(e.to_string())
                })?;
                let bytes = body.into_bytes();
                std::fs::write(&bundle_path, &bytes)?;
            }
            Err(SdkError::ServiceError(se)) => {
                let code = se.err().meta().code().unwrap_or("");
                if code == "AccessDenied" {
                    return Err(RemoteError::NotAuthorized {
                        action: "GetObject".to_owned(),
                        bucket: self.bucket.clone(),
                    });
                }
                return Err(RemoteError::Sdk(se.err().to_string()));
            }
            Err(e) => return Err(RemoteError::Sdk(e.to_string())),
        }

        let folder = temp_dir.path().to_string_lossy().to_string();
        git::unbundle(&folder, sha, ref_)?;

        {
            let mut refs = self.fetched_refs.lock().unwrap();
            refs.push(sha.to_owned());
        }

        Ok(())
    }

    // ── remove_remote_ref ─────────────────────────────────────────────────────

    pub async fn remove_remote_ref(&self, remote_ref: &str) -> String {
        info!("Removing remote ref {}", remote_ref);
        let prefix = format!("{}/{}/", self.prefix, remote_ref);
        let objects_result = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await;

        let objects: Vec<String> = match objects_result {
            Ok(r) => r.contents().iter().filter_map(|o| o.key().map(str::to_owned)).collect(),
            Err(SdkError::ServiceError(se)) => {
                let code = se.err().meta().code().unwrap_or("");
                if code == "404" || code == "NoSuchKey" {
                    return format!("error {} not found\n", remote_ref);
                }
                return format!("error {} \"{}\"\n", remote_ref, se.err());
            }
            Err(e) => return format!("error {} \"{}\"\n", remote_ref, e),
        };

        // Filter out PROTECTED#, .zip and .lock objects to count real bundles
        let bundles: Vec<&String> = objects
            .iter()
            .filter(|k| {
                !k.contains("PROTECTED#")
                    && !k.ends_with(".zip")
                    && !k.contains("/LOCKS/")
                    && !k.ends_with(".lock")
            })
            .collect();

        let expected_count = match self.uri_scheme {
            UriScheme::S3 => 1,
            UriScheme::S3Zip => 2,
        };

        if bundles.len() == expected_count
            || (self.uri_scheme == UriScheme::S3 && objects.len() == 1)
            || (self.uri_scheme == UriScheme::S3Zip && objects.len() == 2)
        {
            for key in &objects {
                let _ = self
                    .s3
                    .delete_object()
                    .bucket(&self.bucket)
                    .key(key)
                    .send()
                    .await;
            }
            format!("ok {}\n", remote_ref)
        } else if objects.is_empty() {
            format!("error {} not found\n", remote_ref)
        } else {
            format!(
                "error {} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n",
                remote_ref
            )
        }
    }

    // ── cmd_push ──────────────────────────────────────────────────────────────

    pub async fn cmd_push(&self, args: &str) -> String {
        // args format: "push <local_ref>:<remote_ref>"
        let rest = args.trim_start_matches("push ");
        let mut force_push = false;

        let (local_ref_raw, remote_ref) = match rest.split_once(':') {
            Some(pair) => pair,
            None => return format!("error  \"invalid push command\"\n"),
        };

        if local_ref_raw.is_empty() {
            return self.remove_remote_ref(remote_ref).await;
        }

        let local_ref = if local_ref_raw.starts_with('+') {
            let lref = &local_ref_raw[1..];
            let protected = self.is_protected(remote_ref).await;
            force_push = !protected;
            info!("Force push {}", force_push);
            lref
        } else {
            local_ref_raw
        };

        info!("push !{}! !{}!", local_ref, remote_ref);

        let temp_dir = match TempDir::new() {
            Ok(d) => d,
            Err(e) => return format!("error {} \"{}\"\n", remote_ref, e),
        };
        let folder = temp_dir.path().to_string_lossy().to_string();

        // Check current remote state
        let contents = self.get_bundles_for_ref(remote_ref).await;
        if contents.len() > 1 {
            return format!(
                "error {} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n",
                remote_ref
            );
        }

        let remote_to_remove: Option<String> =
            contents.first().map(|o| o.key.clone());

        // Resolve local ref to SHA
        let sha = match git::rev_parse(local_ref) {
            Ok(s) => s,
            Err(_) => {
                info!("fatal: {} not found", local_ref);
                return format!("error {} \"{} not found\"?\n", remote_ref, local_ref);
            }
        };

        // Ancestor check
        if let Some(ref rtr) = remote_to_remove {
            let remote_sha = rtr
                .split('/')
                .last()
                .unwrap_or("")
                .split('.')
                .next()
                .unwrap_or("");
            if !force_push && !git::is_ancestor(remote_sha, &sha) {
                return format!(
                    "error {} \"remote ref is not ancestor of {}.\"?\n",
                    remote_ref, local_ref
                );
            }
        }

        // Create bundle before acquiring lock (local op)
        let temp_file = match git::bundle(&folder, &sha, local_ref) {
            Ok(p) => p,
            Err(e) => {
                info!("fatal: {}", e);
                return format!("error {} \"{} not found\"?\n", remote_ref, local_ref);
            }
        };

        // Acquire per-ref lock
        let lock_key = match self.acquire_lock(remote_ref).await {
            Some(k) => k,
            None => {
                let lock_path = format!("{}/{}/LOCK#.lock", self.prefix, remote_ref);
                return format!(
                    "error {} \"failed to acquire ref lock at {}. Another client may be pushing. If this persists beyond {}s, run git-remote-s3 doctor --lock-ttl {} to inspect and optionally clear stale locks.\"?\n",
                    remote_ref, lock_path, self.lock_ttl_seconds, self.lock_ttl_seconds
                );
            }
        };

        // Re-check remote state after acquiring lock
        let current_contents = self.get_bundles_for_ref(remote_ref).await;
        if current_contents.len() > 1 {
            let _ = self.release_lock(remote_ref, &lock_key).await;
            return format!(
                "error {} \"multiple bundles exists for the same ref on server. Run git-s3 doctor to fix. Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n",
                remote_ref
            );
        }
        let current_remote_to_remove: Option<String> =
            current_contents.first().map(|o| o.key.clone());

        if let (Some(ref orig), Some(ref curr)) = (&remote_to_remove, &current_remote_to_remove) {
            if orig != curr {
                let _ = self.release_lock(remote_ref, &lock_key).await;
                return format!(
                    "error {} \"stale remote. Please fetch and retry.\"?\n",
                    remote_ref
                );
            }
        }

        // Upload the bundle
        let bundle_bytes = match std::fs::read(&temp_file) {
            Ok(b) => b,
            Err(e) => {
                let _ = self.release_lock(remote_ref, &lock_key).await;
                return format!("error {} \"{}\"\n", remote_ref, e);
            }
        };

        let upload_result = self
            .s3
            .put_object()
            .bucket(&self.bucket)
            .key(format!("{}/{}/{}.bundle", self.prefix, remote_ref, sha))
            .body(bundle_bytes.into())
            .send()
            .await;

        if let Err(e) = upload_result {
            let _ = self.release_lock(remote_ref, &lock_key).await;
            return format!("error {} \"{}\"\n", remote_ref, e);
        }

        // Initialise HEAD if necessary
        self.init_remote_head(remote_ref).await;

        // Remove old bundle
        if let Some(ref old_key) = remote_to_remove {
            let _ = self
                .s3
                .delete_object()
                .bucket(&self.bucket)
                .key(old_key)
                .send()
                .await;
        }

        // Optional zip archive for S3_ZIP scheme
        if self.uri_scheme == UriScheme::S3Zip {
            let commit_msg = git::get_last_commit_message().unwrap_or_default();
            match git::archive(&folder, local_ref) {
                Ok(archive_path) => {
                    if let Ok(archive_bytes) = std::fs::read(&archive_path) {
                        let _ = self
                            .s3
                            .put_object()
                            .bucket(&self.bucket)
                            .key(format!("{}/{}/repo.zip", self.prefix, remote_ref))
                            .body(archive_bytes.into())
                            .metadata(
                                "codepipeline-artifact-revision-summary",
                                &commit_msg,
                            )
                            .content_disposition(format!(
                                "attachment; filename=repo-{}.zip",
                                &sha[..8]
                            ))
                            .send()
                            .await;
                    }
                }
                Err(e) => warn!("archive failed: {}", e),
            }
        }

        // Release lock
        if let Err(e) = self.release_lock(remote_ref, &lock_key).await {
            return format!(
                "error {} \"failed to release lock. You may need to manually remove the lock {} from the server or use git-s3 doctor to fix.\"\n",
                remote_ref, lock_key
            );
        }

        format!("ok {}\n", remote_ref)
    }

    // ── init_remote_head ─────────────────────────────────────────────────────

    async fn init_remote_head(&self, ref_: &str) {
        let key = format!("{}/HEAD", self.prefix);
        let head_exists = self
            .s3
            .head_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await
            .is_ok();

        if !head_exists {
            let _ = self
                .s3
                .put_object()
                .bucket(&self.bucket)
                .key(&key)
                .body(ref_.as_bytes().to_vec().into())
                .send()
                .await;
        }
    }

    // ── get_bundles_for_ref ───────────────────────────────────────────────────

    /// List real bundle objects for `remote_ref` (excludes PROTECTED#, .zip, .lock).
    pub async fn get_bundles_for_ref(&self, remote_ref: &str) -> Vec<S3Object> {
        let prefix = format!("{}/{}/", self.prefix, remote_ref);
        let res = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await;

        match res {
            Ok(r) => r
                .contents()
                .iter()
                .filter(|o| {
                    let key = o.key().unwrap_or("");
                    !key.contains("PROTECTED#")
                        && !key.ends_with(".zip")
                        && !key.contains("/LOCKS/")
                        && !key.ends_with(".lock")
                })
                .map(|o| {
                    let last_modified = o.last_modified().and_then(|t| {
                        chrono::DateTime::from_timestamp(t.secs(), t.subsec_nanos())
                    });
                    S3Object {
                        key: o.key().unwrap_or("").to_owned(),
                        last_modified,
                    }
                })
                .collect(),
            Err(_) => Vec::new(),
        }
    }

    // ── is_protected ─────────────────────────────────────────────────────────

    pub async fn is_protected(&self, remote_ref: &str) -> bool {
        let prefix = format!("{}/{}/PROTECTED#", self.prefix, remote_ref);
        let res = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await;
        res.map(|r| !r.contents().is_empty()).unwrap_or(false)
    }

    // ── acquire_lock ──────────────────────────────────────────────────────────

    /// Attempt to acquire a per-ref lock using S3 conditional writes.
    ///
    /// Returns the lock key on success, or `None` if the lock could not be
    /// acquired (e.g. another client holds a fresh lock).
    pub async fn acquire_lock(&self, remote_ref: &str) -> Option<String> {
        let lock_key = format!("{}/{}/LOCK#.lock", self.prefix, remote_ref);

        // Try conditional put (IfNoneMatch: "*")
        let result = self
            .s3
            .put_object()
            .bucket(&self.bucket)
            .key(&lock_key)
            .body(bytes::Bytes::new().into())
            .if_none_match("*")
            .send()
            .await;

        match result {
            Ok(_) => return Some(lock_key),
            Err(SdkError::ServiceError(se)) => {
                // 412 PreconditionFailed: lock already exists
                let code = se.err().meta().code().unwrap_or("");
                let status = se.raw().status().as_u16();
                if code == "PreconditionFailed" || code == "412" || status == 412 {
                    // Check staleness
                    match self
                        .s3
                        .head_object()
                        .bucket(&self.bucket)
                        .key(&lock_key)
                        .send()
                        .await
                    {
                        Ok(head) => {
                            if let Some(lm) = head.last_modified() {
                                let last_modified_ts = chrono::DateTime::from_timestamp(
                                    lm.secs(),
                                    lm.subsec_nanos(),
                                )
                                .unwrap_or_else(Utc::now);
                                let age =
                                    (Utc::now() - last_modified_ts).num_seconds() as u64;
                                if age > self.lock_ttl_seconds {
                                    // Stale — delete and retry
                                    let _ = self
                                        .s3
                                        .delete_object()
                                        .bucket(&self.bucket)
                                        .key(&lock_key)
                                        .send()
                                        .await;
                                    // Retry conditional put
                                    let retry = self
                                        .s3
                                        .put_object()
                                        .bucket(&self.bucket)
                                        .key(&lock_key)
                                        .body(bytes::Bytes::new().into())
                                        .if_none_match("*")
                                        .send()
                                        .await;
                                    if retry.is_ok() {
                                        return Some(lock_key);
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            info!("failed to check staleness of {}: {}", lock_key, e);
                        }
                    }
                    None
                } else {
                    info!("acquire_lock error: {}", se.err());
                    None
                }
            }
            Err(e) => {
                info!("acquire_lock error: {}", e);
                None
            }
        }
    }

    // ── release_lock ──────────────────────────────────────────────────────────

    pub async fn release_lock(
        &self,
        remote_ref: &str,
        lock_key: &str,
    ) -> Result<(), RemoteError> {
        let result = self
            .s3
            .delete_object()
            .bucket(&self.bucket)
            .key(lock_key)
            .send()
            .await;

        match result {
            Ok(_) => Ok(()),
            Err(SdkError::ServiceError(se)) => {
                let status = se.raw().status().as_u16();
                if status == 404 {
                    info!("lock {} already released", lock_key);
                    Ok(())
                } else {
                    Err(RemoteError::Sdk(se.err().to_string()))
                }
            }
            Err(e) => Err(RemoteError::Sdk(e.to_string())),
        }
    }

    // ── cmd_option ────────────────────────────────────────────────────────────

    pub fn cmd_option(&self, arg: &str) {
        // arg format: "option <name> <value>"
        let parts: Vec<&str> = arg.splitn(3, ' ').collect();
        let option = parts.get(1).copied().unwrap_or("");
        let value = parts.get(2).copied().unwrap_or("");

        if option == "verbosity" {
            if value.parse::<i32>().unwrap_or(0) >= 2 {
                // Increase log level; tracing subscriber is already initialised.
                // We print "ok" to indicate the option is supported.
                print!("ok\n");
            } else {
                print!("unsupported\n");
            }
        } else {
            print!("unsupported\n");
        }
        use std::io::Write;
        std::io::stdout().flush().ok();
    }

    // ── get_remote_head ───────────────────────────────────────────────────────

    pub async fn get_remote_head(&self) -> Result<String, RemoteError> {
        let resp = self
            .s3
            .get_object()
            .bucket(&self.bucket)
            .key(format!("{}/HEAD", self.prefix))
            .send()
            .await
            .map_err(|e| RemoteError::Sdk(e.to_string()))?;

        let bytes = resp
            .body
            .collect()
            .await
            .map_err(|e| RemoteError::Sdk(e.to_string()))?
            .into_bytes();

        Ok(String::from_utf8_lossy(&bytes).trim().to_owned())
    }

    // ── cmd_list ──────────────────────────────────────────────────────────────

    pub async fn cmd_list(&self, for_push: bool) {
        use std::io::Write;
        let objs = self.list_refs(&self.bucket, &self.prefix).await;
        info!("{:?}", objs);

        if !for_push {
            match self.get_remote_head().await {
                Ok(head) => {
                    info!("HEAD=[{}]", head);
                    for o in &objs {
                        let ref_ = o.rsplitn(2, '/').nth(1).unwrap_or("").to_owned();
                        // ref_ is e.g. "refs/heads/main"
                        let ref_short = o.split('/').take(o.split('/').count().saturating_sub(1)).collect::<Vec<_>>().join("/");
                        if ref_short == head || ref_ == head {
                            info!("@{} HEAD", ref_short);
                            print!("@{} HEAD\n", ref_short);
                        }
                    }
                }
                Err(e) => {
                    // NoSuchKey → silently ignore
                    info!("get_remote_head error (ignored): {}", e);
                }
            }
        }

        // Regex: full path must match .+/.+/.+/<40-hex>.bundle
        use std::sync::OnceLock;
        static RE: OnceLock<Regex> = OnceLock::new();
        let re = RE.get_or_init(|| {
            Regex::new(r".+/.+/.+/[a-f0-9]{40}\.bundle").expect("must compile")
        });

        for o in objs.iter().filter(|o| re.is_match(o)) {
            let elements: Vec<&str> = o.split('/').collect();
            let sha = elements.last().unwrap_or(&"").split('.').next().unwrap_or("");
            let ref_ = elements[..elements.len() - 1].join("/");
            print!("{} {}\n", sha, ref_);
        }

        print!("\n");
        std::io::stdout().flush().ok();
    }

    // ── cmd_capabilities ─────────────────────────────────────────────────────

    pub fn cmd_capabilities(&self) {
        use std::io::Write;
        print!("*push\n*fetch\noption\n\n");
        std::io::stdout().flush().ok();
    }

    // ── process_fetch_cmds ────────────────────────────────────────────────────

    /// Run all collected fetch commands in parallel using `tokio::task::spawn`.
    pub async fn process_fetch_cmds(&self, cmds: Vec<String>) {
        if cmds.is_empty() {
            return;
        }
        info!("Processing {} fetch commands in parallel", cmds.len());

        // Wrap self in an Arc so we can share across tasks.
        // Because we cannot move `self` (borrowed), we use a raw pointer approach
        // guarded by the fact that self outlives all tasks here.
        //
        // Safety: `self` is borrowed for the duration of this function and all
        // tasks are joined before the function returns.
        let ptr = self as *const S3Remote as usize;
        let handles: Vec<JoinHandle<()>> = cmds
            .into_iter()
            .map(|cmd| {
                tokio::spawn(async move {
                    // SAFETY: see comment above.
                    let remote = unsafe { &*(ptr as *const S3Remote) };
                    if let Err(e) = remote.cmd_fetch(&cmd).await {
                        warn!("fetch error: {}", e);
                    }
                })
            })
            .collect();

        for h in handles {
            let _ = h.await;
        }

        info!("Completed processing fetch commands in parallel");
    }

    // ── process_cmd ───────────────────────────────────────────────────────────

    /// Dispatch a single line from stdin.
    pub async fn process_cmd(&mut self, cmd: &str) {
        use std::io::Write;

        if cmd.starts_with("fetch") {
            if self.mode != Some(Mode::Fetch) {
                self.mode = Some(Mode::Fetch);
                self.fetch_cmds.clear();
            }
            self.fetch_cmds.push(cmd.trim().to_owned());
        } else if cmd.starts_with("push") {
            if self.mode != Some(Mode::Push) {
                self.mode = Some(Mode::Push);
                self.push_cmds.clear();
            }
            self.push_cmds.push(cmd.trim().to_owned());
        } else if cmd.starts_with("option") {
            self.cmd_option(cmd.trim());
        } else if cmd.starts_with("list for-push") {
            self.cmd_list(true).await;
        } else if cmd.starts_with("list") {
            self.cmd_list(false).await;
        } else if cmd.starts_with("capabilities") {
            self.cmd_capabilities();
        } else if cmd == "\n" || cmd.trim().is_empty() {
            info!("empty line");
            if self.mode == Some(Mode::Push) && !self.push_cmds.is_empty() {
                info!("pushing {:?}", self.push_cmds);
                let cmds = std::mem::take(&mut self.push_cmds);
                for c in &cmds {
                    let res = self.cmd_push(c).await;
                    print!("{}", res);
                }
                self.push_cmds.clear();
            } else if self.mode == Some(Mode::Fetch) && !self.fetch_cmds.is_empty() {
                info!("fetching {} refs in parallel", self.fetch_cmds.len());
                let cmds = std::mem::take(&mut self.fetch_cmds);
                self.process_fetch_cmds(cmds).await;
                self.fetch_cmds.clear();
            }
            print!("\n");
            std::io::stdout().flush().ok();
        } else {
            eprintln!("fatal: invalid command '{}'", cmd.trim());
            std::process::exit(1);
        }
    }
}
