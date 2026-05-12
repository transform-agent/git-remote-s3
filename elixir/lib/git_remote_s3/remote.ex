# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.BucketNotFoundError do
  @moduledoc "Raised when the S3 bucket does not exist."
  defexception [:bucket, :message]

  @impl true
  def exception(bucket: bucket),
    do: %__MODULE__{bucket: bucket, message: "Bucket #{bucket} not found."}
end

defmodule GitRemoteS3.NotAuthorizedError do
  @moduledoc "Raised when the caller lacks permission for an S3 action."
  defexception [:action, :bucket, :message]

  @impl true
  def exception(action: action, bucket: bucket),
    do: %__MODULE__{
      action: action,
      bucket: bucket,
      message: "Not authorized to perform #{action} on the S3 bucket #{bucket}."
    }
end

defmodule GitRemoteS3.Remote do
  @moduledoc """
  Git remote helper for Amazon S3.

  Implements the git remote-helper protocol over stdin/stdout and exposes
  `main/1` as an escript entry point.

  Mirrors `git_remote_s3/remote.py`.
  """

  require Logger

  alias GitRemoteS3.{Common, Git, GitError, UriScheme}
  alias GitRemoteS3.BucketNotFoundError
  alias GitRemoteS3.NotAuthorizedError

  @default_lock_ttl_seconds 60

  # ---------------------------------------------------------------------------
  # Struct
  # ---------------------------------------------------------------------------

  defstruct [
    :uri_scheme,
    :profile,
    :bucket,
    :prefix,
    :s3,
    :lock_ttl_seconds,
    mode: nil,
    # accumulated push commands (list of strings)
    push_cmds: [],
    # accumulated fetch commands
    fetch_cmds: [],
    # SHAs already fetched in this session (for dedup)
    fetched_refs: [],
    # agent PID for thread-safe access to fetched_refs
    fetched_refs_agent: nil
  ]

  @type t :: %__MODULE__{}

  # ---------------------------------------------------------------------------
  # Constructor
  # ---------------------------------------------------------------------------

  @doc """
  Create a new `S3Remote` struct, validating bucket access immediately.

  Raises `BucketNotFoundError` or `NotAuthorizedError` on access failure.
  """
  @spec new(UriScheme.t(), String.t() | nil, String.t(), String.t()) :: t()
  def new(uri_scheme, profile, bucket, prefix) do
    s3 = s3_client()
    opts = build_opts(profile)

    case s3.list_objects_v2(bucket, prefix, opts) do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 404, _}} ->
        raise BucketNotFoundError, bucket: bucket

      {:error, {:http_error, 403, _}} ->
        raise NotAuthorizedError, action: "ListObjectsV2", bucket: bucket

      {:error, reason} ->
        maybe_raise_bucket_or_auth(reason, bucket)
    end

    {:ok, agent} = Agent.start_link(fn -> [] end)

    lock_ttl =
      case Integer.parse(System.get_env("GIT_REMOTE_S3_LOCK_TTL_SECONDS", "#{@default_lock_ttl_seconds}")) do
        {v, ""} -> v
        _ -> @default_lock_ttl_seconds
      end

    %__MODULE__{
      uri_scheme: uri_scheme,
      profile: profile,
      bucket: bucket,
      prefix: prefix,
      s3: s3,
      lock_ttl_seconds: lock_ttl,
      fetched_refs_agent: agent
    }
  end

  # ---------------------------------------------------------------------------
  # list_refs
  # ---------------------------------------------------------------------------

  @doc """
  Return all bundle object keys (relative to `prefix`) for the remote,
  sorted newest-first.
  """
  @spec list_refs(t(), bucket: String.t(), prefix: String.t()) :: [String.t()]
  def list_refs(%__MODULE__{s3: s3, profile: profile}, bucket: bucket, prefix: prefix) do
    opts = build_opts(profile)
    contents = list_all_objects(s3, bucket, prefix, opts)

    contents
    |> Enum.sort_by(& &1.last_modified, {:desc, Date})
    |> Enum.filter(fn o ->
      String.starts_with?(o.key, prefix <> "/refs") and String.ends_with?(o.key, ".bundle")
    end)
    |> Enum.map(fn o ->
      String.replace_prefix(o.key, prefix <> "/", "")
    end)
  end

  # ---------------------------------------------------------------------------
  # cmd_fetch
  # ---------------------------------------------------------------------------

  @doc """
  Fetch a single bundle from S3 and unbundle it locally.

  Deduplicates by SHA using the `fetched_refs` Agent.
  """
  @spec cmd_fetch(t(), String.t()) :: :ok
  def cmd_fetch(%__MODULE__{} = remote, args) do
    [_fetch, sha, ref] = String.split(args, " ", parts: 3)

    # Check dedup
    already = Agent.get(remote.fetched_refs_agent, fn refs -> sha in refs end)

    if already do
      :ok
    else
      Logger.info("fetch #{sha} #{ref}")
      opts = build_opts(remote.profile)
      temp_dir = System.tmp_dir!() |> Path.join("git_remote_s3_fetch_#{:os.getpid()}_#{sha}")
      File.mkdir_p!(temp_dir)
      bundle_path = Path.join(temp_dir, "#{sha}.bundle")

      try do
        :ok =
          remote.s3.download_file(
            remote.bucket,
            "#{remote.prefix}/#{ref}/#{sha}.bundle",
            bundle_path,
            opts
          )

        Logger.info("fetched #{bundle_path} #{ref}")
        Git.unbundle(folder: temp_dir, sha: sha, ref: ref)
        Agent.update(remote.fetched_refs_agent, fn refs -> [sha | refs] end)
        :ok
      rescue
        e ->
          case e do
            %{__struct__: s} when s in [GitRemoteS3.HttpError] ->
              raise NotAuthorizedError, action: "GetObject", bucket: remote.bucket

            _ ->
              reraise e, __STACKTRACE__
          end
      after
        if File.exists?(bundle_path), do: File.rm!(bundle_path)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # cmd_push
  # ---------------------------------------------------------------------------

  @doc """
  Push a local ref to S3.  Returns a result line string for the protocol.
  """
  @spec cmd_push(t(), String.t()) :: String.t()
  def cmd_push(%__MODULE__{} = remote, args) do
    ref_spec = args |> String.split(" ", parts: 2) |> List.last()
    [local_ref_raw, remote_ref] = String.split(ref_spec, ":")

    if local_ref_raw == "" do
      remove_remote_ref(remote, remote_ref)
    else
      do_push(remote, local_ref_raw, remote_ref)
    end
  end

  defp do_push(%__MODULE__{} = remote, local_ref_raw, remote_ref) do
    {force_push, local_ref} =
      if String.starts_with?(local_ref_raw, "+") do
        lref = String.trim_leading(local_ref_raw, "+")
        {not is_protected?(remote, remote_ref), lref}
      else
        {false, local_ref_raw}
      end

    Logger.info("push !#{local_ref}! !#{remote_ref}!")

    temp_dir = System.tmp_dir!() |> Path.join("git_remote_s3_push_#{:os.getpid()}")
    File.mkdir_p!(temp_dir)

    contents = get_bundles_for_ref(remote, remote_ref)

    if length(contents) > 1 do
      "error #{remote_ref} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n"
    else
      remote_to_remove = if length(contents) == 1, do: List.first(contents).key, else: nil
      do_push_with_lock(remote, local_ref, remote_ref, force_push, remote_to_remove, temp_dir)
    end
  end

  defp do_push_with_lock(remote, local_ref, remote_ref, force_push, remote_to_remove, temp_dir) do
    opts = build_opts(remote.profile)

    sha =
      try do
        Git.rev_parse(local_ref)
      rescue
        %GitError{} ->
          Logger.info("fatal: #{local_ref} not found")
          {nil, "error #{remote_ref} \"#{local_ref} not found\"?\n"}
      end

    case sha do
      {nil, err_line} ->
        err_line

      sha ->
        # Ancestry check before acquiring lock
        ancestor_ok =
          if remote_to_remove && not force_push do
            remote_sha = remote_to_remove |> Path.basename() |> String.split(".") |> List.first()
            Git.is_ancestor(remote_sha, sha)
          else
            true
          end

        if not ancestor_ok do
          "error #{remote_ref} \"remote ref is not ancestor of #{local_ref}.\"?\n"
        else
          # Build bundle locally before taking the lock
          temp_file =
            try do
              Git.bundle(folder: temp_dir, sha: sha, ref: local_ref)
            rescue
              e in GitError ->
                Logger.info("fatal: #{e.message}")
                nil
            end

          if is_nil(temp_file) do
            "error #{remote_ref} \"#{local_ref} not found\"?\n"
          else
            push_with_lock(
              remote,
              local_ref,
              remote_ref,
              sha,
              temp_file,
              remote_to_remove,
              opts
            )
          end
        end
    end
  end

  defp push_with_lock(remote, local_ref, remote_ref, sha, temp_file, remote_to_remove, opts) do
    case acquire_lock(remote, remote_ref) do
      nil ->
        lock_path = "#{remote.prefix}/#{remote_ref}/LOCK#.lock"

        "error #{remote_ref} " <>
          "\"failed to acquire ref lock at #{lock_path}. " <>
          "Another client may be pushing. If this persists beyond #{remote.lock_ttl_seconds}s, " <>
          "run git-remote-s3 doctor --lock-ttl #{remote.lock_ttl_seconds} to inspect and optionally clear stale locks.\"?\n"

      lock_key ->
        result =
          try do
            # Re-check for multiple bundles after lock acquisition
            current_contents = get_bundles_for_ref(remote, remote_ref)

            if length(current_contents) > 1 do
              "error #{remote_ref} \"multiple bundles exists for the same ref on server. Run git-s3 doctor to fix. Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n"
            else
              current_remote_to_remove =
                if length(current_contents) == 1, do: List.first(current_contents).key, else: nil

              stale =
                remote_to_remove != nil and current_remote_to_remove != nil and
                  current_remote_to_remove != remote_to_remove

              if stale do
                "error #{remote_ref} \"stale remote. Please fetch and retry.\"?\n"
              else
                do_upload_bundle(
                  remote,
                  local_ref,
                  remote_ref,
                  sha,
                  temp_file,
                  remote_to_remove,
                  opts
                )
              end
            end
          rescue
            e ->
              Logger.info("fatal: #{inspect(e)}")
              "error #{remote_ref} \"#{inspect(e)}\"?\n"
          after
            try do
              release_lock(remote, remote_ref, lock_key)
            rescue
              e ->
                Logger.info("failed to release lock #{lock_key} for #{remote_ref}: #{inspect(e)}")
            end
          end

        result
    end
  after
    bundle_path = Path.join(Path.dirname(temp_file || ""), "#{sha}.bundle")
    if temp_file && File.exists?(bundle_path), do: File.rm!(bundle_path)
  end

  defp do_upload_bundle(remote, local_ref, remote_ref, sha, temp_file, remote_to_remove, opts) do
    body = File.read!(temp_file)

    case remote.s3.put_object(remote.bucket, "#{remote.prefix}/#{remote_ref}/#{sha}.bundle", body, opts) do
      {:ok, _} ->
        init_remote_head(remote, remote_ref)
        Logger.info("pushed #{temp_file} to #{remote_ref}")

        if remote_to_remove do
          remote.s3.delete_object(remote.bucket, remote_to_remove, opts)
        end

        result_line =
          if remote.uri_scheme == UriScheme.s3_zip() do
            push_zip_archive(remote, local_ref, remote_ref, sha, opts)
          else
            "ok #{remote_ref}\n"
          end

        result_line

      {:error, reason} ->
        Logger.info("fatal: #{inspect(reason)}")
        "error #{remote_ref} \"#{inspect(reason)}\"?\n"
    end
  end

  defp push_zip_archive(remote, local_ref, remote_ref, sha, opts) do
    temp_dir = System.tmp_dir!() |> Path.join("git_remote_s3_archive_#{:os.getpid()}_#{sha}")
    File.mkdir_p!(temp_dir)

    try do
      commit_msg = Git.get_last_commit_message()
      temp_file_archive = Git.archive(folder: temp_dir, ref: local_ref)
      archive_body = File.read!(temp_file_archive)
      sha_short = String.slice(sha, 0, 8)

      archive_opts =
        opts ++
          [
            metadata: %{"codepipeline-artifact-revision-summary" => commit_msg},
            content_disposition: "attachment; filename=repo-#{sha_short}.zip"
          ]

      case remote.s3.put_object(
             remote.bucket,
             "#{remote.prefix}/#{remote_ref}/repo.zip",
             archive_body,
             archive_opts
           ) do
        {:ok, _} ->
          Logger.info("pushed archive to #{remote.prefix}/#{remote_ref}/repo.zip with message #{commit_msg}")
          "ok #{remote_ref}\n"

        {:error, reason} ->
          Logger.info("fatal: #{inspect(reason)}")
          "error #{remote_ref} \"#{inspect(reason)}\"?\n"
      end
    rescue
      e ->
        Logger.info("fatal: #{inspect(e)}")
        "error #{remote_ref} \"#{inspect(e)}\"?\n"
    end
  end

  # ---------------------------------------------------------------------------
  # remove_remote_ref
  # ---------------------------------------------------------------------------

  defp remove_remote_ref(%__MODULE__{} = remote, remote_ref) do
    Logger.info("Removing remote ref #{remote_ref}")
    opts = build_opts(remote.profile)

    objects_to_delete =
      case remote.s3.list_objects_v2(remote.bucket, "#{remote.prefix}/#{remote_ref}/", opts) do
        {:ok, %{contents: contents}} -> contents || []
        _ -> []
      end

    s3_count = length(objects_to_delete)
    expected_s3 = if remote.uri_scheme == UriScheme.s3_zip(), do: 2, else: 1

    cond do
      s3_count == 0 ->
        "error #{remote_ref} not found\n"

      s3_count == expected_s3 ->
        Enum.each(objects_to_delete, fn obj ->
          remote.s3.delete_object(remote.bucket, obj.key, opts)
        end)

        "ok #{remote_ref}\n"

      true ->
        "error #{remote_ref} \"multiple bundles exists on server. Run git-s3 doctor to fix.\"?\n"
    end
  end

  # ---------------------------------------------------------------------------
  # get_bundles_for_ref
  # ---------------------------------------------------------------------------

  defp get_bundles_for_ref(%__MODULE__{} = remote, remote_ref) do
    opts = build_opts(remote.profile)

    case remote.s3.list_objects_v2(remote.bucket, "#{remote.prefix}/#{remote_ref}/", opts) do
      {:ok, %{contents: contents}} when is_list(contents) ->
        Enum.filter(contents, fn obj ->
          not String.contains?(obj.key, "PROTECTED#") and
            not String.ends_with?(obj.key, ".zip") and
            not String.contains?(obj.key, "/LOCKS/") and
            not String.ends_with?(obj.key, ".lock")
        end)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # is_protected?
  # ---------------------------------------------------------------------------

  defp is_protected?(%__MODULE__{} = remote, remote_ref) do
    opts = build_opts(remote.profile)

    case remote.s3.list_objects_v2(
           remote.bucket,
           "#{remote.prefix}/#{remote_ref}/PROTECTED#",
           opts
         ) do
      {:ok, %{contents: [_ | _]}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # init_remote_head
  # ---------------------------------------------------------------------------

  defp init_remote_head(%__MODULE__{} = remote, ref) do
    opts = build_opts(remote.profile)

    case remote.s3.head_object(remote.bucket, "#{remote.prefix}/HEAD", opts) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        remote.s3.put_object(remote.bucket, "#{remote.prefix}/HEAD", ref, opts)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Lock helpers
  # ---------------------------------------------------------------------------

  @doc "Acquire a per-ref lock via S3 conditional write. Returns lock_key or nil."
  @spec acquire_lock(t(), String.t()) :: String.t() | nil
  def acquire_lock(%__MODULE__{} = remote, remote_ref) do
    lock_key = "#{remote.prefix}/#{remote_ref}/LOCK#.lock"
    opts = build_opts(remote.profile)

    case remote.s3.put_object(remote.bucket, lock_key, "", opts ++ [if_none_match: "*"]) do
      {:ok, _} ->
        lock_key

      {:error, {:http_error, 412, _}} ->
        handle_stale_lock(remote, remote_ref, lock_key, opts)

      {:error, reason} ->
        code = extract_error_code(reason)

        if code in ["PreconditionFailed", "412"] do
          handle_stale_lock(remote, remote_ref, lock_key, opts)
        else
          raise RuntimeError, message: inspect(reason)
        end
    end
  end

  defp handle_stale_lock(remote, remote_ref, lock_key, opts) do
    case remote.s3.head_object(remote.bucket, lock_key, opts) do
      {:ok, %{last_modified: last_modified_str}} when is_binary(last_modified_str) ->
        now = DateTime.utc_now()

        case parse_http_date(last_modified_str) do
          {:ok, last_modified_dt} ->
            age = DateTime.diff(now, last_modified_dt, :second)

            if age > remote.lock_ttl_seconds do
              remote.s3.delete_object(remote.bucket, lock_key, opts)

              case remote.s3.put_object(remote.bucket, lock_key, "", opts ++ [if_none_match: "*"]) do
                {:ok, _} -> lock_key
                _ -> nil
              end
            else
              nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc "Release a previously acquired lock."
  @spec release_lock(t(), String.t(), String.t()) :: :ok
  def release_lock(%__MODULE__{} = remote, _remote_ref, lock_key) do
    opts = build_opts(remote.profile)
    remote.s3.delete_object(remote.bucket, lock_key, opts)
    :ok
  end

  # ---------------------------------------------------------------------------
  # cmd_option
  # ---------------------------------------------------------------------------

  @doc "Handle the `option` command from the git remote protocol."
  @spec cmd_option(t(), String.t()) :: :ok
  def cmd_option(_remote, args) do
    parts = String.split(args, " ", parts: 3)

    case parts do
      [_option_cmd, "verbosity", value] ->
        if String.to_integer(value) >= 2 do
          Logger.configure(level: :info)
          IO.write("ok\n")
        else
          IO.write("unsupported\n")
        end

      _ ->
        IO.write("unsupported\n")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # cmd_list
  # ---------------------------------------------------------------------------

  @doc "Handle the `list` command."
  @spec cmd_list(t(), for_push: boolean()) :: :ok
  def cmd_list(%__MODULE__{} = remote, for_push: for_push) do
    objs = list_refs(remote, bucket: remote.bucket, prefix: remote.prefix)
    Logger.info(inspect(objs))

    unless for_push do
      opts = build_opts(remote.profile)

      case get_remote_head(remote, opts) do
        {:ok, head} ->
          Logger.info("HEAD=[#{head}]")

          Enum.each(objs, fn o ->
            ref = o |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

            if ref == head do
              Logger.info("@#{ref} HEAD\n")
              IO.write("@#{ref} HEAD\n")
            end
          end)

        {:error, :no_such_key} ->
          :ok

        {:error, _} ->
          :ok
      end
    end

    bundle_regex = ~r/.+\/.+\/.+\/[a-f0-9]{40}\.bundle/

    Enum.each(objs, fn o ->
      if Regex.match?(bundle_regex, o) do
        elements = String.split(o, "/")
        sha = elements |> List.last() |> String.split(".") |> List.first()
        ref = elements |> Enum.drop(-1) |> Enum.join("/")
        IO.write("#{sha} #{ref}\n")
      end
    end)

    IO.write("\n")
  end

  def cmd_list(remote), do: cmd_list(remote, for_push: false)

  # ---------------------------------------------------------------------------
  # get_remote_head
  # ---------------------------------------------------------------------------

  defp get_remote_head(%__MODULE__{} = remote, opts) do
    case remote.s3.get_object(remote.bucket, "#{remote.prefix}/HEAD", opts) do
      {:ok, body} when is_binary(body) ->
        {:ok, String.trim(body)}

      {:ok, _} ->
        {:error, :unexpected_response}

      {:error, {:http_error, 404, _}} ->
        {:error, :no_such_key}

      {:error, reason} ->
        code = extract_error_code(reason)

        if code == "NoSuchKey" do
          {:error, :no_such_key}
        else
          {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # cmd_capabilities
  # ---------------------------------------------------------------------------

  @doc "Handle the `capabilities` command."
  @spec cmd_capabilities() :: :ok
  def cmd_capabilities do
    IO.write("*push\n")
    IO.write("*fetch\n")
    IO.write("option\n")
    IO.write("\n")
    :ok
  end

  # ---------------------------------------------------------------------------
  # process_fetch_cmds  (parallel)
  # ---------------------------------------------------------------------------

  @doc "Process a list of fetch commands in parallel using `Task.async_stream`."
  @spec process_fetch_cmds(t(), [String.t()]) :: :ok
  def process_fetch_cmds(_remote, []), do: :ok

  def process_fetch_cmds(%__MODULE__{} = remote, cmds) do
    Logger.info("Processing #{length(cmds)} fetch commands in parallel")

    cmds
    |> Task.async_stream(
      fn cmd -> cmd_fetch(remote, cmd) end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Stream.run()

    Logger.info("Completed processing #{length(cmds)} fetch commands in parallel")
    :ok
  end

  # ---------------------------------------------------------------------------
  # process_cmd
  # ---------------------------------------------------------------------------

  @doc "Dispatch a single line from the git remote protocol."
  @spec process_cmd(t(), String.t()) :: t()
  def process_cmd(%__MODULE__{} = remote, cmd) do
    cond do
      String.starts_with?(cmd, "fetch") ->
        mode = if remote.mode != :fetch, do: :fetch, else: remote.mode
        cmds = if remote.mode != :fetch, do: [], else: remote.fetch_cmds
        %{remote | mode: mode, fetch_cmds: cmds ++ [String.trim(cmd)]}

      String.starts_with?(cmd, "push") ->
        mode = if remote.mode != :push, do: :push, else: remote.mode
        cmds = if remote.mode != :push, do: [], else: remote.push_cmds
        %{remote | mode: mode, push_cmds: cmds ++ [String.trim(cmd)]}

      String.starts_with?(cmd, "option") ->
        cmd_option(remote, String.trim(cmd))
        remote

      String.starts_with?(cmd, "list for-push") ->
        cmd_list(remote, for_push: true)
        remote

      String.starts_with?(cmd, "list") ->
        cmd_list(remote, for_push: false)
        remote

      String.starts_with?(cmd, "capabilities") ->
        cmd_capabilities()
        remote

      cmd == "\n" ->
        Logger.info("empty line")

        remote =
          if remote.mode == :push and remote.push_cmds != [] do
            Logger.info("pushing #{inspect(remote.push_cmds)}")

            Enum.each(remote.push_cmds, fn c ->
              res = cmd_push(remote, c)
              IO.write(res)
            end)

            %{remote | push_cmds: []}
          else
            remote
          end

        remote =
          if remote.mode == :fetch and remote.fetch_cmds != [] do
            Logger.info("fetching #{length(remote.fetch_cmds)} refs in parallel")
            process_fetch_cmds(remote, remote.fetch_cmds)
            %{remote | fetch_cmds: []}
          else
            remote
          end

        IO.write("\n")
        remote

      true ->
        IO.write(:stderr, "fatal: invalid command '#{String.trim(cmd)}'\n")
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # main/1  (escript entry point)
  # ---------------------------------------------------------------------------

  @doc "Escript entry point – invoked as `git-remote-s3 <name> <url>`."
  def main(argv) do
    # Enable verbose logging via environment variable
    verbose_env = System.get_env("GIT_REMOTE_S3_VERBOSE", "") |> String.downcase()

    if verbose_env in ["1", "true", "yes"] do
      Logger.configure(level: :info)
    end

    remote_url = Enum.at(argv, 1)
    {uri_scheme, profile, bucket, prefix} = Common.parse_git_url(remote_url)

    if is_nil(bucket) or is_nil(prefix) do
      IO.write(:stderr, "fatal: invalid remote '#{remote_url}'. You need to have a bucket and a prefix.\n")
      System.halt(1)
    end

    try do
      s3remote = new(uri_scheme, profile, bucket, prefix)

      loop(s3remote)
    rescue
      e in BucketNotFoundError ->
        IO.write(:stderr, "fatal: bucket not found #{e.bucket}\n")
        System.halt(1)

      e in NotAuthorizedError ->
        IO.write(:stderr, "fatal: user not authorized to perform #{e.action} on #{e.bucket}\n")
        System.halt(1)

      e ->
        Logger.info(inspect(e))
        IO.write(:stderr, "fatal: unknown error. Run with --verbose flag to get full log\n")
        System.halt(1)
    end
  end

  defp loop(remote) do
    case IO.read(:line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        Logger.info("cmd: #{line}")
        updated_remote = process_cmd(remote, line)
        loop(updated_remote)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp s3_client do
    Application.get_env(:git_remote_s3, :s3_client, GitRemoteS3.ExAwsS3Client)
  end

  defp build_opts(nil), do: []
  defp build_opts(profile), do: [profile: profile]

  defp list_all_objects(s3, bucket, prefix, opts) do
    do_list_all_objects(s3, bucket, prefix, opts, nil, [])
  end

  defp do_list_all_objects(s3, bucket, prefix, opts, continuation_token, acc) do
    req_opts =
      if continuation_token,
        do: opts ++ [continuation_token: continuation_token],
        else: opts

    case s3.list_objects_v2(bucket, prefix, req_opts) do
      {:ok, %{contents: contents, next_continuation_token: token}} when is_binary(token) ->
        do_list_all_objects(s3, bucket, prefix, opts, token, acc ++ (contents || []))

      {:ok, %{contents: contents}} ->
        acc ++ (contents || [])

      _ ->
        acc
    end
  end

  defp extract_error_code(reason) do
    case reason do
      %{code: code} -> code
      {:aws_error, %{code: code}} -> code
      _ -> nil
    end
  end

  defp maybe_raise_bucket_or_auth(reason, bucket) do
    code = extract_error_code(reason)

    cond do
      code in ["NoSuchBucket"] ->
        raise BucketNotFoundError, bucket: bucket

      code in ["AccessDenied", "Forbidden"] ->
        raise NotAuthorizedError, action: "ListObjectsV2", bucket: bucket

      true ->
        raise RuntimeError, message: inspect(reason)
    end
  end

  # Parse an HTTP date string (RFC 7231) to a DateTime.
  defp parse_http_date(str) do
    # ExAws typically returns ISO 8601 strings for LastModified.
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        # Fallback: try to parse as RFC 1123 (HTTP/1.1 date format)
        {:error, :unparseable}
    end
  end
end
