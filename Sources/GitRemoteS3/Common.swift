// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from git_remote_s3/common.py

import Foundation

/// The result of parsing a git remote S3 URL.
public struct GitURLComponents {
    public let uriScheme: UriScheme?
    public let profile: String?
    public let bucket: String?
    public let prefix: String?

    /// A "nil" result indicating an invalid / unrecognised URL.
    public static let invalid = GitURLComponents(
        uriScheme: nil, profile: nil, bucket: nil, prefix: nil
    )
}

/// Parses the elements in a `s3://` or `s3+zip://` remote origin URI.
///
/// - Parameter url: The URI to parse.
/// - Returns: A ``GitURLComponents`` value; all fields are `nil` when the URL is invalid.
public func parseGitURL(_ url: String?) -> GitURLComponents {
    guard let url = url else { return .invalid }

    // Pattern mirrors the Python original:
    //   (s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?
    let pattern = #"^(s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9.\-]{2,62})/?(.+)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return .invalid }

    let nsURL = url as NSString
    let range = NSRange(location: 0, length: nsURL.length)
    guard let match = regex.firstMatch(in: url, range: range),
          match.numberOfRanges == 5
    else { return .invalid }

    func group(_ i: Int) -> String? {
        let r = match.range(at: i)
        guard r.location != NSNotFound else { return nil }
        return nsURL.substring(with: r)
    }

    // Group 1: scheme ("s3" or "s3+zip")
    guard let schemeString = group(1) else { return .invalid }
    let scheme: UriScheme = schemeString == "s3+zip" ? .s3Zip : .s3

    // Group 2: optional "profile@" token
    var profile: String? = group(2)
    if let p = profile {
        // Strip trailing "@"
        if p.isEmpty {
            // Empty profile like "s3://@bucket/…" → invalid
            return .invalid
        }
        profile = String(p.dropLast()) // remove the "@"
        if profile!.isEmpty { return .invalid }
    }

    // Group 3: bucket
    guard let bucket = group(3) else { return .invalid }

    // Group 4: optional prefix
    var prefix: String? = group(4)
    if let p = prefix {
        // Strip leading and trailing "/"
        let stripped = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        prefix = stripped.isEmpty ? nil : stripped
    }

    return GitURLComponents(
        uriScheme: scheme,
        profile: profile,
        bucket: bucket,
        prefix: prefix
    )
}
