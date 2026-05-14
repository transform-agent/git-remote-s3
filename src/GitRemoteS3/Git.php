<?php

// SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
//
// SPDX-License-Identifier: Apache-2.0

declare(strict_types=1);

namespace GitRemoteS3;

/**
 * Exception thrown when a git sub-process fails.
 *
 * Corresponds to GitError in git_remote_s3/git.py.
 */
class GitError extends \RuntimeException {}

/**
 * Helpers that wrap git sub-processes.
 *
 * All methods are static; they spawn git via proc_open / exec and throw
 * GitError on failure — mirroring the Python module git_remote_s3/git.py.
 */
class Git
{
    /**
     * Archive the repository into a repo.zip file.
     *
     * @param string $folder  Directory in which to write the archive
     * @param string $ref     Git ref to archive
     * @return string         Absolute path to the written archive
     * @throws GitError
     */
    public static function archive(string $folder, string $ref): string
    {
        $filePath = "{$folder}/repo.zip";
        [$stdout, $stderr, $code] = self::run(
            ['git', 'archive', '--format', 'zip', '--output', $filePath, $ref]
        );
        if ($code !== 0) {
            throw new GitError($stderr);
        }
        return $filePath;
    }

    /**
     * Bundle a git ref into <sha>.bundle.
     *
     * @param string $folder  Directory in which to write the bundle
     * @param string $sha     SHA to use as the filename (without extension)
     * @param string $ref     Git ref to bundle
     * @return string         Absolute path to the bundle file
     * @throws GitError
     */
    public static function bundle(string $folder, string $sha, string $ref): string
    {
        $filePath = "{$folder}/{$sha}.bundle";
        [$stdout, $stderr, $code] = self::run(
            ['git', 'bundle', 'create', $filePath, $ref]
        );
        if ($code !== 0) {
            throw new GitError($stderr);
        }
        return $filePath;
    }

    /**
     * Unbundle a <sha>.bundle file into the current repository.
     *
     * @param string $folder  Directory that contains the bundle
     * @param string $sha     SHA portion of the bundle filename
     * @param string $ref     Git ref to check out after unbundling
     * @throws GitError
     */
    public static function unbundle(string $folder, string $sha, string $ref): void
    {
        // Stderr is forwarded to the process's own stderr (like Python's stdout=sys.stderr).
        $cmd = sprintf(
            'git bundle unbundle %s %s 1>&2',
            escapeshellarg("{$folder}/{$sha}.bundle"),
            escapeshellarg($ref)
        );
        passthru($cmd, $code);
        if ($code !== 0) {
            throw new GitError("git bundle unbundle exited with code {$code}");
        }
    }

    /**
     * Resolve a git ref to its full SHA.
     *
     * @param string $ref
     * @return string  40-character hex SHA
     * @throws GitError
     */
    public static function revParse(string $ref): string
    {
        [$stdout, $stderr, $code] = self::run(['git', 'rev-parse', $ref]);
        if ($code !== 0) {
            throw new GitError("fatal: {$ref} not found");
        }
        return trim($stdout);
    }

    /**
     * Check whether $ancestor is an ancestor of $descendant.
     *
     * @param string $ancestor
     * @param string $descendant
     * @return bool
     */
    public static function isAncestor(string $ancestor, string $descendant): bool
    {
        [$stdout, $stderr, $code] = self::run(
            ['git', 'merge-base', '--is-ancestor', $ancestor, $descendant],
            suppressOutput: true
        );
        return $code === 0;
    }

    /**
     * Return the URL configured for a named remote.
     *
     * @param string $remote
     * @return string
     * @throws GitError
     */
    public static function getRemoteUrl(string $remote): string
    {
        [$stdout, $stderr, $code] = self::run(['git', 'remote', 'get-url', $remote]);
        if ($code !== 0) {
            throw new GitError("fatal: {$remote} not found");
        }
        return trim($stdout);
    }

    /**
     * Validate a git refname according to the rules in git's refs.c.
     *
     * @see https://github.com/git/git/blob/406f326/refs.c#L170
     *
     * @param string $name
     * @return bool
     */
    public static function validateRefName(string $name): bool
    {
        return preg_match(
            '/(\.\.)|(^\.)|([:?\[\\\\^~\s*])|(\.lock$)|(\/\/)|(^\/)|(\/$)|(@\{)|([\x00-\x1f])/',
            $name
        ) === 0;
    }

    /**
     * Return a short summary of the last commit (hash + subject).
     *
     * @return string
     * @throws GitError
     */
    public static function getLastCommitMessage(): string
    {
        [$stdout, $stderr, $code] = self::run(['git', 'log', '-1', '--pretty=%h %s']);
        if ($code !== 0) {
            throw new GitError('fatal: an error has occurred');
        }
        return trim($stdout);
    }

    // -------------------------------------------------------------------------
    // Internal helper
    // -------------------------------------------------------------------------

    /**
     * Run an external command and capture stdout + stderr.
     *
     * @param string[]   $argv
     * @param bool       $suppressOutput  When true, stderr/stdout are discarded
     * @return array{string, string, int}  [stdout, stderr, exit_code]
     */
    private static function run(array $argv, bool $suppressOutput = false): array
    {
        $cmd = implode(' ', array_map('escapeshellarg', $argv));

        $descriptors = [
            0 => ['pipe', 'r'],  // stdin
            1 => ['pipe', 'w'],  // stdout
            2 => ['pipe', 'w'],  // stderr
        ];

        $process = proc_open($cmd, $descriptors, $pipes);
        if (!is_resource($process)) {
            throw new GitError("Failed to start process: {$cmd}");
        }

        fclose($pipes[0]);

        $stdout = stream_get_contents($pipes[1]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);

        $code = proc_close($process);

        return [$stdout ?: '', $stderr ?: '', $code];
    }
}
