// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Entry-point for `git-remote-s3` and `git-remote-s3+zip`.
//!
//! Mirrors the `main()` function in `git_remote_s3/remote.py`.

use std::io::{self, BufRead};

use aws_sdk_s3::Client as S3Client;
use tracing::info;

use git_remote_s3::common::parse_git_url;
use git_remote_s3::remote::{RemoteError, S3Remote};

#[tokio::main]
async fn main() {
    // Initialise tracing/logging to stderr.
    // Honour GIT_REMOTE_S3_VERBOSE env var: if set to "1", "true" or "yes",
    // default to INFO; otherwise ERROR.
    let verbose = std::env::var("GIT_REMOTE_S3_VERBOSE")
        .map(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);

    let default_level = if verbose { "info" } else { "error" };
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(default_level)),
        )
        .init();

    let args: Vec<String> = std::env::args().collect();
    info!("{:?}", args);

    // git passes: argv[0]=helper, argv[1]=remote-name, argv[2]=url
    if args.len() < 3 {
        eprintln!("fatal: usage: git-remote-s3 <remote> <url>");
        std::process::exit(1);
    }

    let remote_url = &args[2];
    let parsed = match parse_git_url(remote_url) {
        Some(p) => p,
        None => {
            eprintln!(
                "fatal: invalid remote '{}'. You need to have a bucket and a prefix.",
                remote_url
            );
            std::process::exit(1);
        }
    };

    if parsed.bucket.is_empty() || parsed.prefix.is_none() {
        eprintln!(
            "fatal: invalid remote '{}'. You need to have a bucket and a prefix.",
            remote_url
        );
        std::process::exit(1);
    }

    // Build AWS client
    let aws_config = if let Some(ref profile) = parsed.profile {
        aws_config::from_env()
            .profile_name(profile.as_str())
            .load()
            .await
    } else {
        aws_config::load_from_env().await
    };
    let s3 = S3Client::new(&aws_config);

    let mut s3remote = match S3Remote::new(
        s3,
        parsed.uri_scheme,
        parsed.profile,
        parsed.bucket,
        parsed.prefix.unwrap_or_default(),
    )
    .await
    {
        Ok(r) => r,
        Err(RemoteError::BucketNotFound { bucket }) => {
            eprintln!("fatal: bucket not found {}", bucket);
            std::process::exit(1);
        }
        Err(RemoteError::NotAuthorized { action, bucket }) => {
            eprintln!(
                "fatal: user not authorized to perform {} on {}",
                action, bucket
            );
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("fatal: invalid credentials {}", e);
            std::process::exit(1);
        }
    };

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        info!("cmd: {}", line);
        // Append newline so process_cmd can detect empty-line flush
        let cmd = if line.is_empty() {
            "\n".to_owned()
        } else {
            line
        };
        s3remote.process_cmd(&cmd).await;
    }
}
