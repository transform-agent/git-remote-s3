// swift-tools-version: 5.9
// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "git-remote-s3",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library – shared logic used by all CLI targets and tests
        .library(
            name: "GitRemoteS3",
            targets: ["GitRemoteS3"]
        ),
        // git-remote-s3 / git-remote-s3+zip binary
        .executable(
            name: "git-remote-s3",
            targets: ["GitRemoteS3CLI"]
        ),
        // git-lfs-s3 binary
        .executable(
            name: "git-lfs-s3",
            targets: ["GitLFSS3CLI"]
        ),
        // git-s3 binary
        .executable(
            name: "git-s3",
            targets: ["GitS3CLI"]
        ),
    ],
    dependencies: [
        // AWS SDK for Swift – S3 service
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift.git",
            from: "0.36.0"
        ),
        // Argument parser for CLI targets
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.3.0"
        ),
    ],
    targets: [
        // ── Library ─────────────────────────────────────────────────────────
        .target(
            name: "GitRemoteS3",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
            ],
            path: "Sources/GitRemoteS3"
        ),

        // ── git-remote-s3 CLI ────────────────────────────────────────────────
        .executableTarget(
            name: "GitRemoteS3CLI",
            dependencies: [
                "GitRemoteS3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitRemoteS3CLI"
        ),

        // ── git-lfs-s3 CLI ───────────────────────────────────────────────────
        .executableTarget(
            name: "GitLFSS3CLI",
            dependencies: [
                "GitRemoteS3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitLFSS3CLI"
        ),

        // ── git-s3 CLI ───────────────────────────────────────────────────────
        .executableTarget(
            name: "GitS3CLI",
            dependencies: [
                "GitRemoteS3",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GitS3CLI"
        ),

        // ── Tests ────────────────────────────────────────────────────────────
        .testTarget(
            name: "GitRemoteS3Tests",
            dependencies: [
                "GitRemoteS3",
            ],
            path: "Tests/GitRemoteS3Tests"
        ),
    ]
)
