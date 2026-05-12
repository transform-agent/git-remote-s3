# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.GitError do
  @moduledoc "Raised when a git subprocess returns a non-zero exit code."
  defexception [:message]
end

defmodule GitRemoteS3.Git do
  @moduledoc """
  Thin wrappers around git subprocess commands.

  Mirrors `git_remote_s3/git.py`.  All functions raise `GitRemoteS3.GitError`
  on failure.
  """

  alias GitRemoteS3.GitError

  # ---------------------------------------------------------------------------
  # archive
  # ---------------------------------------------------------------------------

  @doc """
  Archive the working tree at `ref` into `<folder>/repo.zip`.

  Returns the path to the archive file, or raises `GitError`.
  """
  @spec archive(folder: String.t(), ref: String.t()) :: String.t()
  def archive(folder: folder, ref: ref) do
    file_path = Path.join(folder, "repo.zip")

    case System.cmd("git", ["archive", "--format", "zip", "--output", file_path, ref],
           stderr_to_stdout: false
         ) do
      {_out, 0} ->
        file_path

      {err, _code} ->
        raise GitError, message: err
    end
  end

  # ---------------------------------------------------------------------------
  # bundle
  # ---------------------------------------------------------------------------

  @doc """
  Bundle `ref` into `<folder>/<sha>.bundle`.

  Returns the path to the bundle file, or raises `GitError`.
  """
  @spec bundle(folder: String.t(), sha: String.t(), ref: String.t()) :: String.t()
  def bundle(folder: folder, sha: sha, ref: ref) do
    file_path = Path.join(folder, "#{sha}.bundle")

    case System.cmd("git", ["bundle", "create", file_path, ref], stderr_to_stdout: false) do
      {_out, 0} ->
        file_path

      {err, _code} ->
        raise GitError, message: err
    end
  end

  # ---------------------------------------------------------------------------
  # unbundle
  # ---------------------------------------------------------------------------

  @doc """
  Unbundle `<folder>/<sha>.bundle` and check out `ref`.

  Output is forwarded to stderr (matching the Python implementation's
  `stdout=sys.stderr`).
  """
  @spec unbundle(folder: String.t(), sha: String.t(), ref: String.t()) :: :ok
  def unbundle(folder: folder, sha: sha, ref: ref) do
    bundle_path = Path.join(folder, "#{sha}.bundle")

    # System.cmd captures stdout; we write it to :stderr ourselves to mirror
    # the Python `stdout=sys.stderr` behaviour.
    case System.cmd("git", ["bundle", "unbundle", bundle_path, ref], stderr_to_stdout: false) do
      {output, 0} ->
        IO.write(:stderr, output)
        :ok

      {err, code} ->
        raise GitError, message: "git bundle unbundle exited with #{code}: #{err}"
    end
  end

  # ---------------------------------------------------------------------------
  # rev_parse
  # ---------------------------------------------------------------------------

  @doc """
  Return the SHA for `ref`, or raise `GitError` if not found.
  """
  @spec rev_parse(String.t()) :: String.t()
  def rev_parse(ref) do
    case System.cmd("git", ["rev-parse", ref], stderr_to_stdout: false) do
      {sha, 0} ->
        String.trim(sha)

      {_err, _code} ->
        raise GitError, message: "fatal: #{ref} not found"
    end
  end

  # ---------------------------------------------------------------------------
  # is_ancestor
  # ---------------------------------------------------------------------------

  @doc """
  Return `true` if `ancestor` is an ancestor of `descendant`.
  """
  @spec is_ancestor(String.t(), String.t()) :: boolean()
  def is_ancestor(ancestor, descendant) do
    {_out, code} =
      System.cmd("git", ["merge-base", "--is-ancestor", ancestor, descendant],
        stderr_to_stdout: true
      )

    code == 0
  end

  # ---------------------------------------------------------------------------
  # get_remote_url
  # ---------------------------------------------------------------------------

  @doc """
  Return the URL of `remote`, or raise `GitError` if not found.
  """
  @spec get_remote_url(String.t()) :: String.t()
  def get_remote_url(remote) do
    case System.cmd("git", ["remote", "get-url", remote], stderr_to_stdout: false) do
      {url, 0} ->
        String.trim(url)

      {_err, _code} ->
        raise GitError, message: "fatal: #{remote} not found"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_ref_name
  # ---------------------------------------------------------------------------

  # Mirrors https://github.com/git/git/blob/406f326/refs.c#L170
  @invalid_ref_regex ~r/(\A\.)|(\.\.)|([:\?\[\\\^\~\s\*\]])|(\.lock\z)|(\/\z)|(@\{)|([\x00-\x1f])/

  @doc """
  Return `true` if `name` is a valid git ref name.
  """
  @spec validate_ref_name(String.t()) :: boolean()
  def validate_ref_name(name) do
    not Regex.match?(@invalid_ref_regex, name)
  end

  # ---------------------------------------------------------------------------
  # get_last_commit_message
  # ---------------------------------------------------------------------------

  @doc """
  Return the short log line for the most recent commit, or raise `GitError`.
  """
  @spec get_last_commit_message() :: String.t()
  def get_last_commit_message do
    case System.cmd("git", ["log", "-1", "--pretty=%h %s"], stderr_to_stdout: false) do
      {msg, 0} ->
        String.trim(msg)

      {_err, _code} ->
        raise GitError, message: "fatal: an error as occurred"
    end
  end
end
