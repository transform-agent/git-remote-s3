// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Entry-point for `git-lfs-s3`.
//!
//! Mirrors the `main()` function in `git_remote_s3/lfs.py`.

use git_remote_s3::lfs::lfs_main;

#[tokio::main]
async fn main() {
    // Initialise logging — LFS logs to .git/lfs/tmp/git-lfs-s3.log at ERROR level
    // by default; DEBUG enabled when the "debug" argument is passed.
    let args: Vec<String> = std::env::args().collect();
    let debug_mode = args.get(1).map(|a| a == "debug").unwrap_or(false);
    let level = if debug_mode { "debug" } else { "error" };

    // Use file-based appender if the log directory exists.
    let log_path = std::path::Path::new(".git/lfs/tmp/git-lfs-s3.log");
    if let Some(parent) = log_path.parent() {
        if parent.exists() {
            // Append to log file
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(log_path);
            match file {
                Ok(f) => {
                    tracing_subscriber::fmt()
                        .with_writer(move || {
                            // Clone the file for each write call
                            f.try_clone()
                                .unwrap_or_else(|_| std::fs::File::create("/dev/null").unwrap())
                        })
                        .with_env_filter(
                            tracing_subscriber::EnvFilter::try_from_default_env()
                                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level)),
                        )
                        .init();
                }
                Err(_) => {
                    init_stderr_logging(level);
                }
            }
        } else {
            init_stderr_logging(level);
        }
    } else {
        init_stderr_logging(level);
    }

    lfs_main().await;
}

fn init_stderr_logging(level: &str) {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level)),
        )
        .init();
}
