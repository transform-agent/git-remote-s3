<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3\Tests;

use GitRemoteS3\Common;
use GitRemoteS3\UriScheme;
use PHPUnit\Framework\TestCase;

/**
 * Tests for Common::parseGitUrl().
 *
 * Corresponds to test/parse_url_test.py.
 */
class ParseUrlTest extends TestCase
{
    public function testParseUrlTrailingSlashNoProfile(): void
    {
        $url = 's3://bucket-name/path/to/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertNull($profile);
        $this->assertSame('path/to', $prefix);
    }

    public function testParseUrlNoProfile(): void
    {
        $url = 's3://bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertNull($profile);
        $this->assertSame('path/to', $prefix);
    }

    public function testParseUrl(): void
    {
        $url = 's3://profile-test@bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertSame('profile-test', $profile);
        $this->assertSame('path/to', $prefix);
    }

    public function testParseUrlIssue5(): void
    {
        $url = 's3://er@bucket/path/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket', $bucket);
        $this->assertSame('er', $profile);
        $this->assertSame('path', $prefix);
    }

    public function testParseUrl1CharProfile(): void
    {
        $url = 's3://A@bucket/path/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket', $bucket);
        $this->assertSame('A', $profile);
        $this->assertSame('path', $prefix);
    }

    public function testParseUrlAllSupportedSymbolsInProfile(): void
    {
        $url = 's3://Ab-tr+54_quwww@bucket/path/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket', $bucket);
        $this->assertSame('Ab-tr+54_quwww', $profile);
        $this->assertSame('path', $prefix);
    }

    public function testParseUrlUnsupportedSymbolsInProfile(): void
    {
        $url = 's3://A!@bucket/path/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket', $bucket);
        $this->assertSame('A!', $profile);
        $this->assertSame('path', $prefix);
    }

    public function testParseUrlEmptyProfile(): void
    {
        $url = 's3://@bucket/path/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertNull($uriScheme);
        $this->assertNull($bucket);
        $this->assertNull($profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlNoPrefixTrailingSlash(): void
    {
        $url = 's3://profile-test@bucket-name/';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertSame('profile-test', $profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlNoPrefix(): void
    {
        $url = 's3://profile-test@bucket-name';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertSame('profile-test', $profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlNoPrefixNoProfile(): void
    {
        $url = 's3://bucket-name';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertNull($profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlNotValid(): void
    {
        $url = 's4://bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertNull($uriScheme);
        $this->assertNull($bucket);
        $this->assertNull($profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlNull(): void
    {
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl(null);

        $this->assertNull($uriScheme);
        $this->assertNull($bucket);
        $this->assertNull($profile);
        $this->assertNull($prefix);
    }

    public function testParseUrlUriSchemeS3ZipNoProfile(): void
    {
        $url = 's3+zip://bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3_ZIP, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertNull($profile);
        $this->assertSame('path/to', $prefix);
    }

    public function testParseUrlUriSchemeS3Zip(): void
    {
        $url = 's3+zip://profile-test@bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertSame(UriScheme::S3_ZIP, $uriScheme);
        $this->assertSame('bucket-name', $bucket);
        $this->assertSame('profile-test', $profile);
        $this->assertSame('path/to', $prefix);
    }

    public function testParseUrlUriSchemeNotValid(): void
    {
        $url = 's3+foo://bucket-name/path/to';
        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($url);

        $this->assertNull($uriScheme);
        $this->assertNull($bucket);
        $this->assertNull($profile);
        $this->assertNull($prefix);
    }
}
