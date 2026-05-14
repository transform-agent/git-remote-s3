<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3\Tests;

use Aws\Result;
use Aws\S3\S3Client;
use Aws\S3\Exception\S3Exception;
use Aws\CommandInterface;
use GitRemoteS3\Remote;
use GitRemoteS3\UriScheme;
use GitRemoteS3\Git;
use PHPUnit\Framework\TestCase;
use PHPUnit\Framework\MockObject\MockObject;

/**
 * Tests for Remote (push, fetch, list, capabilities, options).
 *
 * Corresponds to test/remote_test.py.
 *
 * Mocking strategy
 * ----------------
 * Python tests patch `boto3.Session.client` globally.  In PHP we pass a
 * pre-built mock S3Client through the Remote constructor (injected via the
 * optional $s3Client parameter added in the translation plan).
 *
 * Git helper functions (bundle, rev_parse, is_ancestor, unbundle, archive,
 * get_last_commit_message) are mocked by subclassing Remote and overriding
 * the relevant Git:: calls through callable properties that tests can set.
 */
class RemoteTest extends TestCase
{
    use S3TestHelpers;

    // -------------------------------------------------------------------------
    // Constants (mirror the Python tests)
    // -------------------------------------------------------------------------
    private const SHA1   = 'c105d19ba64965d2c9d3d3246e7269059ef8bb8a';
    private const SHA2   = 'c105d19ba64965d2c9d3d3246e7269059ef8bb8b';
    private const BRANCH = 'pytest';
    private const MOCK_BUNDLE_CONTENT  = 'MOCK_BUNDLE_CONTENT';
    private const MOCK_ARCHIVE_CONTENT = 'MOCK_ARCHIVE_CONTENT';

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Create a temporary bundle file and return its path.
     */
    private function makeTempBundle(): string
    {
        $dir  = sys_get_temp_dir() . '/remote_test_' . uniqid('', true);
        mkdir($dir, 0700, true);
        $path = $dir . '/' . self::SHA1 . '.bundle';
        file_put_contents($path, self::MOCK_BUNDLE_CONTENT);
        return $path;
    }

    /**
     * Create a temporary archive file and return its path.
     */
    private function makeTempArchive(): string
    {
        $dir  = sys_get_temp_dir() . '/remote_test_' . uniqid('', true);
        mkdir($dir, 0700, true);
        $path = $dir . '/repo.zip';
        file_put_contents($path, self::MOCK_ARCHIVE_CONTENT);
        return $path;
    }

    /**
     * Build a Remote with a testable Git strategy.
     *
     * @param array $gitStubs  Associative array of Git method stubs:
     *                         revParse, bundle, isAncestor, unbundle,
     *                         archive, getLastCommitMessage
     */
    private function makeTestableRemote(
        UriScheme $uriScheme,
        S3Client  $s3Mock,
        array     $gitStubs = [],
    ): TestableRemote {
        return new TestableRemote(
            uriScheme: $uriScheme,
            profile:   null,
            bucket:    'test_bucket',
            prefix:    'test_prefix',
            s3Client:  $s3Mock,
            gitStubs:  $gitStubs,
        );
    }

    // -------------------------------------------------------------------------
    // cmd_list tests
    // -------------------------------------------------------------------------

    public function testCmdList(): void
    {
        $branch = self::BRANCH;
        $sha1   = self::SHA1;

        $s3Mock = $this->createMock(S3Client::class);

        $s3Mock->method('listObjectsV2')
               ->willReturnCallback(function (array $args) use ($sha1, $branch): Result {
                   $prefix  = $args['Prefix'];
                   $content = [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => 'test_prefix/HEAD', 'LastModified' => new \DateTimeImmutable()],
                   ];
                   return new Result([
                       'Contents' => array_values(array_filter($content, fn($c) => str_starts_with($c['Key'], $prefix))),
                   ]);
               });

        $s3Mock->method('getObject')
               ->willReturn(new Result(['Body' => "refs/heads/{$branch}"]));

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdList();
        $out = ob_get_clean();

        $this->assertSame("@refs/heads/{$branch} HEAD\n{$sha1} refs/heads/{$branch}\n\n", $out);
    }

    public function testListRefs(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "nested/test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "nested/test_prefix/refs/tags/v1/{$sha1}.bundle",          'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));

        $remote = new Remote(
            uriScheme: UriScheme::S3,
            profile:   null,
            bucket:    'test_bucket',
            prefix:    'nested/test_prefix',
            s3Client:  $s3Mock,
        );

        $refs = $remote->listRefs('test_bucket', 'nested/test_prefix');
        $this->assertCount(2, $refs);
        $this->assertContains("refs/heads/{$branch}/{$sha1}.bundle", $refs);
        $this->assertContains("refs/tags/v1/{$sha1}.bundle", $refs);
    }

    public function testCmdListNestedPrefix(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "nested/test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => 'nested/test_prefix/HEAD', 'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));
        $s3Mock->method('getObject')
               ->willReturn(new Result(['Body' => "refs/heads/{$branch}"]));

        $remote = new Remote(
            uriScheme: UriScheme::S3,
            profile:   null,
            bucket:    'test_bucket',
            prefix:    'nested/test_prefix',
            s3Client:  $s3Mock,
        );

        ob_start();
        $remote->cmdList();
        $out = ob_get_clean();

        $this->assertSame("@refs/heads/{$branch} HEAD\n{$sha1} refs/heads/{$branch}\n\n", $out);
    }

    public function testCmdListNoHead(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturnCallback(function (array $args) use ($sha1, $branch): Result {
                   $prefix  = $args['Prefix'];
                   $content = [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                   ];
                   return new Result([
                       'Contents' => array_values(array_filter($content, fn($c) => str_starts_with($c['Key'], $prefix))),
                   ]);
               });
        $s3Mock->method('getObject')
               ->willThrowException($this->makeS3Exception('NoSuchKey', 404));

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdList();
        $out = ob_get_clean();

        $this->assertSame("{$sha1} refs/heads/{$branch}\n\n", $out);
    }

    public function testCmdListWithHeadNotExistingRef(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturnCallback(function (array $args) use ($sha1, $branch): Result {
                   $prefix  = $args['Prefix'];
                   $content = [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => 'test_prefix/HEAD', 'LastModified' => new \DateTimeImmutable()],
                   ];
                   return new Result([
                       'Contents' => array_values(array_filter($content, fn($c) => str_starts_with($c['Key'], $prefix))),
                   ]);
               });
        // HEAD points to a non-existent ref
        $s3Mock->method('getObject')
               ->willReturn(new Result(['Body' => 'refs/heads/master']));

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdList();
        $out = ob_get_clean();

        // HEAD ref does not match any listed ref → only the bundle line
        $this->assertSame("{$sha1} refs/heads/{$branch}\n\n", $out);
    }

    public function testCmdListProtectedBranch(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturnCallback(function (array $args) use ($sha1, $branch): Result {
                   $prefix  = $args['Prefix'];
                   $content = [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "test_prefix/refs/heads/{$branch}/PROTECTED#",     'LastModified' => new \DateTimeImmutable()],
                       ['Key' => 'test_prefix/HEAD', 'LastModified' => new \DateTimeImmutable()],
                   ];
                   return new Result([
                       'Contents' => array_values(array_filter($content, fn($c) => str_starts_with($c['Key'], $prefix))),
                   ]);
               });
        $s3Mock->method('getObject')
               ->willReturn(new Result(['Body' => "refs/heads/{$branch}"]));

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdList();
        $out = ob_get_clean();

        $this->assertSame("@refs/heads/{$branch} HEAD\n{$sha1} refs/heads/{$branch}\n\n", $out);
    }

    // -------------------------------------------------------------------------
    // cmd_push tests
    // -------------------------------------------------------------------------

    public function testCmdPushNoForceUnprotectedAncestor(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $tempFile = $this->makeTempBundle();

        $s3Mock = $this->makeS3Mock(shas: [$sha1], branch: $branch, protected: true);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => true,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(1, $putCalls);
        $this->assertSame(1, $delCalls);
        $this->assertSame("ok refs/heads/{$branch}\n", $res);
    }

    public function testCmdPushNoForceUnprotectedAncestorS3Zip(): void
    {
        $sha1        = self::SHA1;
        $branch      = self::BRANCH;
        $tempFile    = $this->makeTempBundle();
        $tempArchive = $this->makeTempArchive();

        $s3Mock = $this->makeS3Mock(shas: [$sha1], branch: $branch, protected: true);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock, [
            'revParse'             => fn($ref) => $sha1,
            'isAncestor'           => fn($a, $b) => true,
            'bundle'               => fn($folder, $sha, $ref) => $tempFile,
            'archive'              => fn($folder, $ref) => $tempArchive,
            'getLastCommitMessage' => fn() => 'test commit',
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(2, $putCalls);
        $this->assertSame(1, $delCalls);
        $this->assertSame("ok refs/heads/{$branch}\n", $res);
    }

    public function testCmdPushNoForceUnprotectedNoAncestor(): void
    {
        $sha1     = self::SHA1;
        $sha2     = self::SHA2;
        $branch   = self::BRANCH;
        $tempFile = $this->makeTempBundle();

        $s3Mock = $this->makeS3Mock(shas: [$sha2], branch: $branch);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));
        $putCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'] ?? '', '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => false,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(0, $putCalls);
        $this->assertTrue(str_starts_with($res, 'error'));
    }

    public function testCmdPushForceNoAncestor(): void
    {
        $sha1     = self::SHA1;
        $sha2     = self::SHA2;
        $branch   = self::BRANCH;
        $tempFile = $this->makeTempBundle();

        $s3Mock = $this->makeS3Mock(shas: [$sha2], branch: $branch);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => false,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push +refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(1, $putCalls);
        $this->assertSame(1, $delCalls);
        $this->assertTrue(str_starts_with($res, 'ok'));
    }

    public function testCmdPushForceNoAncestorS3Zip(): void
    {
        $sha1        = self::SHA1;
        $sha2        = self::SHA2;
        $branch      = self::BRANCH;
        $tempFile    = $this->makeTempBundle();
        $tempArchive = $this->makeTempArchive();

        $s3Mock = $this->makeS3Mock(shas: [$sha2], branch: $branch);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock, [
            'revParse'             => fn($ref) => $sha1,
            'isAncestor'           => fn($a, $b) => false,
            'bundle'               => fn($folder, $sha, $ref) => $tempFile,
            'archive'              => fn($folder, $ref) => $tempArchive,
            'getLastCommitMessage' => fn() => 'test commit',
        ]);

        $res = $remote->cmdPush("push +refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(2, $putCalls);
        $this->assertSame(1, $delCalls);
        $this->assertTrue(str_starts_with($res, 'ok'));
    }

    public function testCmdPushForceNoAncestorProtected(): void
    {
        $sha1     = self::SHA1;
        $sha2     = self::SHA2;
        $branch   = self::BRANCH;
        $tempFile = $this->makeTempBundle();

        $s3Mock   = $this->makeS3Mock(shas: [$sha2], branch: $branch, protected: true);
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            $putCalls++;
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            $delCalls++;
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => false,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push +refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(0, $putCalls);
        $this->assertSame(0, $delCalls);
        $this->assertTrue(str_starts_with($res, 'error'));
    }

    public function testCmdPushEmptyBucket(): void
    {
        $sha1     = self::SHA1;
        $branch   = self::BRANCH;
        $tempFile = $this->makeTempBundle();

        $s3Mock = $this->createMock(S3Client::class);
        // Empty bucket — listObjectsV2 returns nothing
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        // headObject throws (no HEAD yet)
        $s3Mock->method('headObject')
               ->willThrowException($this->makeS3Exception('NoSuchKey', 404));

        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => false,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        // bundle + HEAD → 2 puts, 0 deletes
        $this->assertSame(2, $putCalls);
        $this->assertSame(0, $delCalls);
        $this->assertTrue(str_starts_with($res, 'ok'));
    }

    public function testCmdPushEmptyBucketS3Zip(): void
    {
        $sha1        = self::SHA1;
        $branch      = self::BRANCH;
        $tempFile    = $this->makeTempBundle();
        $tempArchive = $this->makeTempArchive();

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $s3Mock->method('headObject')
               ->willThrowException($this->makeS3Exception('NoSuchKey', 404));

        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $putCalls++;
            }
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            if (!str_ends_with($args['Key'], '.lock')) {
                $delCalls++;
            }
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock, [
            'revParse'             => fn($ref) => $sha1,
            'isAncestor'           => fn($a, $b) => false,
            'bundle'               => fn($folder, $sha, $ref) => $tempFile,
            'archive'              => fn($folder, $ref) => $tempArchive,
            'getLastCommitMessage' => fn() => 'test commit',
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        // bundle + HEAD + zip → 3 puts, 0 deletes
        $this->assertSame(3, $putCalls);
        $this->assertSame(0, $delCalls);
        $this->assertTrue(str_starts_with($res, 'ok'));
    }

    public function testCmdPushS3ZipPutObjectParams(): void
    {
        $sha1        = self::SHA1;
        $sha2        = self::SHA2;
        $branch      = self::BRANCH;
        $tempFile    = $this->makeTempBundle();
        $tempArchive = $this->makeTempArchive();
        $commitMsg   = 'test commit message';

        $s3Mock = $this->makeS3Mock(shas: [$sha2], branch: $branch);
        $s3Mock->method('headObject')->willThrowException($this->makeS3Exception('NoSuchKey', 404));

        $putObjectCalls = [];
        $s3Mock->method('putObject')->willReturnCallback(
            function (array $args) use (&$putObjectCalls): Result {
                if (!str_ends_with($args['Key'], '.lock')) {
                    $putObjectCalls[] = $args;
                }
                return new Result([]);
            }
        );
        $s3Mock->method('deleteObject')->willReturn(new Result([]));

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock, [
            'revParse'             => fn($ref) => $sha1,
            'isAncestor'           => fn($a, $b) => true,
            'bundle'               => fn($folder, $sha, $ref) => $tempFile,
            'archive'              => fn($folder, $ref) => $tempArchive,
            'getLastCommitMessage' => fn() => $commitMsg,
        ]);

        $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertCount(2, $putObjectCalls);

        // First call: bundle
        $bundleCall = $putObjectCalls[0];
        $this->assertSame('test_bucket', $bundleCall['Bucket']);
        $this->assertStringEndsWith('.bundle', $bundleCall['Key']);

        // Second call: zip
        $zipCall = $putObjectCalls[1];
        $this->assertSame('test_bucket', $zipCall['Bucket']);
        $this->assertStringEndsWith('repo.zip', $zipCall['Key']);
        $this->assertSame(
            $commitMsg,
            $zipCall['Metadata']['codepipeline-artifact-revision-summary']
        );
    }

    public function testCmdPushMultipleHeads(): void
    {
        $sha1     = self::SHA1;
        $sha2     = self::SHA2;
        $branch   = self::BRANCH;
        $tempFile = $this->makeTempBundle();

        $s3Mock   = $this->makeS3Mock(shas: [$sha1, $sha2], branch: $branch);
        $putCalls = 0;
        $delCalls = 0;
        $s3Mock->method('putObject')->willReturnCallback(function (array $args) use (&$putCalls): Result {
            $putCalls++;
            return new Result([]);
        });
        $s3Mock->method('deleteObject')->willReturnCallback(function (array $args) use (&$delCalls): Result {
            $delCalls++;
            return new Result([]);
        });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'revParse'   => fn($ref) => $sha1,
            'isAncestor' => fn($a, $b) => false,
            'bundle'     => fn($folder, $sha, $ref) => $tempFile,
        ]);

        $res = $remote->cmdPush("push refs/heads/{$branch}:refs/heads/{$branch}");

        $this->assertSame(0, $putCalls);
        $this->assertSame(0, $delCalls);
        $this->assertTrue(str_starts_with($res, 'error'));
    }

    // -------------------------------------------------------------------------
    // cmd_fetch tests
    // -------------------------------------------------------------------------

    public function testCmdFetch(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $s3Mock->expects($this->once())->method('getObject');

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'unbundle' => fn($folder, $sha, $ref) => null,
        ]);

        $remote->cmdFetch("fetch {$sha1} refs/heads/{$branch}");
    }

    public function testCmdFetchSameRef(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        // Second call must be skipped — getObject called only once
        $s3Mock->expects($this->once())->method('getObject');

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock, [
            'unbundle' => fn($folder, $sha, $ref) => null,
        ]);

        $cmd = "fetch {$sha1} refs/heads/{$branch}";
        $remote->cmdFetch($cmd);
        $remote->cmdFetch($cmd);
    }

    // -------------------------------------------------------------------------
    // cmd_option / cmd_capabilities tests
    // -------------------------------------------------------------------------

    public function testCmdOption(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdOption('option verbosity 2');
        $out = ob_get_clean();
        $this->assertStringStartsWith("ok\n", $out);

        ob_start();
        $remote->cmdOption('option concurrency 1');
        $out = ob_get_clean();
        $this->assertStringEndsWith("unsupported\n", $out);
    }

    public function testCmdCapabilities(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);

        ob_start();
        $remote->cmdCapabilities();
        $out = ob_get_clean();

        $this->assertStringContainsString('fetch', $out);
        $this->assertStringContainsString('option', $out);
        $this->assertStringContainsString('push', $out);
    }

    // -------------------------------------------------------------------------
    // cmd_push delete tests
    // -------------------------------------------------------------------------

    public function testCmdPushDelete(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));
        $s3Mock->expects($this->once())->method('deleteObject');

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);
        $res    = $remote->cmdPush("push :refs/heads/{$branch}");

        $this->assertSame("ok refs/heads/{$branch}\n", $res);
    }

    public function testCmdPushDeleteS3Zip(): void
    {
        $sha1   = self::SHA1;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "test_prefix/refs/heads/{$branch}/repo.zip",       'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));
        $s3Mock->expects($this->exactly(2))->method('deleteObject');

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock);
        $res    = $remote->cmdPush("push :refs/heads/{$branch}");

        $this->assertSame("ok refs/heads/{$branch}\n", $res);
    }

    public function testCmdPushDeleteFailsWithMultipleHeads(): void
    {
        $sha1   = self::SHA1;
        $sha2   = self::SHA2;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha2}.bundle", 'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));
        $s3Mock->expects($this->never())->method('deleteObject');

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);
        $res    = $remote->cmdPush("push :refs/heads/{$branch}");

        $this->assertTrue(str_starts_with($res, 'error'));
    }

    public function testCmdPushDeleteFailsWithMultipleHeadsS3Zip(): void
    {
        $sha1   = self::SHA1;
        $sha2   = self::SHA2;
        $branch = self::BRANCH;

        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result([
                   'Contents' => [
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha1}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "test_prefix/refs/heads/{$branch}/{$sha2}.bundle", 'LastModified' => new \DateTimeImmutable()],
                       ['Key' => "test_prefix/refs/heads/{$branch}/repo.zip",       'LastModified' => new \DateTimeImmutable()],
                   ],
               ]));
        $s3Mock->expects($this->never())->method('deleteObject');

        $remote = $this->makeTestableRemote(UriScheme::S3_ZIP, $s3Mock);
        $res    = $remote->cmdPush("push :refs/heads/{$branch}");

        $this->assertTrue(str_starts_with($res, 'error'));
    }

    // -------------------------------------------------------------------------
    // Lock tests
    // -------------------------------------------------------------------------

    public function testAcquireLockDeletesStaleLockAndReacquires(): void
    {
        $branch = self::BRANCH;
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));

        $attempts = 0;
        $s3Mock->method('putObject')
               ->willReturnCallback(function (array $args) use (&$attempts): Result {
                   $key         = $args['Key'] ?? '';
                   $ifNoneMatch = $args['IfNoneMatch'] ?? null;
                   if (str_ends_with($key, '.lock') && $ifNoneMatch === '*') {
                       if ($attempts === 0) {
                           $attempts++;
                           throw $this->makeS3Exception('PreconditionFailed', 412);
                       }
                   }
                   return new Result([]);
               });

        // Stale lock: last modified 120 seconds ago
        $staleTime = new \DateTimeImmutable('-120 seconds');
        $s3Mock->method('headObject')
               ->willReturn(new Result(['LastModified' => $staleTime]));

        $deleteCallKeys = [];
        $s3Mock->method('deleteObject')
               ->willReturnCallback(function (array $args) use (&$deleteCallKeys): Result {
                   $deleteCallKeys[] = $args['Key'];
                   return new Result([]);
               });

        $remote = $this->makeTestableRemote(UriScheme::S3, $s3Mock);
        $remote->lockTtlSeconds = 60;

        $remoteRef = "refs/heads/{$branch}";
        $lockKey   = $remote->acquireLock($remoteRef);

        $expectedLockKey = "test_prefix/{$remoteRef}/LOCK#.lock";
        $this->assertSame($expectedLockKey, $lockKey);

        // delete was called for the stale lock
        $lockDeleteCalls = array_filter($deleteCallKeys, fn($k) => str_ends_with($k, '.lock'));
        $this->assertCount(1, $lockDeleteCalls);

        // putObject was called at least twice (first fail + reacquire)
        $this->assertGreaterThanOrEqual(2, $attempts + 1);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private function makeS3Exception(string $code, int $statusCode): S3Exception
    {
        $cmd = $this->createMock(CommandInterface::class);
        return new S3Exception(
            $code,
            $cmd,
            ['response' => null, 'code' => $code, 'message' => $code, 'status_code' => $statusCode]
        );
    }
}

// ---------------------------------------------------------------------------
// TestableRemote — allows injecting Git stub callables
// ---------------------------------------------------------------------------

/**
 * Subclass of Remote that allows individual Git:: calls to be stubbed out
 * without spawning real git processes.
 */
class TestableRemote extends Remote
{
    /** @var array<string, callable> */
    private array $gitStubs;

    public function __construct(
        UriScheme $uriScheme,
        ?string   $profile,
        string    $bucket,
        string    $prefix,
        S3Client  $s3Client,
        array     $gitStubs = [],
    ) {
        parent::__construct($uriScheme, $profile, $bucket, $prefix, $s3Client);
        $this->gitStubs = $gitStubs;
    }

    // Override every Git:: call that reaches out to real processes.

    protected function gitRevParse(string $ref): string
    {
        return isset($this->gitStubs['revParse'])
            ? ($this->gitStubs['revParse'])($ref)
            : Git::revParse($ref);
    }

    protected function gitBundle(string $folder, string $sha, string $ref): string
    {
        return isset($this->gitStubs['bundle'])
            ? ($this->gitStubs['bundle'])($folder, $sha, $ref)
            : Git::bundle($folder, $sha, $ref);
    }

    protected function gitIsAncestor(string $ancestor, string $descendant): bool
    {
        return isset($this->gitStubs['isAncestor'])
            ? ($this->gitStubs['isAncestor'])($ancestor, $descendant)
            : Git::isAncestor($ancestor, $descendant);
    }

    protected function gitUnbundle(string $folder, string $sha, string $ref): void
    {
        if (isset($this->gitStubs['unbundle'])) {
            ($this->gitStubs['unbundle'])($folder, $sha, $ref);
        } else {
            Git::unbundle($folder, $sha, $ref);
        }
    }

    protected function gitArchive(string $folder, string $ref): string
    {
        return isset($this->gitStubs['archive'])
            ? ($this->gitStubs['archive'])($folder, $ref)
            : Git::archive($folder, $ref);
    }

    protected function gitGetLastCommitMessage(): string
    {
        return isset($this->gitStubs['getLastCommitMessage'])
            ? ($this->gitStubs['getLastCommitMessage'])()
            : Git::getLastCommitMessage();
    }
}
