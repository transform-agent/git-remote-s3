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

/**
 * Shared test helpers.
 */
trait S3TestHelpers
{
    /**
     * Build a mock S3Client stub whose listObjectsV2 returns the given keys.
     *
     * @param string[] $shas        SHA hex strings for bundles under refs/heads/<branch>/<sha>.bundle
     * @param string   $branch      Branch name (default: 'pytest')
     * @param bool     $protected   Whether to include a PROTECTED# object
     * @param bool     $noHead      When true, omit the HEAD object
     */
    protected function makeS3Mock(
        array  $shas,
        string $branch    = 'pytest',
        bool   $protected = false,
        bool   $noHead    = false,
    ): \PHPUnit\Framework\MockObject\MockObject {
        $mock = $this->createMock(S3Client::class);

        $mock->method('listObjectsV2')
             ->willReturnCallback(function (array $args) use ($shas, $branch, $protected, $noHead): Result {
                 $prefix  = $args['Prefix'];
                 $content = [];

                 foreach ($shas as $sha) {
                     $key = "test_prefix/refs/heads/{$branch}/{$sha}.bundle";
                     if (str_starts_with($key, $prefix)) {
                         $content[] = ['Key' => $key, 'LastModified' => new \DateTimeImmutable()];
                     }
                 }

                 if ($protected) {
                     $key = "test_prefix/refs/heads/{$branch}/PROTECTED#";
                     if (str_starts_with($key, $prefix)) {
                         $content[] = ['Key' => $key, 'LastModified' => new \DateTimeImmutable()];
                     }
                 }

                 if (!$noHead) {
                     $key = 'test_prefix/HEAD';
                     if (str_starts_with($key, $prefix)) {
                         $content[] = ['Key' => $key, 'LastModified' => new \DateTimeImmutable()];
                     }
                 }

                 return new Result([
                     'Contents'              => $content,
                     'NextContinuationToken' => null,
                 ]);
             });

        return $mock;
    }

    /**
     * Build a Remote instance injecting a pre-built S3 mock.
     */
    protected function makeRemote(
        UriScheme $uriScheme = UriScheme::S3,
        string    $bucket    = 'test_bucket',
        string    $prefix    = 'test_prefix',
        ?S3Client $s3Client  = null,
    ): Remote {
        // If no mock provided, create a minimal one that allows construction.
        if ($s3Client === null) {
            $s3Client = $this->createMock(S3Client::class);
            $s3Client->method('listObjectsV2')
                     ->willReturn(new Result(['Contents' => [], 'NextContinuationToken' => null]));
        }
        return new Remote(
            uriScheme: $uriScheme,
            profile:   null,
            bucket:    $bucket,
            prefix:    $prefix,
            s3Client:  $s3Client,
        );
    }
}
