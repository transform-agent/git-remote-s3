<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

use Aws\S3\S3Client;
use Aws\S3\Exception\S3Exception;
use Aws\Exception\AwsException;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;

/**
 * Exception thrown when the target S3 bucket does not exist.
 */
class BucketNotFoundError extends \RuntimeException
{
    public function __construct(public readonly string $bucket)
    {
        parent::__construct("Bucket {$bucket} not found.");
    }
}

/**
 * Exception thrown when the caller is not authorised to perform an S3 action.
 */
class NotAuthorizedError extends \RuntimeException
{
    public function __construct(
        public readonly string $action,
        public readonly string $bucket
    ) {
        parent::__construct(
            "Not authorized to perform {$action} on the S3 bucket {$bucket}."
        );
    }
}

/**
 * Modes for the remote helper protocol.
 */
class Mode
{
    public const FETCH = 'fetch';
    public const PUSH  = 'push';
}

/**
 * Default TTL (seconds) for per-ref S3 lock objects.
 */
const DEFAULT_LOCK_TTL_SECONDS = 60;

/**
 * Core git-remote-s3 remote helper.
 *
 * Corresponds to git_remote_s3/remote.py (S3Remote class + main()).
 *
 * NOTE: Parallel fetch is not implemented in PHP (no standard native threads).
 *       Fetches are executed sequentially.  This is a correctness-preserving
 *       simplification; performance may differ from the Python version.
 *
 * Git interaction
 * ---------------
 * Rather than calling Git:: static methods directly throughout the class,
 * all git operations are routed through protected methods (gitRevParse, etc.).
 * This lets subclasses (used in tests) replace those methods with stubs
 * without spawning real processes.
 */
class Remote
{
    private S3Client $s3;
    private ?string $mode      = null;
    /** @var string[] */
    private array $fetchCmds   = [];
    /** @var string[] */
    private array $pushCmds    = [];
    /** @var string[] */
    private array $fetchedRefs = [];
    public  int   $lockTtlSeconds;

    private Logger $logger;

    /**
     * @param UriScheme   $uriScheme
     * @param string|null $profile
     * @param string      $bucket
     * @param string      $prefix
     * @param S3Client|null $s3Client  Inject a pre-built client (used in tests)
     */
    public function __construct(
        public readonly UriScheme $uriScheme,
        public readonly ?string   $profile,
        public readonly string    $bucket,
        public readonly string    $prefix,
        ?S3Client                 $s3Client = null,
    ) {
        $this->logger = new Logger('git-remote-s3');
        $logLevel = $this->resolveLogLevel();
        $this->logger->pushHandler(new StreamHandler(STDERR, $logLevel));

        if ($s3Client !== null) {
            $this->s3 = $s3Client;
        } else {
            $this->s3 = $this->buildS3Client();
        }

        // Validate bucket accessibility
        try {
            $this->s3->listObjectsV2([
                'Bucket' => $bucket,
                'Prefix' => $prefix,
            ]);
        } catch (S3Exception $e) {
            $code = $e->getAwsErrorCode();
            if ($code === 'NoSuchBucket') {
                throw new BucketNotFoundError($bucket);
            }
            if ($code === 'AccessDenied') {
                throw new NotAuthorizedError('ListObjectsV2', $bucket);
            }
            throw $e;
        }

        // Lock TTL: env var > default
        $envTtl = getenv('GIT_REMOTE_S3_LOCK_TTL_SECONDS');
        $this->lockTtlSeconds = ($envTtl !== false && is_numeric($envTtl))
            ? (int) $envTtl
            : DEFAULT_LOCK_TTL_SECONDS;
    }

    // =========================================================================
    // Protected Git wrappers (override in tests via subclassing)
    // =========================================================================

    protected function gitRevParse(string $ref): string
    {
        return Git::revParse($ref);
    }

    protected function gitBundle(string $folder, string $sha, string $ref): string
    {
        return Git::bundle($folder, $sha, $ref);
    }

    protected function gitIsAncestor(string $ancestor, string $descendant): bool
    {
        return Git::isAncestor($ancestor, $descendant);
    }

    protected function gitUnbundle(string $folder, string $sha, string $ref): void
    {
        Git::unbundle($folder, $sha, $ref);
    }

    protected function gitArchive(string $folder, string $ref): string
    {
        return Git::archive($folder, $ref);
    }

    protected function gitGetLastCommitMessage(): string
    {
        return Git::getLastCommitMessage();
    }

    // =========================================================================
    // Public API used by the entry-point and tests
    // =========================================================================

    /**
     * List all refs available on the remote.
     *
     * @return string[]  Paths relative to $prefix, e.g. "refs/heads/main/<sha>.bundle"
     */
    public function listRefs(string $bucket, string $prefix): array
    {
        $contents      = [];
        $nextToken     = null;

        do {
            $params = ['Bucket' => $bucket, 'Prefix' => $prefix];
            if ($nextToken !== null) {
                $params['ContinuationToken'] = $nextToken;
            }
            $res       = $this->s3->listObjectsV2($params);
            $contents  = array_merge($contents, $res->get('Contents') ?? []);
            $nextToken = $res->get('NextContinuationToken') ?? null;
        } while ($nextToken !== null);

        // Sort descending by LastModified
        usort($contents, fn($a, $b) => $b['LastModified'] <=> $a['LastModified']);

        $prefixSlash = $prefix . '/';
        $objs = [];
        foreach ($contents as $o) {
            $key = $o['Key'];
            if (str_starts_with($key, $prefixSlash . 'refs') && str_ends_with($key, '.bundle')) {
                // Strip leading "<prefix>/"
                $objs[] = substr($key, strlen($prefixSlash));
            }
        }
        return $objs;
    }

    /**
     * Execute a single fetch command.
     *
     * @param string $args  e.g. "fetch <sha> refs/heads/main"
     */
    public function cmdFetch(string $args): void
    {
        $parts = explode(' ', trim($args));
        // format: fetch <sha> <ref>
        $sha = $parts[1];
        $ref = $parts[2];

        if (in_array($sha, $this->fetchedRefs, true)) {
            return;
        }

        $this->logger->info("fetch {$sha} {$ref}");

        $tempDir = sys_get_temp_dir() . '/git_remote_s3_fetch_' . uniqid('', true);
        mkdir($tempDir, 0700, true);
        $bundlePath = "{$tempDir}/{$sha}.bundle";

        try {
            $this->s3->getObject([
                'Bucket' => $this->bucket,
                'Key'    => "{$this->prefix}/{$ref}/{$sha}.bundle",
                'SaveAs' => $bundlePath,
            ]);

            $this->logger->info("fetched {$bundlePath} {$ref}");
            $this->gitUnbundle($tempDir, $sha, $ref);

            $this->fetchedRefs[] = $sha;
        } catch (S3Exception $e) {
            if ($e->getAwsErrorCode() === 'AccessDenied') {
                throw new NotAuthorizedError('GetObject', $this->bucket);
            }
            throw $e;
        } finally {
            if (file_exists($bundlePath)) {
                unlink($bundlePath);
            }
            if (is_dir($tempDir)) {
                @rmdir($tempDir);
            }
        }
    }

    /**
     * Process a push command and return the result line.
     *
     * @param string $args  e.g. "push refs/heads/main:refs/heads/main"
     * @return string
     */
    public function cmdPush(string $args): string
    {
        $parts    = explode(' ', trim($args));
        $refPair  = $parts[1]; // "local:remote" or ":remote" for delete

        [$localRef, $remoteRef] = explode(':', $refPair, 2);

        if ($localRef === '') {
            return $this->removeRemoteRef($remoteRef);
        }

        $forcePush = false;
        if (str_starts_with($localRef, '+')) {
            $localRef  = substr($localRef, 1);
            $forcePush = !$this->isProtected($remoteRef);
            $this->logger->info("Force push {$forcePush}");
        }

        $this->logger->info("push !{$localRef}! !{$remoteRef}!");

        $tempDir = sys_get_temp_dir() . '/git_remote_s3_push_' . uniqid('', true);
        mkdir($tempDir, 0700, true);

        $contents = $this->getBundlesForRef($remoteRef);
        if (count($contents) > 1) {
            return "error {$remoteRef} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n";
        }

        $remoteToRemove = count($contents) === 1 ? $contents[0]['Key'] : null;
        $sha     = null;
        $lockKey = null;

        try {
            $sha = $this->gitRevParse($localRef);

            if ($remoteToRemove !== null) {
                $remoteSha = explode('.', basename($remoteToRemove))[0];
                if (!$forcePush && !$this->gitIsAncestor($remoteSha, $sha)) {
                    return "error {$remoteRef} \"remote ref is not ancestor of {$localRef}.\"?\n";
                }
            }

            // Create the bundle before acquiring the lock (local operation)
            $tempFile = $this->gitBundle($tempDir, $sha, $localRef);

            // Acquire per-ref lock
            $lockKey = $this->acquireLock($remoteRef);
            if ($lockKey === null) {
                $lockPath = "{$this->prefix}/{$remoteRef}/LOCK#.lock";
                return
                    "error {$remoteRef} " .
                    "\"failed to acquire ref lock at {$lockPath}. " .
                    "Another client may be pushing. If this persists beyond {$this->lockTtlSeconds}s, " .
                    "run git-remote-s3 doctor --lock-ttl {$this->lockTtlSeconds} to inspect and optionally clear stale locks.\"?\n";
            }

            // Re-check bundles after acquiring lock
            $currentContents = $this->getBundlesForRef($remoteRef);
            if (count($currentContents) > 1) {
                return "error {$remoteRef} \"multiple bundles exists for the same ref on server. Run git-s3 doctor to fix. Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n";
            }

            $currentRemoteToRemove = count($currentContents) === 1 ? $currentContents[0]['Key'] : null;
            if (
                $remoteToRemove !== null &&
                $currentRemoteToRemove !== null &&
                $currentRemoteToRemove !== $remoteToRemove
            ) {
                return "error {$remoteRef} \"stale remote. Please fetch and retry.\"?\n";
            }

            // Upload the bundle
            $body = fopen($tempFile, 'rb');
            $this->s3->putObject([
                'Bucket' => $this->bucket,
                'Key'    => "{$this->prefix}/{$remoteRef}/{$sha}.bundle",
                'Body'   => $body,
            ]);
            if (is_resource($body)) {
                fclose($body);
            }

            $this->initRemoteHead($remoteRef);
            $this->logger->info("pushed {$tempFile} to {$remoteRef}");

            if ($remoteToRemove !== null) {
                $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $remoteToRemove]);
            }

            // S3_ZIP: also upload a repo.zip archive
            if ($this->uriScheme === UriScheme::S3_ZIP) {
                $commitMsg       = $this->gitGetLastCommitMessage();
                $tempFileArchive = $this->gitArchive($tempDir, $localRef);
                $archiveBody     = fopen($tempFileArchive, 'rb');
                $this->s3->putObject([
                    'Bucket'             => $this->bucket,
                    'Key'                => "{$this->prefix}/{$remoteRef}/repo.zip",
                    'Body'               => $archiveBody,
                    'Metadata'           => [
                        'codepipeline-artifact-revision-summary' => $commitMsg,
                    ],
                    'ContentDisposition' => 'attachment; filename=repo-' . substr($sha, 0, 8) . '.zip',
                ]);
                if (is_resource($archiveBody)) {
                    fclose($archiveBody);
                }
                $this->logger->info(
                    "pushed {$tempFileArchive} to {$this->prefix}/{$remoteRef}/repo.zip with message {$commitMsg}"
                );
            }

            return "ok {$remoteRef}\n";

        } catch (GitError $e) {
            $this->logger->info("fatal: {$localRef} not found");
            return "error {$remoteRef} \"{$localRef} not found\"?\n";
        } catch (AwsException $e) {
            $this->logger->info("fatal: {$e->getMessage()}");
            return "error {$remoteRef} \"{$e->getMessage()}\"?\n";
        } finally {
            if ($lockKey !== null) {
                try {
                    $this->releaseLock($remoteRef, $lockKey);
                } catch (\Exception $e) {
                    $this->logger->info("failed to release lock {$lockKey} for {$remoteRef}: {$e->getMessage()}");
                }
            }
            if ($sha !== null && file_exists("{$tempDir}/{$sha}.bundle")) {
                unlink("{$tempDir}/{$sha}.bundle");
            }
            if (is_dir($tempDir)) {
                @rmdir($tempDir);
            }
        }
    }

    /**
     * Announce capabilities to git.
     */
    public function cmdCapabilities(): void
    {
        fwrite(STDOUT, "*push\n");
        fwrite(STDOUT, "*fetch\n");
        fwrite(STDOUT, "option\n");
        fwrite(STDOUT, "\n");
    }

    /**
     * List refs on the remote, optionally for a push operation.
     */
    public function cmdList(bool $forPush = false): void
    {
        $objs = $this->listRefs($this->bucket, $this->prefix);
        $this->logger->info(implode(', ', $objs));

        if (!$forPush) {
            try {
                $head = $this->getRemoteHead();
                $this->logger->info("HEAD=[{$head}]");
                foreach ($objs as $o) {
                    $elements = explode('/', $o);
                    $ref      = implode('/', array_slice($elements, 0, -1));
                    if ($ref === $head) {
                        $this->logger->info("@{$ref} HEAD");
                        fwrite(STDOUT, "@{$ref} HEAD\n");
                    }
                }
            } catch (S3Exception $e) {
                if ($e->getAwsErrorCode() === 'NoSuchKey') {
                    // Ignore missing HEAD on remote
                } else {
                    throw $e;
                }
            }
        }

        foreach ($objs as $o) {
            // Only output refs matching the pattern: .+/.+/.+/<40-hex>.bundle
            if (preg_match('/^.+\/.+\/.+\/[a-f0-9]{40}\.bundle$/', $o)) {
                $elements = explode('/', $o);
                $sha      = explode('.', $elements[count($elements) - 1])[0];
                fwrite(STDOUT, $sha . ' ' . implode('/', array_slice($elements, 0, -1)) . "\n");
            }
        }

        fwrite(STDOUT, "\n");
    }

    /**
     * Handle the "option" command.
     */
    public function cmdOption(string $arg): void
    {
        $parts  = explode(' ', trim($arg));
        $option = $parts[1];
        $value  = $parts[2];

        if ($option === 'verbosity' && (int) $value >= 2) {
            foreach ($this->logger->getHandlers() as $handler) {
                $handler->setLevel(Logger::INFO);
            }
            fwrite(STDOUT, "ok\n");
        } else {
            fwrite(STDOUT, "unsupported\n");
        }
    }

    /**
     * Process a single command line from the git remote helper protocol.
     *
     * @param string $cmd  Raw line as received from stdin
     */
    public function processCmd(string $cmd): void
    {
        if (str_starts_with($cmd, 'fetch')) {
            if ($this->mode !== Mode::FETCH) {
                $this->mode      = Mode::FETCH;
                $this->fetchCmds = [];
            }
            $this->fetchCmds[] = trim($cmd);

        } elseif (str_starts_with($cmd, 'push')) {
            if ($this->mode !== Mode::PUSH) {
                $this->mode     = Mode::PUSH;
                $this->pushCmds = [];
            }
            $this->pushCmds[] = trim($cmd);

        } elseif (str_starts_with($cmd, 'option')) {
            $this->cmdOption(trim($cmd));

        } elseif (str_starts_with($cmd, 'list for-push')) {
            $this->cmdList(forPush: true);

        } elseif (str_starts_with($cmd, 'list')) {
            $this->cmdList();

        } elseif (str_starts_with($cmd, 'capabilities')) {
            $this->cmdCapabilities();

        } elseif ($cmd === "\n") {
            $this->logger->info('empty line');

            if ($this->mode === Mode::PUSH && !empty($this->pushCmds)) {
                $this->logger->info('pushing ' . implode(', ', $this->pushCmds));
                foreach ($this->pushCmds as $c) {
                    fwrite(STDOUT, $this->cmdPush($c));
                }
                $this->pushCmds = [];
            } elseif ($this->mode === Mode::FETCH && !empty($this->fetchCmds)) {
                $this->logger->info('fetching ' . count($this->fetchCmds) . ' refs');
                $this->processFetchCmds($this->fetchCmds);
                $this->fetchCmds = [];
            }

            fwrite(STDOUT, "\n");

        } else {
            fwrite(STDERR, "fatal: invalid command '{$cmd}'\n");
            exit(1);
        }
    }

    /**
     * Process a batch of fetch commands.
     *
     * NOTE: In the Python implementation this is done in parallel via
     * ThreadPoolExecutor.  PHP lacks standard native threads, so commands
     * are executed sequentially here.
     *
     * @param string[] $cmds
     */
    public function processFetchCmds(array $cmds): void
    {
        if (empty($cmds)) {
            return;
        }
        $this->logger->info('Processing ' . count($cmds) . ' fetch commands');
        foreach ($cmds as $cmd) {
            $this->cmdFetch($cmd);
        }
        $this->logger->info('Completed processing ' . count($cmds) . ' fetch commands');
    }

    // =========================================================================
    // Lock helpers
    // =========================================================================

    /**
     * Acquire a per-ref lock using S3 conditional writes (IfNoneMatch: *).
     *
     * Returns the lock key on success, or null if the lock could not be acquired.
     */
    public function acquireLock(string $remoteRef): ?string
    {
        $lockKey = "{$this->prefix}/{$remoteRef}/LOCK#.lock";
        try {
            $this->s3->putObject([
                'Bucket'      => $this->bucket,
                'Key'         => $lockKey,
                'Body'        => '',
                'IfNoneMatch' => '*',
            ]);
            return $lockKey;
        } catch (S3Exception $e) {
            $statusCode = $e->getStatusCode();
            $awsCode    = $e->getAwsErrorCode();

            if ($statusCode === 412 || in_array($awsCode, ['PreconditionFailed', '412'], true)) {
                // Existing lock — check staleness
                try {
                    $head         = $this->s3->headObject(['Bucket' => $this->bucket, 'Key' => $lockKey]);
                    $lastModified = $head['LastModified'] ?? null;
                    if ($lastModified instanceof \DateTimeInterface) {
                        $now = new \DateTimeImmutable('now', $lastModified->getTimezone());
                        $age = $now->getTimestamp() - $lastModified->getTimestamp();
                        if ($age > $this->lockTtlSeconds) {
                            // Stale — delete and retry
                            $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $lockKey]);
                            $this->s3->putObject([
                                'Bucket'      => $this->bucket,
                                'Key'         => $lockKey,
                                'Body'        => '',
                                'IfNoneMatch' => '*',
                            ]);
                            return $lockKey;
                        }
                    }
                } catch (S3Exception $inner) {
                    $this->logger->info("failed to check staleness of {$lockKey}: {$inner->getMessage()}");
                    throw $inner;
                }
                return null;
            }
            throw $e;
        }
    }

    /**
     * Release a previously acquired lock.
     */
    public function releaseLock(string $remoteRef, string $lockKey): void
    {
        try {
            $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $lockKey]);
        } catch (S3Exception $e) {
            if ($e->getStatusCode() === 404) {
                $this->logger->info("lock {$lockKey} already released");
            } else {
                throw $e;
            }
        }
    }

    // =========================================================================
    // Accessors used by tests / manage
    // =========================================================================

    public function getS3Client(): S3Client
    {
        return $this->s3;
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    private function buildS3Client(): S3Client
    {
        $args = ['version' => 'latest', 'region' => $this->resolveRegion()];
        if ($this->profile !== null) {
            $args['profile'] = $this->profile;
        }
        return new S3Client($args);
    }

    private function resolveRegion(): string
    {
        return getenv('AWS_DEFAULT_REGION') ?: (getenv('AWS_REGION') ?: 'us-east-1');
    }

    private function resolveLogLevel(): int
    {
        $verbose = getenv('GIT_REMOTE_S3_VERBOSE');
        if ($verbose !== false && in_array(strtolower($verbose), ['1', 'true', 'yes'], true)) {
            return Logger::INFO;
        }
        return Logger::ERROR;
    }

    /**
     * Remove a remote ref (used by "push :ref").
     */
    private function removeRemoteRef(string $remoteRef): string
    {
        $this->logger->info("Removing remote ref {$remoteRef}");
        try {
            $objectsToDelete = $this->s3->listObjectsV2([
                'Bucket' => $this->bucket,
                'Prefix' => "{$this->prefix}/{$remoteRef}/",
            ])->get('Contents') ?? [];

            $count = count($objectsToDelete);
            $allowedCount = $this->uriScheme === UriScheme::S3 ? 1 : 2;

            if ($count === $allowedCount) {
                foreach ($objectsToDelete as $object) {
                    $this->s3->deleteObject(['Bucket' => $this->bucket, 'Key' => $object['Key']]);
                }
                return "ok {$remoteRef}\n";
            } elseif ($count === 0) {
                return "error {$remoteRef} not found\n";
            } else {
                return "error {$remoteRef} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n";
            }
        } catch (S3Exception $e) {
            if ($e->getStatusCode() === 404) {
                return "error {$remoteRef} not found\n";
            }
            throw $e;
        }
    }

    /**
     * Initialise the remote HEAD if it does not exist yet.
     */
    private function initRemoteHead(string $ref): void
    {
        try {
            $this->s3->headObject(['Bucket' => $this->bucket, 'Key' => "{$this->prefix}/HEAD"]);
        } catch (S3Exception $e) {
            // HEAD does not exist — create it
            $this->s3->putObject([
                'Bucket' => $this->bucket,
                'Key'    => "{$this->prefix}/HEAD",
                'Body'   => $ref,
            ]);
        }
    }

    /**
     * List all bundle objects for a given remote ref (excludes PROTECTED#, .zip, locks).
     *
     * @return array<int, array{Key: string, LastModified: \DateTimeInterface}>
     */
    public function getBundlesForRef(string $remoteRef): array
    {
        $contents = $this->s3->listObjectsV2([
            'Bucket' => $this->bucket,
            'Prefix' => "{$this->prefix}/{$remoteRef}/",
        ])->get('Contents') ?? [];

        return array_values(array_filter($contents, function (array $c): bool {
            $key = $c['Key'];
            return
                !str_contains($key, 'PROTECTED#') &&
                !str_ends_with($key, '.zip')       &&
                !str_contains($key, '/LOCKS/')     &&
                !str_ends_with($key, '.lock');
        }));
    }

    /**
     * Check whether a remote ref is protected.
     */
    public function isProtected(string $remoteRef): bool
    {
        $protected = $this->s3->listObjectsV2([
            'Bucket' => $this->bucket,
            'Prefix' => "{$this->prefix}/{$remoteRef}/PROTECTED#",
        ])->get('Contents') ?? [];

        return !empty($protected);
    }

    /**
     * Read the remote HEAD value from S3.
     */
    public function getRemoteHead(): string
    {
        $result = $this->s3->getObject([
            'Bucket' => $this->bucket,
            'Key'    => "{$this->prefix}/HEAD",
        ]);
        return trim((string) $result['Body']);
    }
}

// ---------------------------------------------------------------------------
// Entry-point
// ---------------------------------------------------------------------------

/**
 * Main function for the git-remote-s3 / git-remote-s3+zip helper.
 *
 * Corresponds to git_remote_s3.remote:main().
 */
function main(): void
{
    global $argv;

    // Disable output buffering so git sees our responses immediately.
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    ob_implicit_flush(true);

    $logger = new Logger('git-remote-s3-main');
    $logger->pushHandler(new StreamHandler(STDERR, Logger::INFO));

    $logger->info(implode(' ', $argv));

    if (!isset($argv[2])) {
        fwrite(STDERR, "fatal: usage: git-remote-s3 <name> <url>\n");
        exit(1);
    }

    $remote = $argv[2];
    [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($remote);

    if ($bucket === null || $prefix === null) {
        fwrite(STDERR, "fatal: invalid remote '{$remote}'. You need to have a bucket and a prefix.\n");
        exit(1);
    }

    try {
        $s3Remote = new Remote(
            uriScheme: $uriScheme,
            profile:   $profile,
            bucket:    $bucket,
            prefix:    $prefix,
        );

        while (true) {
            $line = fgets(STDIN);
            if ($line === false) {
                break;
            }
            $logger->info("cmd: {$line}");
            $s3Remote->processCmd($line);
        }

    } catch (\Exception $e) {
        if ($e instanceof BucketNotFoundError) {
            fwrite(STDERR, "fatal: bucket not found {$e->bucket}\n");
            exit(1);
        }
        if ($e instanceof NotAuthorizedError) {
            fwrite(STDERR, "fatal: user not authorized to perform {$e->action} on {$e->bucket}\n");
            exit(1);
        }
        if ($e instanceof AwsException) {
            fwrite(STDERR, "fatal: invalid credentials {$e->getMessage()}\n");
            exit(1);
        }
        $logger->info($e->getMessage());
        fwrite(STDERR, "fatal: unknown error. Run with --verbose flag to get full log\n");
        exit(1);
    }
}
