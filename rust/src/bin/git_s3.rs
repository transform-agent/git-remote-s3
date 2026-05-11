// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//! Entry-point for `git-s3` (repository management).
//!
//! Mirrors the `main()` function in `git_remote_s3/manage.py`.

use aws_sdk_s3::Client as S3Client;
use clap::{Arg, ArgAction, Command};

use git_remote_s3::common::parse_git_url;
use git_remote_s3::git::{get_remote_url, GitError};
use git_remote_s3::manage::{Doctor, ManageBranch};
use git_remote_s3::remote::DEFAULT_LOCK_TTL_SECONDS;

#[tokio::main]
async fn main() {
    // Logging
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("error")),
        )
        .init();

    let matches = Command::new("git-s3")
        .about("Manage git-remote-s3 repositories")
        .arg(
            Arg::new("command")
                .index(1)
                .required(true)
                .help("Command to run: doctor | delete-branch | protect | unprotect"),
        )
        .arg(
            Arg::new("remote")
                .index(2)
                .required(true)
                .help("The remote s3 uri to analyse, including the AWS profile if used"),
        )
        .arg(
            Arg::new("branch")
                .index(3)
                .required(false)
                .help("Branch to operate on"),
        )
        .arg(
            Arg::new("delete-bundle")
                .short('d')
                .long("delete-bundle")
                .action(ArgAction::SetTrue)
                .help("Delete the bundle instead of creating a new branch"),
        )
        .arg(
            Arg::new("lock-ttl")
                .long("lock-ttl")
                .value_name("SECONDS")
                .default_value(Box::leak(DEFAULT_LOCK_TTL_SECONDS.to_string().into_boxed_str()) as &str)
                .help("Seconds after which a lock is considered stale"),
        )
        .arg(
            Arg::new("delete-stale-locks")
                .long("delete-stale-locks")
                .action(ArgAction::SetTrue)
                .help("Delete stale lock files found during doctor run"),
        )
        .get_matches();

    let command = matches.get_one::<String>("command").unwrap();
    let remote_name = matches.get_one::<String>("remote").unwrap();
    let branch = matches.get_one::<String>("branch").map(|s| s.as_str());
    let delete_bundle = *matches.get_one::<bool>("delete-bundle").unwrap_or(&false);
    let lock_ttl: u64 = matches
        .get_one::<String>("lock-ttl")
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_LOCK_TTL_SECONDS);
    let delete_stale_locks = *matches
        .get_one::<bool>("delete-stale-locks")
        .unwrap_or(&false);

    // Resolve the remote URL from the git config
    let remote_url = match get_remote_url(remote_name) {
        Ok(url) => url,
        Err(e) => {
            eprintln!("fatal: {}", e);
            std::process::exit(1);
        }
    };

    let parsed = match parse_git_url(&remote_url) {
        Some(p) => p,
        None => {
            eprintln!("fatal: invalid remote URL '{}'", remote_url);
            std::process::exit(1);
        }
    };

    // Build S3 client
    let aws_config = if let Some(ref profile) = parsed.profile {
        aws_config::from_env()
            .profile_name(profile.as_str())
            .load()
            .await
    } else {
        aws_config::load_from_env().await
    };
    let s3 = S3Client::new(&aws_config);

    let bucket = parsed.bucket;
    let prefix = parsed.prefix.unwrap_or_default();

    match command.as_str() {
        "doctor" => {
            let doctor = Doctor::new(
                s3,
                bucket,
                prefix,
                delete_bundle,
                lock_ttl,
                delete_stale_locks,
            );
            doctor.run().await;
        }
        cmd @ ("delete-branch" | "protect" | "unprotect") => {
            let branch_name = match branch {
                Some(b) => b,
                None => {
                    eprintln!("fatal: branch argument is required for '{}'", cmd);
                    std::process::exit(1);
                }
            };
            match ManageBranch::new(s3, bucket, prefix, branch_name.to_owned()).await {
                Ok(mb) => mb.process_cmd(cmd).await,
                Err(e) => {
                    eprintln!("fatal: {}", e);
                    std::process::exit(1);
                }
            }
        }
        unknown => {
            eprintln!("fatal: unknown command '{}'", unknown);
            std::process::exit(1);
        }
    }

    std::process::exit(0);
}
