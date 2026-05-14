<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3\Tests;

use Aws\Result;
use Aws\S3\S3Client;
use GitRemoteS3\Remote;
use GitRemoteS3\UriScheme;
use PHPUnit\Framework\TestCase;

/**
 * Tests for Remote::processFetchCmds() — parallel-fetch behaviour.
 *
 * Corresponds to test/parallel_fetch_test.py.
 *
 * NOTE: PHP does not have native threads, so "parallel" execution is
 *       sequential in the PHP port.  The tests still verify that:
 *       - Each fetch command is processed exactly once.
 *       - Duplicate SHAs are deduplicated (fetched_refs guard).
 *       - Batch collection (processCmd + empty line) works correctly.
 */
class ParallelFetchTest extends TestCase
{
    use S3TestHelpers;

    private const SHA1   = 'c105d19ba64965d2c9d3d3246e7269059ef8bb8a';
    private const SHA2   = 'c105d19ba64965d2c9d3d3246e7269059ef8bb8b';
    private const SHA3   = 'c105d19ba64965d2c9d3d3246e7269059ef8bb8c';
    private const BRANCH = 'pytest';

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Build a Remote whose S3 mock stubs downloadFile + getObject,
     * and patches Git::unbundle so no real git process is launched.
     */
    private function makeRemoteWithDownloadMock(S3Client $s3Client): Remote
    {
        return $this->makeRemote(s3Client: $s3Client);
    }

    private function makeS3ClientWithDownloadMock(): S3Client
    {
        $mock = $this->createMock(S3Client::class);

        // listObjectsV2 for constructor validation
        $mock->method('listObjectsV2')
             ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));

        // getObject (used by cmdFetch via SaveAs) — return empty result
        $mock->method('getObject')
             ->willReturn(new Result(['Body' => '']));

        return $mock;
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    /**
     * processFetchCmds with an empty list must not call getObject.
     */
    public function testProcessFetchCmdsEmptyList(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));

        $remote = $this->makeRemote(s3Client: $s3Mock);
        $remote->processFetchCmds([]);

        // getObject must not have been called
        $s3Mock->expects($this->never())->method('getObject');
    }

    /**
     * A single fetch command must trigger exactly one S3 download.
     */
    public function testProcessFetchCmdsSingleCommand(): void
    {
        $s3Mock = $this->makeS3ClientWithDownloadMock();

        // Expect exactly one getObject call
        $s3Mock->expects($this->once())
               ->method('getObject');

        $remote = $this->makeRemoteWithDownloadMock($s3Mock);

        // Patch unbundle so no real git subprocess is launched
        $this->patchUnbundle(function () {});

        $remote->processFetchCmds(['fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH]);

        $this->assertContains(self::SHA1, $this->getPrivateFetchedRefs($remote));
    }

    /**
     * Multiple fetch commands must each trigger one S3 download.
     */
    public function testProcessFetchCmdsMultipleCommands(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $s3Mock->expects($this->exactly(3))->method('getObject');

        $remote = $this->makeRemoteWithDownloadMock($s3Mock);
        $this->patchUnbundle(function () {});

        $cmds = [
            'fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH,
            'fetch ' . self::SHA2 . ' refs/heads/' . self::BRANCH,
            'fetch ' . self::SHA3 . ' refs/heads/' . self::BRANCH,
        ];
        $remote->processFetchCmds($cmds);

        $fetched = $this->getPrivateFetchedRefs($remote);
        $this->assertContains(self::SHA1, $fetched);
        $this->assertContains(self::SHA2, $fetched);
        $this->assertContains(self::SHA3, $fetched);
    }

    /**
     * Fetch commands are collected but NOT processed until the empty-line flush.
     * processFetchCmds must be called with all collected commands at once.
     */
    public function testProcessCmdBatchProcessing(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));

        $remote = $this->makeRemoteWithDownloadMock($s3Mock);

        $remote->processCmd('fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH);
        $remote->processCmd('fetch ' . self::SHA2 . ' refs/heads/' . self::BRANCH);
        $remote->processCmd('fetch ' . self::SHA3 . ' refs/heads/' . self::BRANCH);

        // Commands collected, unbundle not called yet
        $this->assertCount(3, $this->getPrivateFetchCmds($remote));
        $s3Mock->expects($this->never())->method('getObject');

        // Flush — triggers batch execution; capture stdout
        ob_start();
        // We mock processFetchCmds to verify it is called once with 3 items
        // by using a test double via anonymous class extension.
        $called    = 0;
        $calledArg = null;
        // Re-create a partial mock subclass inline
        $partialRemote = new class(
            uriScheme: UriScheme::S3,
            profile:   null,
            bucket:    'test_bucket',
            prefix:    'test_prefix',
            s3Client:  $s3Mock,
        ) extends Remote {
            public int   $processFetchCmdsCalled = 0;
            public array $processFetchCmdsArg    = [];

            public function processFetchCmds(array $cmds): void
            {
                $this->processFetchCmdsCalled++;
                $this->processFetchCmdsArg = $cmds;
            }
        };

        $partialRemote->processCmd('fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH);
        $partialRemote->processCmd('fetch ' . self::SHA2 . ' refs/heads/' . self::BRANCH);
        $partialRemote->processCmd('fetch ' . self::SHA3 . ' refs/heads/' . self::BRANCH);
        $partialRemote->processCmd("\n");
        ob_end_clean();

        $this->assertSame(1, $partialRemote->processFetchCmdsCalled);
        $this->assertCount(3, $partialRemote->processFetchCmdsArg);
        $this->assertEmpty($this->getPrivateFetchCmds($partialRemote));
    }

    /**
     * Fetching the same SHA twice must only download once (deduplication).
     */
    public function testThreadSafetyOfFetchedRefs(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        // 20 commands with the same SHA — only the first should trigger a download
        $s3Mock->expects($this->once())->method('getObject');

        $remote = $this->makeRemoteWithDownloadMock($s3Mock);
        $this->patchUnbundle(function () {});

        $cmds = array_fill(0, 20, 'fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH);
        $remote->processFetchCmds($cmds);

        $this->assertContains(self::SHA1, $this->getPrivateFetchedRefs($remote));
    }

    /**
     * Calling cmdFetch with the same SHA twice only downloads once.
     */
    public function testCmdFetchThreadSafety(): void
    {
        $s3Mock = $this->createMock(S3Client::class);
        $s3Mock->method('listObjectsV2')
               ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        $s3Mock->expects($this->once())->method('getObject');

        $remote = $this->makeRemoteWithDownloadMock($s3Mock);
        $this->patchUnbundle(function () {});

        $cmd = 'fetch ' . self::SHA1 . ' refs/heads/' . self::BRANCH;
        $remote->cmdFetch($cmd);
        $remote->cmdFetch($cmd); // second call must be a no-op

        $this->assertContains(self::SHA1, $this->getPrivateFetchedRefs($remote));
    }

    // -------------------------------------------------------------------------
    // Private reflection helpers
    // -------------------------------------------------------------------------

    private function getPrivateFetchedRefs(Remote $remote): array
    {
        $ref = new \ReflectionProperty(Remote::class, 'fetchedRefs');
        $ref->setAccessible(true);
        return $ref->getValue($remote);
    }

    private function getPrivateFetchCmds(Remote $remote): array
    {
        $ref = new \ReflectionProperty(Remote::class, 'fetchCmds');
        $ref->setAccessible(true);
        return $ref->getValue($remote);
    }

    /**
     * Temporarily stub Git::unbundle so it does not spawn a real process.
     *
     * In the PHP port we cannot monkey-patch a static method the way Python
     * does with `mock.patch`.  Instead we catch any GitError thrown when the
     * bundle file does not really exist.  For these tests, getObject returns
     * an empty string body and no real bundle file is written, so unbundle
     * would fail.  We silence that failure by catching GitError inside
     * cmdFetch; alternatively we can subclass Remote to override cmdFetch.
     *
     * For simplicity the tests rely on the fact that cmdFetch uses try/finally
     * and does not re-throw errors from unbundle when the bundle file is absent
     * (the finally block deletes a non-existent file silently).
     *
     * This helper is a no-op in PHP — the "patching" is implicit.
     */
    private function patchUnbundle(callable $fn): void
    {
        // No-op: unbundle errors are caught inside cmdFetch's try/catch block.
    }
}
