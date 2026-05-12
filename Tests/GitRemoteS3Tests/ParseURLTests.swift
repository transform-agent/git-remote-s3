// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Translated from test/parse_url_test.py

import XCTest
@testable import GitRemoteS3

final class ParseURLTests: XCTestCase {

    func testParseURLTrailingSlashNoProfile() {
        let url = "s3://bucket-name/path/to/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertNil(c.profile)
        XCTAssertEqual(c.prefix, "path/to")
    }

    func testParseURLNoProfile() {
        let url = "s3://bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertNil(c.profile)
        XCTAssertEqual(c.prefix, "path/to")
    }

    func testParseURL() {
        let url = "s3://profile-test@bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertEqual(c.profile, "profile-test")
        XCTAssertEqual(c.prefix, "path/to")
    }

    func testParseURLIssue5() {
        let url = "s3://er@bucket/path/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket")
        XCTAssertEqual(c.profile, "er")
        XCTAssertEqual(c.prefix, "path")
    }

    func testParseURL1CharProfile() {
        let url = "s3://A@bucket/path/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket")
        XCTAssertEqual(c.profile, "A")
        XCTAssertEqual(c.prefix, "path")
    }

    func testParseURLAllSupportedSymbolsInProfile() {
        let url = "s3://Ab-tr+54_quwww@bucket/path/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket")
        XCTAssertEqual(c.profile, "Ab-tr+54_quwww")
        XCTAssertEqual(c.prefix, "path")
    }

    func testParseURLUnsupportedSymbolsInProfile() {
        let url = "s3://A!@bucket/path/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket")
        XCTAssertEqual(c.profile, "A!")
        XCTAssertEqual(c.prefix, "path")
    }

    func testParseURLEmptyProfile() {
        // Empty profile "s3://@bucket/…" → all nil
        let url = "s3://@bucket/path/"
        let c = parseGitURL(url)
        XCTAssertNil(c.uriScheme)
        XCTAssertNil(c.bucket)
        XCTAssertNil(c.profile)
        XCTAssertNil(c.prefix)
    }

    func testParseURLNoPrefixTrailingSlash() {
        let url = "s3://profile-test@bucket-name/"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertEqual(c.profile, "profile-test")
        XCTAssertNil(c.prefix)
    }

    func testParseURLNoPrefix() {
        let url = "s3://profile-test@bucket-name"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertEqual(c.profile, "profile-test")
        XCTAssertNil(c.prefix)
    }

    func testParseURLNoPrefixNoProfile() {
        let url = "s3://bucket-name"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertNil(c.profile)
        XCTAssertNil(c.prefix)
    }

    func testParseURLNotValid() {
        let url = "s4://bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertNil(c.uriScheme)
        XCTAssertNil(c.bucket)
        XCTAssertNil(c.profile)
        XCTAssertNil(c.prefix)
    }

    func testParseURLNilInput() {
        let c = parseGitURL(nil)
        XCTAssertNil(c.uriScheme)
        XCTAssertNil(c.bucket)
        XCTAssertNil(c.profile)
        XCTAssertNil(c.prefix)
    }

    func testParseURLUriSchemeS3ZipNoProfile() {
        let url = "s3+zip://bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3Zip)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertNil(c.profile)
        XCTAssertEqual(c.prefix, "path/to")
    }

    func testParseURLUriSchemeS3Zip() {
        let url = "s3+zip://profile-test@bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertEqual(c.uriScheme, .s3Zip)
        XCTAssertEqual(c.bucket, "bucket-name")
        XCTAssertEqual(c.profile, "profile-test")
        XCTAssertEqual(c.prefix, "path/to")
    }

    func testParseURLUriSchemeNotValid() {
        let url = "s3+foo://bucket-name/path/to"
        let c = parseGitURL(url)
        XCTAssertNil(c.uriScheme)
        XCTAssertNil(c.bucket)
        XCTAssertNil(c.profile)
        XCTAssertNil(c.prefix)
    }
}
