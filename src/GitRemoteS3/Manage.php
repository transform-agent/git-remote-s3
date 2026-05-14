<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

use Aws\S3\S3Client;
use Aws\S3\Exception\S3Exception;
use Aws\Exception\AwsException;

/**
 * Diagnostic and branch-management tool for git-remote-s3 repos.
 *
 * Corresponds to git_remote_s3/manage.py (Doctor + ManageBranch + main()).
 */
class Doctor
{
    private S3Client $s3;

    public function __construct(
        private readonly ?string $profile,
        private readonly string  $bucket,
        private readonly string  $prefix,
        private readonly bool    $deleteBundle,
        private readonly int     $lockTtlSeconds   = 60,
        private readonly bool    $deleteStaleLocks  = false,
        ?S3Client                $s3Client          = null,
    ) {
        if ($s3Client !== null) {
            $this->s3 = $s3Client;
        } else {
            $region = getenv('AWS_DEFAULT_REGION') ?: (getenv('AWS_REGION') ?: 'us-east-1');
            $args = ['version' => 'latest', 'region' => $region];
            if ($profile !== null) {
                $args['profile'] = $profile;
            }
            $this->s3 = new S3Client($args);
        }
    }

    public function run(): void
    {
        $repos = $this->analyzeRepo();
        foreach ($repos as $r => $repoData) {
            echo "{$r}:\n";
            $headRef = 'Invalid';
            foreach ($repoData['refs'] as $ref => $refData) {
                if ($repoData['HEAD'] === $ref) {
                    $headRef = $ref;
                }
                $count = count($refData['bundles']);
                $part1 = $refData['protected'] ? '*' : '';
                $part2 = $count === 1 ? 'Ok' : 'Multiple refs';
                echo " {$part1} {$ref}: {$part2}\n";
            }
            if ($headRef === 'Invalid') {
                $repos[$r]['HEAD'] = $headRef;
            }
            echo "  HEAD: {$headRef}\n";
        }

        $this->fixIssues($repos);
    }

    public function fixIssues(array $repos): void
    {
        foreach ($repos as $r => $repoData) {
            foreach ($repoData['refs'] as $ref => $refData) {
                if (count($refData['bundles']) > 1) {
                    $this->fixMultipleBundles($repos, $r, $ref);
                }
            }
            if ($repoData['HEAD'] === 'Invalid') {
                $this->fixHead($repos, $r);
            }
        }
        $this->listAndHandleStaleLocks();
    }

    public function listAndHandleStaleLocks(): void
    {
        echo "\nScanning for stale locks...\n";

        $objs = $this->s3->listObjectsV2([
            'Bucket' => $this->bucket,
            'Prefix' => $this->prefix . '/',
        ])->get('Contents') ?? [];

        $now   = new \DateTimeImmutable('now', new \DateTimeZone('UTC'));
        $stale = [];
        foreach ($objs as $o) {
            $key = $o['Key'];
            if (str_ends_with($key, '.lock')) {
                /** @var \DateTimeInterface $lastModified */
                $lastModified = $o['LastModified'] ?? null;
                if ($lastModified !== null) {
                    $age = $now->getTimestamp() - $lastModified->getTimestamp();
                    if ($age > $this->lockTtlSeconds) {
                        $stale[] = [$key, (int) $age];
                    }
                }
            }
        }

        if (empty($stale)) {
            echo "No stale locks found.\n";
            return;
        }

        echo "Found stale locks:\n";
        foreach ($stale as [$key, $age]) {
            echo " - {$key} (age: {$age}s)\n";
        }

        if ($this->deleteStaleLocks) {
            echo "\nDeleting stale locks...\n";
            foreach ($stale as [$key]) {
                try {
                    $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $key]);
                    echo "Deleted {$key}\n";
                } catch (S3Exception $e) {
                    echo "Failed to delete {$key}: {$e->getMessage()}\n";
                }
            }
        } else {
            echo "\nRun with --delete-stale-locks to remove them automatically.\n";
        }
    }

    public function analyzeRepo(): array
    {
        $objs = $this->s3->listObjectsV2([
            'Bucket' => $this->bucket,
            'Prefix' => $this->prefix . '/',
        ])->get('Contents') ?? [];

        $repos = [];
        foreach ($objs as $o) {
            $key      = $o['Key'];
            $keyParts = explode('/', $key);
            $repoName = $keyParts[0];
            if (!isset($repos[$repoName])) {
                $repos[$repoName] = ['refs' => [], 'HEAD' => 'Missing'];
            }
            $refs = implode('/', array_slice($keyParts, 1, count($keyParts) - 2));
            if ($keyParts[1] === 'HEAD') {
                $headRef = trim(
                    (string) $this->s3->getObject([
                        'Bucket' => $this->bucket,
                        'Key'    => $key,
                    ])['Body']
                );
                $repos[$repoName]['HEAD'] = $headRef;
                continue;
            }
            if (empty($repos[$repoName]['refs'][$refs])) {
                $repos[$repoName]['refs'][$refs] = ['protected' => false, 'bundles' => []];
            }
            $lastName = end($keyParts);
            if ($lastName === 'PROTECTED#') {
                $repos[$repoName]['refs'][$refs]['protected'] = true;
            } else {
                $sha = explode('.', $lastName)[0];
                $repos[$repoName]['refs'][$refs]['bundles'][] = [
                    'sha'          => $sha,
                    'lastModified' => $o['LastModified'],
                ];
            }
        }
        return $repos;
    }

    public function fixMultipleBundles(array &$repos, string $r, string $ref): void
    {
        echo "\nFix multiple bundles for repo {$r} and ref {$ref}\n";
        $bundles = $repos[$r]['refs'][$ref]['bundles'];
        foreach ($bundles as $i => $sha) {
            echo ($i + 1) . ". {$sha['sha']} {$sha['lastModified']->format(\DateTimeInterface::ATOM)}\n";
        }

        while (true) {
            $input = trim(fgets(STDIN) ?: '');
            if (!ctype_digit($input)) {
                echo "Invalid input\n";
                continue;
            }
            $i = (int) $input;
            if ($i < 1 || $i > count($bundles)) {
                echo "Invalid input\n";
                continue;
            }
            $keepSha = $bundles[$i - 1]['sha'];
            echo "Keeping {$keepSha}\n";
            fgets(STDIN); // wait for confirmation (Enter) or Ctrl+C
            foreach ($bundles as $bundle) {
                $s = $bundle['sha'];
                if ($s === $keepSha) {
                    continue;
                }
                if ($this->deleteBundle) {
                    echo "Removing {$s}\n";
                    $this->s3->deleteObject([
                        'Bucket' => $this->bucket,
                        'Key'    => "{$this->prefix}/{$ref}/{$s}.bundle",
                    ]);
                } else {
                    $tmpBranch = $ref . '_' . substr(uniqid('', true), 0, 8);
                    echo "Moving {$s} to new branch {$tmpBranch}\n";
                    $this->s3->copyObject([
                        'CopySource' => "{$this->bucket}/{$this->prefix}/{$ref}/{$s}.bundle",
                        'Bucket'     => $this->bucket,
                        'Key'        => "{$this->prefix}/{$tmpBranch}/{$s}.bundle",
                    ]);
                    $this->s3->deleteObject([
                        'Bucket' => $this->bucket,
                        'Key'    => "{$this->prefix}/{$ref}/{$s}.bundle",
                    ]);
                }
            }
            break;
        }
    }

    public function fixHead(array &$repos, string $r): void
    {
        echo "\nFix invalid HEAD for repo {$r}\n";
        $heads = array_values(
            array_filter(
                array_keys($repos[$r]['refs']),
                fn(string $k) => str_contains($k, 'heads')
            )
        );
        foreach ($heads as $i => $head) {
            $parts = explode('/', $head);
            echo ($i + 1) . '. ' . end($parts) . "\n";
        }

        while (true) {
            $input = trim(fgets(STDIN) ?: '');
            if (!ctype_digit($input)) {
                echo "Invalid input\n";
                continue;
            }
            $i = (int) $input;
            if ($i < 1 || $i > count($heads)) {
                echo "Invalid input\n";
                continue;
            }
            $head = $heads[$i - 1];
            echo "Setting {$head} as HEAD\n";
            $this->s3->putObject([
                'Bucket' => $this->bucket,
                'Key'    => "{$this->prefix}/HEAD",
                'Body'   => $head,
            ]);
            break;
        }
    }
}

/**
 * Branch management (delete / protect / unprotect).
 *
 * Corresponds to ManageBranch in git_remote_s3/manage.py.
 */
class ManageBranch
{
    private S3Client $s3;

    public function __construct(
        private readonly ?string $profile,
        private readonly string  $bucket,
        private readonly string  $prefix,
        private readonly string  $branch,
        ?S3Client                $s3Client = null,
    ) {
        if ($s3Client !== null) {
            $this->s3 = $s3Client;
        } else {
            $region = getenv('AWS_DEFAULT_REGION') ?: (getenv('AWS_REGION') ?: 'us-east-1');
            $args = ['version' => 'latest', 'region' => $region];
            if ($profile !== null) {
                $args['profile'] = $profile;
            }
            $this->s3 = new S3Client($args);
        }

        if (empty($this->getBranchContent())) {
            throw new \InvalidArgumentException("Branch {$this->branch} does not exist");
        }
    }

    public function processCmd(string $cmd): void
    {
        match ($cmd) {
            'delete-branch' => $this->deleteBranch(),
            'protect'       => $this->protectBranch(),
            'unprotect'     => $this->unprotectBranch(),
            default         => null,
        };
    }

    public function deleteBranch(): void
    {
        $objs = $this->getBranchContent();
        $resp = trim(fgets(STDIN) ?: '');
        if (strtolower($resp) === 'yes') {
            foreach ($objs as $o) {
                $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $o['Key']]);
            }
            echo "Branch {$this->branch} has been deleted\n";
        } else {
            echo "Aborted\n";
        }
    }

    public function getBranchContent(): array
    {
        return $this->s3->listObjectsV2([
            'Bucket' => $this->bucket,
            'Prefix' => "{$this->prefix}/refs/heads/{$this->branch}/",
        ])->get('Contents') ?? [];
    }

    public function protectBranch(): void
    {
        $this->s3->putObject([
            'Bucket' => $this->bucket,
            'Key'    => "{$this->prefix}/refs/heads/{$this->branch}/PROTECTED#",
            'Body'   => '',
        ]);
        echo "Branch {$this->branch} is now protected\n";
    }

    public function unprotectBranch(): void
    {
        $this->s3->deleteObject([
            'Bucket' => $this->bucket,
            'Key'    => "{$this->prefix}/refs/heads/{$this->branch}/PROTECTED#",
        ]);
        echo "Branch {$this->branch} is now unprotected\n";
    }
}

// ---------------------------------------------------------------------------
// Entry-point
// ---------------------------------------------------------------------------

/**
 * Main function for git-s3 management CLI.
 *
 * Corresponds to git_remote_s3.manage:main().
 */
function manageMain(): void
{
    global $argv;

    // Minimal argument parser — mirrors the Python argparse setup:
    //   git-s3 <command> <remote> [-d|--delete-bundle] [--lock-ttl N]
    //          [--delete-stale-locks] <branch>
    $opts = getopt(
        'd',
        ['delete-bundle', 'lock-ttl:', 'delete-stale-locks'],
        $restIndex
    );

    $positional   = array_slice($argv, $restIndex);
    $command      = $positional[0] ?? null;
    $remote       = $positional[1] ?? null;
    $branch       = $positional[2] ?? null;

    $deleteBundle     = isset($opts['d']) || isset($opts['delete-bundle']);
    $lockTtl          = isset($opts['lock-ttl']) ? (int) $opts['lock-ttl'] : DEFAULT_LOCK_TTL_SECONDS;
    $deleteStaleLocks = isset($opts['delete-stale-locks']);

    if ($command === null || $remote === null) {
        fwrite(STDERR, "usage: git-s3 <command> <remote> [options] [branch]\n");
        exit(1);
    }

    try {
        $remoteUrl = Git::getRemoteUrl($remote);
    } catch (GitError $e) {
        fwrite(STDERR, "fatal: {$e->getMessage()}\n");
        fflush(STDERR);
        exit(1);
    }

    [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($remoteUrl);

    try {
        if ($command === 'doctor') {
            $doctor = new Doctor(
                $profile,
                $bucket,
                $prefix,
                $deleteBundle,
                $lockTtl,
                $deleteStaleLocks,
            );
            $doctor->run();
        } elseif (in_array($command, ['delete-branch', 'protect', 'unprotect'], true)) {
            if ($branch === null) {
                fwrite(STDERR, "fatal: branch argument is required\n");
                fflush(STDERR);
                exit(1);
            }
            try {
                $manageBranch = new ManageBranch($profile, $bucket, $prefix, $branch);
                $manageBranch->processCmd($command);
            } catch (\InvalidArgumentException $e) {
                fwrite(STDERR, "fatal: {$e->getMessage()}\n");
                fflush(STDERR);
                exit(1);
            }
        }
        exit(0);
    } catch (AwsException $e) {
        fwrite(STDERR, "fatal: invalid credentials {$e->getMessage()}\n");
        fflush(STDERR);
        exit(1);
    }
}
