// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0
//
// Mock S3 client and Git function overrides used across all test files.

import Foundation
@testable import GitRemoteS3

// MARK: - MockS3Client

/// A simple in-memory S3 mock used by unit tests.
///
/// All behaviour is configurable through closures; defaults return empty results.
final class MockS3Client: S3ClientProtocol {

    // ---------- Configurable closures ----------

    var listObjectsV2Handler: ((_ bucket: String, _ prefix: String, _ continuationToken: String?)
        throws -> (contents: [[String: Any]], nextToken: String?))
        = { _, _, _ in return ([], nil) }

    var getObjectHandler: ((_ bucket: String, _ key: String) throws -> Data)
        = { _, _ in return Data() }

    var putObjectHandler: ((_ bucket: String, _ key: String, _ body: Data,
                            _ metadata: [String: String]?,
                            _ contentDisposition: String?,
                            _ ifNoneMatch: String?) throws -> Void)
        = { _, _, _, _, _, _ in }

    var deleteObjectHandler: ((_ bucket: String, _ key: String) throws -> Void)
        = { _, _ in }

    var headObjectHandler: ((_ bucket: String, _ key: String) throws -> Date?)
        = { _, _ in return nil }

    var downloadFileHandler: ((_ bucket: String, _ key: String, _ toPath: String) throws -> Void)
        = { _, _, _ in }

    var uploadFileHandler: ((_ localPath: String, _ bucket: String, _ key: String,
                             _ metadata: [String: String]?,
                             _ contentDisposition: String?,
                             _ progressCallback: ((Int64) -> Void)?) throws -> Void)
        = { _, _, _, _, _, _ in }

    var copyObjectHandler: ((_ sourceBucket: String, _ sourceKey: String,
                             _ destBucket: String, _ destKey: String) throws -> Void)
        = { _, _, _, _ in }

    // ---------- Call-count tracking ----------

    private(set) var listCallCount = 0
    private(set) var getCallCount = 0
    private(set) var putCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var headCallCount = 0
    private(set) var downloadCallCount = 0
    private(set) var uploadCallCount = 0

    // ---------- Recorded calls ----------

    struct PutCall {
        let bucket: String
        let key: String
        let body: Data
        let metadata: [String: String]?
        let contentDisposition: String?
        let ifNoneMatch: String?
    }
    struct DeleteCall { let bucket: String; let key: String }

    private(set) var putCalls: [PutCall] = []
    private(set) var deleteCalls: [DeleteCall] = []

    // ---------- Protocol conformance ----------

    func listObjectsV2(bucket: String, prefix: String, continuationToken: String?) throws
        -> (contents: [[String: Any]], nextToken: String?)
    {
        listCallCount += 1
        return try listObjectsV2Handler(bucket, prefix, continuationToken)
    }

    func getObject(bucket: String, key: String) throws -> Data {
        getCallCount += 1
        return try getObjectHandler(bucket, key)
    }

    func putObject(bucket: String, key: String, body: Data,
                   metadata: [String: String]?, contentDisposition: String?,
                   ifNoneMatch: String?) throws
    {
        putCallCount += 1
        putCalls.append(PutCall(bucket: bucket, key: key, body: body,
                                metadata: metadata, contentDisposition: contentDisposition,
                                ifNoneMatch: ifNoneMatch))
        try putObjectHandler(bucket, key, body, metadata, contentDisposition, ifNoneMatch)
    }

    func deleteObject(bucket: String, key: String) throws {
        deleteCallCount += 1
        deleteCalls.append(DeleteCall(bucket: bucket, key: key))
        try deleteObjectHandler(bucket, key)
    }

    func headObject(bucket: String, key: String) throws -> Date? {
        headCallCount += 1
        return try headObjectHandler(bucket, key)
    }

    func downloadFile(bucket: String, key: String, toPath: String) throws {
        downloadCallCount += 1
        try downloadFileHandler(bucket, key, toPath)
    }

    func uploadFile(localPath: String, bucket: String, key: String,
                    metadata: [String: String]?,
                    contentDisposition: String?,
                    progressCallback: ((Int64) -> Void)?) throws
    {
        uploadCallCount += 1
        try uploadFileHandler(localPath, bucket, key, metadata, contentDisposition, progressCallback)
    }

    func copyObject(sourceBucket: String, sourceKey: String,
                    destBucket: String, destKey: String) throws
    {
        try copyObjectHandler(sourceBucket, sourceKey, destBucket, destKey)
    }

    // ---------- Reset ----------

    func reset() {
        listCallCount = 0
        getCallCount = 0
        putCallCount = 0
        deleteCallCount = 0
        headCallCount = 0
        downloadCallCount = 0
        uploadCallCount = 0
        putCalls = []
        deleteCalls = []
    }
}

// MARK: - MockGitFunctions

/// Injectable git function closures used to stub out subprocess calls in tests.
var mockGitRevParse: ((String) throws -> String)? = nil
var mockGitBundle: ((String, String, String) throws -> String)? = nil
var mockGitUnbundle: ((String, String, String) throws -> Void)? = nil
var mockGitIsAncestor: ((String, String) throws -> Bool)? = nil
var mockGitArchive: ((String, String) throws -> String)? = nil
var mockGitGetLastCommitMessage: (() throws -> String)? = nil

// MARK: - Factory helpers

func makeS3RemoteForTest(
    uriScheme: UriScheme = .s3,
    profile: String? = nil,
    bucket: String = "test_bucket",
    prefix: String = "test_prefix",
    s3: MockS3Client
) -> S3Remote {
    S3Remote(uriScheme: uriScheme,
             profile: profile,
             bucket: bucket,
             prefix: prefix,
             s3Client: s3)
}

// MARK: - Test list-objects helper (mirrors Python's create_list_objects_v2_mock)

func makeListObjectsMock(
    shas: [String],
    branch: String = "pytest",
    protected: Bool = false,
    noHead: Bool = false
) -> (_ bucket: String, _ prefix: String, _ continuationToken: String?)
    throws -> (contents: [[String: Any]], nextToken: String?)
{
    return { _, prefix, _ in
        var content: [[String: Any]] = []
        for sha in shas {
            content.append([
                "Key": "test_prefix/refs/heads/\(branch)/\(sha).bundle",
                "LastModified": Date(),
            ])
        }
        if protected {
            content.append([
                "Key": "test_prefix/refs/heads/\(branch)/PROTECTED#",
                "LastModified": Date(),
            ])
        }
        if !noHead {
            content.append([
                "Key": "test_prefix/HEAD",
                "LastModified": Date(),
            ])
        }
        let filtered = content.filter { obj in
            guard let key = obj["Key"] as? String else { return false }
            return key.hasPrefix(prefix)
        }
        return (filtered, nil)
    }
}
