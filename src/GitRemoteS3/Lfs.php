<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

use Aws\S3\S3Client;
use Aws\S3\Exception\S3Exception;
use Monolog\Logger;
use Monolog\Handler\StreamHandler;

/**
 * Git LFS custom-transfer agent for Amazon S3.
 *
 * Corresponds to git_remote_s3/lfs.py.
 *
 * Protocol reference:
 *   https://github.com/git-lfs/git-lfs/blob/main/docs/custom-transfers.md
 *
 * NOTE: The Python implementation uses a threading.Lock for progress callbacks.
 *       PHP does not have native threads in the standard SAPI; progress events
 *       are therefore emitted without locking (safe in a single-threaded CLI).
 */
class Lfs
{
    private string   $prefix;
    private string   $bucket;
    private ?string  $profile;
    private S3Client $s3;

    private Logger $logger;

    public function __construct(string $s3Uri)
    {
        $this->logger = new Logger('git-lfs-s3');
        // Log to file — same path as Python implementation
        $logFile = '.git/lfs/tmp/git-lfs-s3.log';
        if (!is_dir(dirname($logFile))) {
            @mkdir(dirname($logFile), 0755, true);
        }
        try {
            $this->logger->pushHandler(new StreamHandler($logFile, Logger::ERROR));
        } catch (\Exception $e) {
            // If we cannot open the log file, silently continue
        }

        [$uriScheme, $profile, $bucket, $prefix] = Common::parseGitUrl($s3Uri);

        if ($bucket === null || $prefix === null) {
            $this->logger->error("s3 uri {$s3Uri} is invalid");
            $errorEvent = ['error' => ['code' => 32, 'message' => "s3 uri {$s3Uri} is invalid"]];
            fwrite(STDOUT, json_encode($errorEvent) . "\n");
            fflush(STDOUT);
            return;
        }

        $this->prefix  = $prefix;
        $this->bucket  = $bucket;
        $this->profile = $profile;

        // Send the initialisation acknowledgement expected by git-lfs
        fwrite(STDOUT, "{}\n");
        fflush(STDOUT);

        // Build S3 client lazily — done inline so tests can subclass
        $this->initS3Client();
    }

    private function initS3Client(): void
    {
        $region = getenv('AWS_DEFAULT_REGION') ?: (getenv('AWS_REGION') ?: 'us-east-1');
        $args = ['version' => 'latest', 'region' => $region];
        if ($this->profile !== null) {
            $args['profile'] = $this->profile;
        }
        $this->s3 = new S3Client($args);
    }

    // -------------------------------------------------------------------------
    // Upload / Download
    // -------------------------------------------------------------------------

    /**
     * Handle an LFS "upload" event.
     *
     * @param array{oid: string, path: string, size?: int} $event
     */
    public function upload(array $event): void
    {
        $this->logger->debug('upload');
        $oid = $event['oid'];
        try {
            // Check if object already exists
            $existing = $this->s3->listObjectsV2([
                'Bucket' => $this->bucket,
                'Prefix' => "{$this->prefix}/lfs/{$oid}",
            ])->get('Contents') ?? [];

            if (!empty($existing)) {
                $this->logger->debug('object already exists');
                fwrite(STDOUT, json_encode(['event' => 'complete', 'oid' => $oid]) . "\n");
                fflush(STDOUT);
                return;
            }

            // Upload with progress
            $bytesSoFar = 0;
            $this->s3->putObject([
                'Bucket'         => $this->bucket,
                'Key'            => "{$this->prefix}/lfs/{$oid}",
                'SourceFile'     => $event['path'],
                '@http'          => [
                    'progress' => function (
                        int $downloadTotal,
                        int $downloaded,
                        int $uploadTotal,
                        int $uploaded
                    ) use ($oid, &$bytesSoFar): void {
                        if ($uploaded > 0) {
                            $bytesSinceLast = $uploaded - $bytesSoFar;
                            if ($bytesSinceLast > 0) {
                                $bytesSoFar = $uploaded;
                                $progressEvent = [
                                    'event'          => 'progress',
                                    'oid'            => $oid,
                                    'bytesSoFar'     => $bytesSoFar,
                                    'bytesSinceLast' => $bytesSinceLast,
                                ];
                                fwrite(STDOUT, json_encode($progressEvent) . "\n");
                                fflush(STDOUT);
                            }
                        }
                    },
                ],
            ]);

            fwrite(STDOUT, json_encode(['event' => 'complete', 'oid' => $oid]) . "\n");
        } catch (\Exception $e) {
            $this->logger->error($e->getMessage());
            self::writeErrorEvent($oid, $e->getMessage());
        }
        fflush(STDOUT);
    }

    /**
     * Handle an LFS "download" event.
     *
     * @param array{oid: string} $event
     */
    public function download(array $event): void
    {
        $this->logger->debug('download');
        $oid     = $event['oid'];
        $tempDir = realpath('.git/lfs/tmp') ?: sys_get_temp_dir();
        $dest    = "{$tempDir}/{$oid}";

        try {
            $bytesSoFar = 0;
            $this->s3->getObject([
                'Bucket'  => $this->bucket,
                'Key'     => "{$this->prefix}/lfs/{$oid}",
                'SaveAs'  => $dest,
                '@http'   => [
                    'progress' => function (
                        int $downloadTotal,
                        int $downloaded,
                        int $uploadTotal,
                        int $uploaded
                    ) use ($oid, &$bytesSoFar): void {
                        if ($downloaded > 0) {
                            $bytesSinceLast = $downloaded - $bytesSoFar;
                            if ($bytesSinceLast > 0) {
                                $bytesSoFar = $downloaded;
                                $progressEvent = [
                                    'event'          => 'progress',
                                    'oid'            => $oid,
                                    'bytesSoFar'     => $bytesSoFar,
                                    'bytesSinceLast' => $bytesSinceLast,
                                ];
                                fwrite(STDOUT, json_encode($progressEvent) . "\n");
                                fflush(STDOUT);
                            }
                        }
                    },
                ],
            ]);

            $doneEvent = ['event' => 'complete', 'oid' => $oid, 'path' => $dest];
            fwrite(STDOUT, json_encode($doneEvent) . "\n");
        } catch (\Exception $e) {
            $this->logger->error($e->getMessage());
            self::writeErrorEvent($oid, $e->getMessage());
        }
        fflush(STDOUT);
    }

    // -------------------------------------------------------------------------
    // Static helpers
    // -------------------------------------------------------------------------

    public static function writeErrorEvent(string $oid, string $error, bool $flush = false): void
    {
        $errEvent = [
            'event' => 'complete',
            'oid'   => $oid,
            'error' => ['code' => 2, 'message' => $error],
        ];
        fwrite(STDOUT, json_encode($errEvent) . "\n");
        if ($flush) {
            fflush(STDOUT);
        }
    }

    /**
     * Install git-lfs-s3 as the custom transfer agent in the current repo.
     */
    public static function install(): void
    {
        exec(
            'git config --add lfs.customtransfer.git-lfs-s3.path git-lfs-s3',
            $output,
            $code
        );
        if ($code !== 0) {
            fwrite(STDERR, implode("\n", $output));
            fflush(STDERR);
            exit(1);
        }

        exec(
            'git config --add lfs.standalonetransferagent git-lfs-s3',
            $output,
            $code
        );
        if ($code !== 0) {
            fwrite(STDERR, implode("\n", $output));
            fflush(STDERR);
            exit(1);
        }

        fwrite(STDOUT, "git-lfs-s3 installed\n");
        fflush(STDOUT);
    }
}

// ---------------------------------------------------------------------------
// Entry-point
// ---------------------------------------------------------------------------

/**
 * Main function for the git-lfs-s3 custom transfer agent.
 *
 * Corresponds to git_remote_s3.lfs:main().
 */
function lfsMain(): void
{
    global $argv;

    if (isset($argv[1])) {
        switch ($argv[1]) {
            case 'install':
                Lfs::install();
                exit(0);

            case 'debug':
                // Enable debug logging — handled when the Lfs object is constructed.
                // Fall through to main loop with debug flag set via env or config.
                break;

            case 'enable-debug':
                exec('git config --add lfs.customtransfer.git-lfs-s3.args debug');
                echo "debug enabled\n";
                exit(0);

            case 'disable-debug':
                exec('git config --unset lfs.customtransfer.git-lfs-s3.args');
                echo "debug disabled\n";
                exit(0);

            default:
                echo "unknown command {$argv[1]}\n";
                exit(1);
        }
    }

    $lfsProcess = null;

    while (true) {
        $line = fgets(STDIN);
        if ($line === false) {
            break;
        }
        $event = json_decode($line, true);
        if (!is_array($event)) {
            continue;
        }

        switch ($event['event'] ?? '') {
            case 'init':
                $remote = $event['remote'] ?? '';
                if (!Git::validateRefName($remote)) {
                    fwrite(STDOUT, "{}\n");
                    fflush(STDOUT);
                    exit(1);
                }

                $s3Uri = '';
                exec('git remote get-url ' . escapeshellarg($remote), $output, $code);
                if ($code !== 0) {
                    $errEvent = [
                        'error' => [
                            'code'    => 2,
                            'message' => "cannot resolve remote \"{$remote}\"",
                        ],
                    ];
                    fwrite(STDOUT, json_encode($errEvent));
                    fflush(STDOUT);
                    exit(1);
                }
                $s3Uri = trim(implode('', $output));
                $lfsProcess = new Lfs($s3Uri);
                break;

            case 'upload':
                if ($lfsProcess !== null) {
                    $lfsProcess->upload($event);
                }
                break;

            case 'download':
                if ($lfsProcess !== null) {
                    $lfsProcess->download($event);
                }
                break;
        }
    }
}
