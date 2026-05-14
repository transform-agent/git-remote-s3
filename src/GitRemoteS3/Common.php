<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

/**
 * Common helpers — URL parsing.
 *
 * Corresponds to git_remote_s3/common.py.
 */
class Common
{
    /**
     * Parse the elements in an s3:// remote origin URI.
     *
     * Returns a four-element array: [UriScheme|null, profile|null, bucket|null, prefix|null].
     * All elements are null when the URI is invalid.
     *
     * @param string|null $url
     * @return array{UriScheme|null, string|null, string|null, string|null}
     */
    public static function parseGitUrl(?string $url): array
    {
        if ($url === null) {
            return [null, null, null, null];
        }

        // Same pattern as the Python implementation:
        //   (s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?
        $pattern = '/^(s3|s3\+zip):\/\/([^@]+@)?([a-z0-9][a-z0-9.\-]{2,62})\/?(.+)?$/';
        if (preg_match($pattern, $url, $m) !== 1) {
            return [null, null, null, null];
        }

        // $m[0] is the full match; groups start at $m[1]
        if (count($m) - 1 !== 4) {
            // Unexpected — shouldn't happen with the above pattern, but guard anyway.
            return [null, null, null, null];
        }

        $uriSchemeStr = $m[1] !== '' ? $m[1] : null;
        $profile      = $m[2] !== '' ? $m[2] : null;
        $bucket       = $m[3] !== '' ? $m[3] : null;
        $prefix       = isset($m[4]) && $m[4] !== '' ? $m[4] : null;

        // Strip trailing '@' from profile
        if ($profile !== null) {
            $profile = rtrim($profile, '@');
            // Reject empty profiles (e.g. "s3://@bucket/path")
            if ($profile === '') {
                return [null, null, null, null];
            }
        }

        // Strip leading/trailing slashes from prefix
        if ($prefix !== null) {
            $prefix = trim($prefix, '/');
            if ($prefix === '') {
                $prefix = null;
            }
        }

        $uriScheme = null;
        if ($uriSchemeStr === 's3') {
            $uriScheme = UriScheme::S3;
        } elseif ($uriSchemeStr === 's3+zip') {
            $uriScheme = UriScheme::S3_ZIP;
        }

        return [$uriScheme, $profile, $bucket, $prefix];
    }
}
