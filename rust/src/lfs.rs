// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Git LFS custom-transfer agent for S3.
//!
//! Mirrors `git_remote_s3/lfs.py`.

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use aws_sdk_s3::Client as S3Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::{debug, error};

use crate::common::parse_git_url;
use crate::git::validate_ref_name;

// ── JSON event types ──────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct LfsEvent {
    event: String,
    #[serde(default)]
    remote: Option<String>,
    #[serde(default)]
    oid: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    size: Option<u64>,
}

#[derive(Debug, Serialize)]
struct ProgressEvent<'a> {
    event: &'a str,
    oid: &'a str,
    #[serde(rename = "bytesSoFar")]
    bytes_so_far: u64,
    #[serde(rename = "bytesSinceLast")]
    bytes_since_last: u64,
}

#[derive(Debug, Serialize)]
struct CompleteEvent<'a> {
    event: &'a str,
    oid: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<LfsError<'a>>,
}

#[derive(Debug, Serialize)]
struct LfsError<'a> {
    code: i32,
    message: &'a str,
}

fn write_error_event(oid: &str, error_msg: &str) {
    let ev = CompleteEvent {
        event: "complete",
        oid,
        path: None,
        error: Some(LfsError {
            code: 2,
            message: error_msg,
        }),
    };
    println!("{}", serde_json::to_string(&ev).unwrap_or_default());
}

// ── LFSProcess ────────────────────────────────────────────────────────────────

pub struct LFSProcess {
    pub prefix: String,
    pub bucket: String,
    pub profile: Option<String>,
    pub s3: S3Client,
}

impl LFSProcess {
    pub async fn new(s3uri: &str) -> Option<Self> {
        let parsed = match parse_git_url(s3uri) {
            Some(p) if p.bucket != "" => p,
            _ => {
                error!("s3 uri {} is invalid", s3uri);
                let ev = serde_json::json!({
                    "error": {"code": 32, "message": format!("s3 uri {} is invalid", s3uri)}
                });
                println!("{}", ev);
                std::io::stdout().flush().ok();
                return None;
            }
        };

        if parsed.prefix.is_none() {
            error!("s3 uri {} has no prefix", s3uri);
            let ev = serde_json::json!({
                "error": {"code": 32, "message": format!("s3 uri {} is invalid", s3uri)}
            });
            println!("{}", ev);
            std::io::stdout().flush().ok();
            return None;
        }

        let config = if let Some(ref profile) = parsed.profile {
            aws_config::from_env()
                .profile_name(profile)
                .load()
                .await
        } else {
            aws_config::load_from_env().await
        };

        let s3 = S3Client::new(&config);

        // Acknowledge init
        println!("{{}}");
        std::io::stdout().flush().ok();

        Some(LFSProcess {
            prefix: parsed.prefix.unwrap(),
            bucket: parsed.bucket,
            profile: parsed.profile,
            s3,
        })
    }

    pub async fn upload(&self, event: &LfsEvent) {
        debug!("upload");
        let oid = match &event.oid {
            Some(o) => o.clone(),
            None => {
                write_error_event("", "missing oid");
                return;
            }
        };
        let path = match &event.path {
            Some(p) => p.clone(),
            None => {
                write_error_event(&oid, "missing path");
                return;
            }
        };

        // Check if object already exists
        let key = format!("{}/lfs/{}", self.prefix, oid);
        let exists = self
            .s3
            .list_objects_v2()
            .bucket(&self.bucket)
            .prefix(&key)
            .send()
            .await
            .map(|r| !r.contents().is_empty())
            .unwrap_or(false);

        if exists {
            debug!("object already exists");
            let ev = serde_json::json!({"event": "complete", "oid": oid});
            println!("{}", ev);
            std::io::stdout().flush().ok();
            return;
        }

        // Upload
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                error!("{}", e);
                write_error_event(&oid, &e.to_string());
                std::io::stdout().flush().ok();
                return;
            }
        };

        let total = bytes.len() as u64;
        let result = self
            .s3
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .body(bytes.into())
            .send()
            .await;

        match result {
            Ok(_) => {
                // Emit a final progress + complete
                let prog = ProgressEvent {
                    event: "progress",
                    oid: &oid,
                    bytes_so_far: total,
                    bytes_since_last: total,
                };
                println!("{}", serde_json::to_string(&prog).unwrap_or_default());
                let ev = serde_json::json!({"event": "complete", "oid": oid});
                println!("{}", ev);
            }
            Err(e) => {
                error!("{}", e);
                write_error_event(&oid, &e.to_string());
            }
        }
        std::io::stdout().flush().ok();
    }

    pub async fn download(&self, event: &LfsEvent) {
        debug!("download");
        let oid = match &event.oid {
            Some(o) => o.clone(),
            None => {
                write_error_event("", "missing oid");
                return;
            }
        };

        let temp_dir = std::path::Path::new(".git/lfs/tmp");
        let dest_path = temp_dir.join(&oid);
        let key = format!("{}/lfs/{}", self.prefix, oid);

        let result = self
            .s3
            .get_object()
            .bucket(&self.bucket)
            .key(&key)
            .send()
            .await;

        match result {
            Ok(resp) => {
                match resp.body.collect().await {
                    Ok(data) => {
                        let bytes = data.into_bytes();
                        let total = bytes.len() as u64;
                        if let Err(e) = std::fs::write(&dest_path, &bytes) {
                            error!("{}", e);
                            write_error_event(&oid, &e.to_string());
                        } else {
                            // Progress
                            let prog = ProgressEvent {
                                event: "progress",
                                oid: &oid,
                                bytes_so_far: total,
                                bytes_since_last: total,
                            };
                            println!("{}", serde_json::to_string(&prog).unwrap_or_default());
                            // Complete
                            let done = CompleteEvent {
                                event: "complete",
                                oid: &oid,
                                path: Some(dest_path.to_str().unwrap_or("")),
                                error: None,
                            };
                            println!("{}", serde_json::to_string(&done).unwrap_or_default());
                        }
                    }
                    Err(e) => {
                        error!("{}", e);
                        write_error_event(&oid, &e.to_string());
                    }
                }
            }
            Err(e) => {
                error!("{}", e);
                write_error_event(&oid, &e.to_string());
            }
        }
        std::io::stdout().flush().ok();
    }
}

// ── install ───────────────────────────────────────────────────────────────────

pub fn install() {
    let r1 = std::process::Command::new("git")
        .args([
            "config",
            "--add",
            "lfs.customtransfer.git-lfs-s3.path",
            "git-lfs-s3",
        ])
        .status();
    if !r1.map(|s| s.success()).unwrap_or(false) {
        eprintln!("Failed to configure lfs.customtransfer.git-lfs-s3.path");
        std::process::exit(1);
    }

    let r2 = std::process::Command::new("git")
        .args([
            "config",
            "--add",
            "lfs.standalonetransferagent",
            "git-lfs-s3",
        ])
        .status();
    if !r2.map(|s| s.success()).unwrap_or(false) {
        eprintln!("Failed to configure lfs.standalonetransferagent");
        std::process::exit(1);
    }

    println!("git-lfs-s3 installed");
    std::io::stdout().flush().ok();
}

// ── main (async) ──────────────────────────────────────────────────────────────

pub async fn lfs_main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "install" => {
                install();
                std::process::exit(0);
            }
            "debug" => {
                // Logger level already set by environment; continue.
            }
            "enable-debug" => {
                std::process::Command::new("git")
                    .args([
                        "config",
                        "--add",
                        "lfs.customtransfer.git-lfs-s3.args",
                        "debug",
                    ])
                    .status()
                    .ok();
                println!("debug enabled");
                std::process::exit(0);
            }
            "disable-debug" => {
                std::process::Command::new("git")
                    .args([
                        "config",
                        "--unset",
                        "lfs.customtransfer.git-lfs-s3.args",
                    ])
                    .status()
                    .ok();
                println!("debug disabled");
                std::process::exit(0);
            }
            other => {
                println!("unknown command {}", other);
                std::process::exit(1);
            }
        }
    }

    let stdin = std::io::stdin();
    let mut lfs_process: Option<LFSProcess> = None;

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                error!("stdin read error: {}", e);
                break;
            }
        };
        debug!("line: {}", line);

        let event: LfsEvent = match serde_json::from_str(&line) {
            Ok(e) => e,
            Err(e) => {
                error!("JSON parse error: {}", e);
                continue;
            }
        };

        match event.event.as_str() {
            "init" => {
                let remote = match &event.remote {
                    Some(r) => r.clone(),
                    None => {
                        error!("missing remote in init event");
                        println!("{{}}");
                        std::io::stdout().flush().ok();
                        std::process::exit(1);
                    }
                };

                if !validate_ref_name(&remote) {
                    error!("invalid ref {}", remote);
                    println!("{{}}");
                    std::io::stdout().flush().ok();
                    std::process::exit(1);
                }

                let url_result = std::process::Command::new("git")
                    .args(["remote", "get-url", &remote])
                    .output();

                let s3uri = match url_result {
                    Ok(out) if out.status.success() => {
                        String::from_utf8_lossy(&out.stdout).trim().to_owned()
                    }
                    Ok(out) => {
                        let msg = String::from_utf8_lossy(&out.stderr).trim().to_owned();
                        error!("{}", msg);
                        let ev = serde_json::json!({
                            "error": {"code": 2, "message": format!("cannot resolve remote \"{}\"", remote)}
                        });
                        print!("{}", ev);
                        std::io::stdout().flush().ok();
                        std::process::exit(1);
                    }
                    Err(e) => {
                        error!("{}", e);
                        std::process::exit(1);
                    }
                };

                lfs_process = LFSProcess::new(&s3uri).await;
            }
            "upload" => {
                if let Some(ref lfs) = lfs_process {
                    lfs.upload(&event).await;
                }
            }
            "download" => {
                if let Some(ref lfs) = lfs_process {
                    lfs.download(&event).await;
                }
            }
            other => {
                debug!("unknown event: {}", other);
            }
        }
    }
}
