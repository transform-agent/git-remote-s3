# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.LFS do
  @moduledoc """
  Git LFS custom transfer agent for Amazon S3.

  Implements the [git-lfs custom transfer protocol][1] over stdin/stdout and
  exposes `main/1` as an escript entry point.

  Mirrors `git_remote_s3/lfs.py`.

  [1]: https://github.com/git-lfs/git-lfs/blob/main/docs/custom-transfers.md
  """

  require Logger

  alias GitRemoteS3.Common
  alias GitRemoteS3.Git

  # ---------------------------------------------------------------------------
  # Progress tracking
  # ---------------------------------------------------------------------------

  # In Python this was a callable object with a threading.Lock.
  # In Elixir we use a simple agent holding the running byte count.
  defmodule Progress do
    @moduledoc false

    def start(oid) do
      {:ok, pid} = Agent.start_link(fn -> {oid, 0} end)
      pid
    end

    def report(pid, bytes_amount) do
      Agent.update(pid, fn {oid, seen} ->
        new_seen = seen + bytes_amount
        event = %{
          "event" => "progress",
          "oid" => oid,
          "bytesSoFar" => new_seen,
          "bytesSinceLast" => bytes_amount
        }
        IO.write(Jason.encode!(event) <> "\n")
        {oid, new_seen}
      end)
    end

    def stop(pid), do: Agent.stop(pid)
  end

  # ---------------------------------------------------------------------------
  # Error event helper
  # ---------------------------------------------------------------------------

  defp write_error_event(oid, error) do
    event = %{
      "event" => "complete",
      "oid" => oid,
      "error" => %{"code" => 2, "message" => error}
    }
    IO.write(Jason.encode!(event) <> "\n")
  end

  # ---------------------------------------------------------------------------
  # LFSProcess state
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [:prefix, :bucket, :profile]
  end

  defp init_state(s3uri) do
    {_uri_scheme, profile, bucket, prefix} = Common.parse_git_url(s3uri)

    if is_nil(bucket) or is_nil(prefix) do
      Logger.error("s3 uri #{s3uri} is invalid")
      error_event = %{"error" => %{"code" => 32, "message" => "s3 uri #{s3uri} is invalid"}}
      IO.write(Jason.encode!(error_event) <> "\n")
      nil
    else
      IO.write("{}\n")
      %State{prefix: prefix, bucket: bucket, profile: profile}
    end
  end

  # ---------------------------------------------------------------------------
  # upload
  # ---------------------------------------------------------------------------

  defp upload(%State{} = state, event) do
    Logger.debug("upload")
    s3 = s3_client()
    opts = build_opts(state.profile)
    oid = event["oid"]
    path = event["path"]

    try do
      # Check if object already exists
      case s3.list_objects_v2(state.bucket, "#{state.prefix}/lfs/#{oid}", opts) do
        {:ok, %{contents: [_ | _]}} ->
          Logger.debug("object already exists")
          IO.write(Jason.encode!(%{"event" => "complete", "oid" => oid}) <> "\n")

        _ ->
          prog = Progress.start(oid)

          body = File.read!(path)
          # Report all bytes as one chunk (real multipart progress needs streaming)
          Progress.report(prog, byte_size(body))
          Progress.stop(prog)

          case s3.put_object(state.bucket, "#{state.prefix}/lfs/#{oid}", body, opts) do
            {:ok, _} ->
              IO.write(Jason.encode!(%{"event" => "complete", "oid" => oid}) <> "\n")

            {:error, reason} ->
              write_error_event(oid, inspect(reason))
          end
      end
    rescue
      e ->
        Logger.error(inspect(e))
        write_error_event(oid, inspect(e))
    end
  end

  # ---------------------------------------------------------------------------
  # download
  # ---------------------------------------------------------------------------

  defp download(%State{} = state, event) do
    Logger.debug("download")
    s3 = s3_client()
    opts = build_opts(state.profile)
    oid = event["oid"]
    temp_dir = Path.absname(".git/lfs/tmp")
    File.mkdir_p!(temp_dir)
    dest_path = Path.join(temp_dir, oid)

    try do
      prog = Progress.start(oid)

      case s3.download_file(state.bucket, "#{state.prefix}/lfs/#{oid}", dest_path, opts) do
        :ok ->
          file_size = File.stat!(dest_path).size
          Progress.report(prog, file_size)
          Progress.stop(prog)

          done_event = %{
            "event" => "complete",
            "oid" => oid,
            "path" => dest_path
          }
          IO.write(Jason.encode!(done_event) <> "\n")

        {:error, reason} ->
          Progress.stop(prog)
          Logger.error(inspect(reason))
          write_error_event(oid, inspect(reason))
      end
    rescue
      e ->
        Logger.error(inspect(e))
        write_error_event(oid, inspect(e))
    end
  end

  # ---------------------------------------------------------------------------
  # install
  # ---------------------------------------------------------------------------

  defp install do
    {_, code1} =
      System.cmd(
        "git",
        ["config", "--add", "lfs.customtransfer.git-lfs-s3.path", "git-lfs-s3"],
        stderr_to_stdout: true
      )

    if code1 != 0 do
      IO.write(:stderr, "git config failed\n")
      System.halt(1)
    end

    {_, code2} =
      System.cmd(
        "git",
        ["config", "--add", "lfs.standalonetransferagent", "git-lfs-s3"],
        stderr_to_stdout: true
      )

    if code2 != 0 do
      IO.write(:stderr, "git config failed\n")
      System.halt(1)
    end

    IO.write("git-lfs-s3 installed\n")
  end

  # ---------------------------------------------------------------------------
  # main/1  (escript entry point)
  # ---------------------------------------------------------------------------

  @doc "Escript entry point for the git-lfs-s3 transfer agent."
  def main(argv) do
    # Set up log file under .git/lfs/tmp/
    File.mkdir_p!(".git/lfs/tmp")

    # Handle sub-commands
    case argv do
      ["install" | _] ->
        install()
        System.halt(0)

      ["debug" | _] ->
        Logger.configure(level: :debug)
        run_protocol(nil)

      ["enable-debug" | _] ->
        System.cmd("git", ["config", "--add", "lfs.customtransfer.git-lfs-s3.args", "debug"])
        IO.puts("debug enabled")
        System.halt(0)

      ["disable-debug" | _] ->
        System.cmd("git", ["config", "--unset", "lfs.customtransfer.git-lfs-s3.args"])
        IO.puts("debug disabled")
        System.halt(0)

      [unknown | _] ->
        IO.puts("unknown command #{unknown}")
        System.halt(1)

      [] ->
        run_protocol(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Protocol loop
  # ---------------------------------------------------------------------------

  defp run_protocol(state) do
    Logger.debug("git-lfs-s3 starting")
    line = IO.read(:line)
    Logger.debug(line)

    case Jason.decode(line) do
      {:ok, event} ->
        handle_event(event, state)

      {:error, reason} ->
        Logger.error("JSON parse error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp handle_event(%{"event" => "init"} = event, _state) do
    remote_name = event["remote"]

    unless Git.validate_ref_name(remote_name) do
      Logger.error("invalid ref #{remote_name}")
      IO.write("{}\n")
      System.halt(1)
    end

    case System.cmd("git", ["remote", "get-url", remote_name],
           stderr_to_stdout: false
         ) do
      {url, 0} ->
        s3uri = String.trim(url)
        new_state = init_state(s3uri)
        run_protocol(new_state)

      {err, _code} ->
        Logger.error(String.trim(err))
        error_event = %{
          "error" => %{
            "code" => 2,
            "message" => "cannot resolve remote \"#{remote_name}\""
          }
        }
        IO.write(Jason.encode!(error_event))
        System.halt(1)
    end
  end

  defp handle_event(%{"event" => "upload"} = event, state) do
    upload(state, event)
    run_protocol(state)
  end

  defp handle_event(%{"event" => "download"} = event, state) do
    download(state, event)
    run_protocol(state)
  end

  defp handle_event(event, state) do
    Logger.warning("unknown event: #{inspect(event)}")
    run_protocol(state)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp s3_client do
    Application.get_env(:git_remote_s3, :s3_client, GitRemoteS3.ExAwsS3Client)
  end

  defp build_opts(nil), do: []
  defp build_opts(profile), do: [profile: profile]
end
