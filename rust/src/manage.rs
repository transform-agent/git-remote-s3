// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Repository management utilities — Doctor and ManageBranch.
//!
//! Mirrors `git_remote_s3/manage.py`.

use std::collections::HashMap;
use std::io::{self, BufRead, Write};

use aws_sdk_s3::Client as S3Client;
use chrono::Utc;
use uuid::Uuid;

use crate::remote::DEFAULT_LOCK_TTL_SECONDS;

// ── Data structures ───────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct BundleInfo {
    pub sha: String,
    pub last_modified: Option<chrono::DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct RefInfo {
    pub protected: bool,
    pub bundles: Vec<BundleInfo>,
}

#[derive(Debug, Clone)]
pub struct RepoInfo {
    pub refs: HashMap<String, RefInfo>,
    pub head: String,
}

// ── Doctor ────────────────────────────────────────────────────────────────────

/// Analyse and fix a git-remote-s3 repository stored in S3.
///
/// Corresponds to `class Doctor` in `manage.py`.
pub struct Doctor {
    pub bucket: String,
    pub prefix: String,
    pub delete_bundle: bool,
    pub s3: S3Client,
    pub lock_ttl_seconds: u64,
    pub delete_stale_locks: bool,
}

impl Doctor {
    pub fn new(
        s3: S3Client,
        bucket: String,
        prefix: String,
        delete_bundle: bool,
        lock_ttl_seconds: u64,
        delete_stale_locks: bool,
    ) -> Self {
        Doctor {
            bucket,
            prefix,
            delete_bundle,
            s3,
            lock_ttl_seconds,
            delete_stale_locks,
        }
    }

    pub async fn run(&self) {
        let repos = self.analyze_repo().await;
        for (r, repo_info) in &repos {
            println!("{}:", r);
            let mut head_ref = "Invalid".to_owned();
            for (ref_, ref_info) in &repo_info.refs {
                if repo_info.head == *ref_ {
                    head_ref = ref_.clone();
                }
                let part1 = if ref_info.protected { "*" } else { "" };
                let part2 = if ref_info.bundles.len() == 1 {
                    "Ok"
                } else {
                    "Multiple refs"
                };
                println!(" {} {}: {}", part1, ref_, part2);
            }
            if head_ref == "Invalid" {
                // head_ref stays "Invalid"
            }
            println!("  HEAD: {}", head_ref);
        }

        self.fix_issues(repos).await;
    }

    pub async fn fix_issues(&self, mut repos: HashMap<String, RepoInfo>) {
        for (r, repo_info) in &repos {
            for (ref_, ref_info) in &repo_info.refs {
                if ref_info.bundles.len() > 1 {
                    self.fix_multiple_bundles(&repos, r, ref_).await;
                }
            }
            if repo_info.head == "Invalid" || repo_info.head == "Missing" {
                self.fix_head(&repos, r).await;
            }
        }

        self.list_and_handle_stale_locks().await;
    }

    pub async fn list_and_handle_stale_locks(&self) {
        println!("\nScanning for stale locks...");

        let prefix = format!("{}/", self.prefix);
        let objs = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await
            .map(|r| r.contents().iter().map(|o| {
                let key = o.key().unwrap_or("").to_owned();
                let lm = o.last_modified().and_then(|t| {
                    chrono::DateTime::from_timestamp(t.secs(), t.subsec_nanos())
                });
                (key, lm)
            }).collect::<Vec<_>>())
            .unwrap_or_default();

        let now = Utc::now();
        let mut stale: Vec<(String, i64)> = Vec::new();
        for (key, lm) in &objs {
            if key.ends_with(".lock") {
                if let Some(last_modified) = lm {
                    let age = (now - *last_modified).num_seconds();
                    if age > self.lock_ttl_seconds as i64 {
                        stale.push((key.clone(), age));
                    }
                }
            }
        }

        if stale.is_empty() {
            println!("No stale locks found.");
            return;
        }

        println!("Found stale locks:");
        for (key, age) in &stale {
            println!(" - {} (age: {}s)", key, age);
        }

        if self.delete_stale_locks {
            println!("\nDeleting stale locks...");
            for (key, _) in &stale {
                match self
                    .s3
                    .delete_object()
                    .bucket(&self.bucket)
                    .key(key)
                    .send()
                    .await
                {
                    Ok(_) => println!("Deleted {}", key),
                    Err(e) => println!("Failed to delete {}: {}", key, e),
                }
            }
        } else {
            println!("\nRun with --delete-stale-locks to remove them automatically.");
        }
    }

    pub async fn analyze_repo(&self) -> HashMap<String, RepoInfo> {
        let prefix = format!("{}/", self.prefix);
        let objs = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await
            .map(|r| r.contents().iter().map(|o| {
                let key = o.key().unwrap_or("").to_owned();
                let lm = o.last_modified().and_then(|t| {
                    chrono::DateTime::from_timestamp(t.secs(), t.subsec_nanos())
                });
                (key, lm)
            }).collect::<Vec<_>>())
            .unwrap_or_default();

        let mut repos: HashMap<String, RepoInfo> = HashMap::new();

        for (key, last_modified) in &objs {
            let key_parts: Vec<&str> = key.split('/').collect();
            if key_parts.is_empty() {
                continue;
            }
            let repo_name = key_parts[0].to_owned();
            let repo = repos.entry(repo_name.clone()).or_insert_with(|| RepoInfo {
                refs: HashMap::new(),
                head: "Missing".to_owned(),
            });

            if key_parts.len() < 2 {
                continue;
            }

            if key_parts[1] == "HEAD" {
                // Read HEAD content
                let head_content = self
                    .s3
                    .get_object()
                    .bucket(&self.bucket)
                    .key(key)
                    .send()
                    .await
                    .ok();
                if let Some(resp) = head_content {
                    if let Ok(data) = resp.body.collect().await {
                        let s = String::from_utf8_lossy(&data.into_bytes()).trim().to_owned();
                        repo.head = s;
                    }
                }
                continue;
            }

            let refs = key_parts[1..key_parts.len() - 1].join("/");
            let ref_info = repo.refs.entry(refs).or_insert_with(|| RefInfo {
                protected: false,
                bundles: Vec::new(),
            });

            let last_part = key_parts.last().unwrap_or(&"");
            if *last_part == "PROTECTED#" {
                ref_info.protected = true;
            } else {
                let sha = last_part.split('.').next().unwrap_or("").to_owned();
                if !sha.is_empty() {
                    ref_info.bundles.push(BundleInfo {
                        sha,
                        last_modified: *last_modified,
                    });
                }
            }
        }

        repos
    }

    pub async fn fix_multiple_bundles(
        &self,
        repos: &HashMap<String, RepoInfo>,
        r: &str,
        ref_: &str,
    ) {
        println!("\nFix multiple bundles for repo {} and ref {}", r, ref_);
        let bundles = &repos[r].refs[ref_].bundles;
        for (i, b) in bundles.iter().enumerate() {
            let lm = b
                .last_modified
                .map(|t| t.to_rfc3339())
                .unwrap_or_default();
            println!("{}. {} {}", i + 1, b.sha, lm);
        }

        let stdin = io::stdin();
        loop {
            print!("Enter the number of the bundle to keep: ");
            io::stdout().flush().ok();
            let mut line = String::new();
            if stdin.lock().read_line(&mut line).is_err() {
                break;
            }
            match line.trim().parse::<usize>() {
                Ok(i) if i > 0 && i <= bundles.len() => {
                    let keep_sha = bundles[i - 1].sha.clone();
                    println!("Keeping {}", keep_sha);
                    print!("Press enter to confirm or Ctrl+C to cancel: ");
                    io::stdout().flush().ok();
                    let mut confirm = String::new();
                    let _ = stdin.lock().read_line(&mut confirm);

                    for bundle in bundles {
                        if bundle.sha != keep_sha {
                            if self.delete_bundle {
                                println!("Removing {}", bundle.sha);
                                let _ = self
                                    .s3
                                    .delete_object()
                                    .bucket(&self.bucket)
                                    .key(format!(
                                        "{}/{}/{}.bundle",
                                        self.prefix, ref_, bundle.sha
                                    ))
                                    .send()
                                    .await;
                            } else {
                                let tmp_branch =
                                    format!("{}_{}", ref_, &Uuid::new_v4().to_string()[..8]);
                                println!("Moving {} to new branch {}", bundle.sha, tmp_branch);
                                let _ = self
                                    .s3
                                    .copy_object()
                                    .bucket(&self.bucket)
                                    .copy_source(format!(
                                        "{}/{}/{}/{}.bundle",
                                        self.bucket, self.prefix, ref_, bundle.sha
                                    ))
                                    .key(format!(
                                        "{}/{}/{}.bundle",
                                        self.prefix, tmp_branch, bundle.sha
                                    ))
                                    .send()
                                    .await;
                                let _ = self
                                    .s3
                                    .delete_object()
                                    .bucket(&self.bucket)
                                    .key(format!(
                                        "{}/{}/{}.bundle",
                                        self.prefix, ref_, bundle.sha
                                    ))
                                    .send()
                                    .await;
                            }
                        }
                    }
                    break;
                }
                _ => println!("Invalid input"),
            }
        }
    }

    pub async fn fix_head(&self, repos: &HashMap<String, RepoInfo>, r: &str) {
        println!("\nFix invalid HEAD for repo {}", r);
        let heads: Vec<String> = repos[r]
            .refs
            .keys()
            .filter(|k| k.contains("heads"))
            .cloned()
            .collect();

        for (i, head) in heads.iter().enumerate() {
            let branch = head.split('/').last().unwrap_or(head);
            println!("{}. {}", i + 1, branch);
        }

        let stdin = io::stdin();
        loop {
            print!("Enter the number of the branch to use as head: ");
            io::stdout().flush().ok();
            let mut line = String::new();
            if stdin.lock().read_line(&mut line).is_err() {
                break;
            }
            match line.trim().parse::<usize>() {
                Ok(i) if i > 0 && i <= heads.len() => {
                    let head = &heads[i - 1];
                    println!("Setting {} as HEAD", head);
                    let _ = self
                        .s3
                        .put_object()
                        .bucket(&self.bucket)
                        .key(format!("{}/HEAD", self.prefix))
                        .body(head.as_bytes().to_vec().into())
                        .send()
                        .await;
                    break;
                }
                _ => println!("Invalid input"),
            }
        }
    }
}

// ── ManageBranch ──────────────────────────────────────────────────────────────

pub struct ManageBranch {
    pub bucket: String,
    pub prefix: String,
    pub s3: S3Client,
    pub branch: String,
}

impl ManageBranch {
    pub async fn new(
        s3: S3Client,
        bucket: String,
        prefix: String,
        branch: String,
    ) -> Result<Self, String> {
        let mb = ManageBranch {
            bucket,
            prefix,
            s3,
            branch: branch.clone(),
        };
        let content = mb.get_branch_content().await;
        if content.is_empty() {
            return Err(format!("Branch {} does not exist", branch));
        }
        Ok(mb)
    }

    pub async fn process_cmd(&self, cmd: &str) {
        match cmd {
            "delete-branch" => self.delete_branch().await,
            "protect" => self.protect_branch().await,
            "unprotect" => self.unprotect_branch().await,
            _ => {}
        }
    }

    pub async fn delete_branch(&self) {
        let objs = self.get_branch_content().await;
        print!("Delete {} branch [yes/no]: ", self.branch);
        io::stdout().flush().ok();
        let mut resp = String::new();
        io::stdin().lock().read_line(&mut resp).ok();
        if resp.trim().to_lowercase() == "yes" {
            for key in objs {
                let _ = self
                    .s3
                    .delete_object()
                    .bucket(&self.bucket)
                    .key(&key)
                    .send()
                    .await;
            }
            println!("Branch {} has been deleted", self.branch);
        } else {
            println!("Aborted");
        }
    }

    pub async fn get_branch_content(&self) -> Vec<String> {
        let prefix = format!("{}/refs/heads/{}/", self.prefix, self.branch);
        self.s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&prefix)
            .send()
            .await
            .map(|r| {
                r.contents()
                    .iter()
                    .filter_map(|o| o.key().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub async fn protect_branch(&self) {
        let key = format!("{}/refs/heads/{}/PROTECTED#", self.prefix, self.branch);
        let _ = self
            .s3
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .body(vec![].into())
            .send()
            .await;
        println!("Branch {} is now protected", self.branch);
    }

    pub async fn unprotect_branch(&self) {
        let key = format!("{}/refs/heads/{}/PROTECTED#", self.prefix, self.branch);
        let _ = self
            .s3
            .delete_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await;
        println!("Branch {} is now unprotected", self.branch);
    }
}
