# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.Manage do
  @moduledoc """
  Management CLI for Amazon S3 git remotes.

  Mirrors `git_remote_s3/manage.py`.

  Entry point: `GitRemoteS3.Manage.main/1` (escript).

  Sub-commands:
    * `doctor  <remote>` — analyse the remote, report issues, fix them
      interactively, and scan for stale lock files.
    * `delete-branch <remote> <branch>` — delete a branch from the remote.
    * `protect <remote> <branch>` — protect a branch from force-pushes.
    * `unprotect <remote> <branch>` — remove branch protection.
  """

  require Logger

  alias GitRemoteS3.Common
  alias GitRemoteS3.Git
  alias GitRemoteS3.GitError

  @default_lock_ttl_seconds 60

  # ---------------------------------------------------------------------------
  # Doctor
  # ---------------------------------------------------------------------------

  defmodule Doctor do
    @moduledoc "Analyses and repairs an S3-backed git remote."

    defstruct [:bucket, :prefix, :s3, :lock_ttl_seconds, :delete_bundle, :delete_stale_locks]

    def new(profile, bucket, prefix, delete_bundle, lock_ttl_seconds, delete_stale_locks) do
      s3 = s3_client()

      %__MODULE__{
        bucket: bucket,
        prefix: prefix,
        s3: s3,
        lock_ttl_seconds: lock_ttl_seconds,
        delete_bundle: delete_bundle,
        delete_stale_locks: delete_stale_locks
      }
    end

    def run(%__MODULE__{} = d) do
      repos = analyze_repo(d)

      Enum.each(repos, fn {repo_name, repo_data} ->
        IO.puts("#{repo_name}:")
        head_ref = "Invalid"

        head_ref =
          Enum.reduce(repo_data.refs, head_ref, fn {ref, ref_data}, head_acc ->
            head_acc =
              if repo_data.head == ref do
                ref
              else
                head_acc
              end

            part_1 = if ref_data.protected, do: "*", else: ""

            part_2 =
              if length(ref_data.bundles) == 1, do: "Ok", else: "Multiple refs"

            IO.puts(" #{part_1} #{ref}: #{part_2}")
            head_acc
          end)

        head_display =
          if head_ref == "Invalid" do
            "Invalid"
          else
            head_ref
          end

        IO.puts("  HEAD: #{head_display}")
      end)

      fix_issues(d, repos)
    end

    defp fix_issues(%__MODULE__{} = d, repos) do
      Enum.each(repos, fn {repo_name, repo_data} ->
        Enum.each(repo_data.refs, fn {ref, ref_data} ->
          if length(ref_data.bundles) > 1 do
            fix_multiple_bundles(d, repos, repo_name, ref)
          end
        end)

        if repo_data.head == "Invalid" do
          fix_head(d, repos, repo_name)
        end
      end)

      list_and_handle_stale_locks(d)
    end

    defp list_and_handle_stale_locks(%__MODULE__{} = d) do
      IO.puts("\nScanning for stale locks...")
      opts = build_opts(nil)

      objs =
        case d.s3.list_objects_v2(d.bucket, d.prefix <> "/", opts) do
          {:ok, %{contents: contents}} -> contents || []
          _ -> []
        end

      now = DateTime.utc_now()

      stale =
        Enum.filter(objs, fn obj ->
          String.ends_with?(obj.key, ".lock") and
            case obj[:last_modified] do
              nil ->
                false

              lm ->
                age = DateTime.diff(now, lm, :second)
                age > d.lock_ttl_seconds
            end
        end)
        |> Enum.map(fn obj ->
          age = DateTime.diff(now, obj.last_modified, :second)
          {obj.key, trunc(age)}
        end)

      if stale == [] do
        IO.puts("No stale locks found.")
      else
        IO.puts("Found stale locks:")
        Enum.each(stale, fn {key, age} -> IO.puts(" - #{key} (age: #{age}s)") end)

        if d.delete_stale_locks do
          IO.puts("\nDeleting stale locks...")

          Enum.each(stale, fn {key, _} ->
            case d.s3.delete_object(d.bucket, key, opts) do
              {:ok, _} -> IO.puts("Deleted #{key}")
              {:error, e} -> IO.puts("Failed to delete #{key}: #{inspect(e)}")
            end
          end)
        else
          IO.puts("\nRun with --delete-stale-locks to remove them automatically.")
        end
      end
    end

    defp analyze_repo(%__MODULE__{} = d) do
      opts = build_opts(nil)

      objs =
        case d.s3.list_objects_v2(d.bucket, d.prefix <> "/", opts) do
          {:ok, %{contents: contents}} -> contents || []
          _ -> []
        end

      Enum.reduce(objs, %{}, fn obj, repos ->
        key = obj.key
        key_parts = String.split(key, "/")
        repo_name = Enum.at(key_parts, 0)

        repos =
          if not Map.has_key?(repos, repo_name) do
            Map.put(repos, repo_name, %{refs: %{}, head: "Missing"})
          else
            repos
          end

        refs_path = key_parts |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join("/")

        cond do
          Enum.at(key_parts, 1) == "HEAD" ->
            case d.s3.get_object(d.bucket, key, opts) do
              {:ok, body} when is_binary(body) ->
                head_ref = String.trim(body)
                put_in(repos, [repo_name, :head], head_ref)

              _ ->
                repos
            end

          true ->
            repos =
              if not get_in(repos, [repo_name, :refs, refs_path]) do
                put_in(repos, [repo_name, :refs, refs_path], %{
                  protected: false,
                  bundles: []
                })
              else
                repos
              end

            if List.last(key_parts) == "PROTECTED#" do
              put_in(repos, [repo_name, :refs, refs_path, :protected], true)
            else
              sha = key_parts |> List.last() |> String.split(".") |> List.first()

              update_in(repos, [repo_name, :refs, refs_path, :bundles], fn bundles ->
                [%{sha: sha, last_modified: obj.last_modified} | bundles]
              end)
            end
        end
      end)
    end

    defp fix_multiple_bundles(%__MODULE__{} = d, repos, repo_name, ref) do
      IO.puts("\nFix multiple bundles for repo #{repo_name} and ref #{ref}")
      bundles = get_in(repos, [repo_name, :refs, ref, :bundles])
      opts = build_opts(nil)

      bundles
      |> Enum.with_index(1)
      |> Enum.each(fn {bundle, i} ->
        IO.puts("#{i}. #{bundle.sha} #{bundle.last_modified}")
      end)

      loop_fix_multiple(d, bundles, ref, opts)
    end

    defp loop_fix_multiple(%__MODULE__{} = d, bundles, ref, opts) do
      input = String.trim(IO.gets("Enter the number of the bundle to keep: "))

      case Integer.parse(input) do
        {i, ""} when i > 0 and i <= length(bundles) ->
          chosen = Enum.at(bundles, i - 1)
          IO.puts("Keeping #{chosen.sha}")
          IO.gets("Press enter to confirm or Ctrl+C to cancel")

          Enum.each(bundles, fn bundle ->
            if bundle.sha != chosen.sha do
              if d.delete_bundle do
                IO.puts("Removing #{bundle.sha}")
                d.s3.delete_object(d.bucket, "#{d.prefix}/#{ref}/#{bundle.sha}.bundle", opts)
              else
                tmp_branch = "#{ref}_#{String.slice(:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower), 0, 8)}"
                IO.puts("Moving #{bundle.sha} to new branch #{tmp_branch}")

                d.s3.copy_object(
                  d.bucket,
                  "#{d.prefix}/#{tmp_branch}/#{bundle.sha}.bundle",
                  d.bucket,
                  "#{d.prefix}/#{ref}/#{bundle.sha}.bundle",
                  opts
                )

                d.s3.delete_object(
                  d.bucket,
                  "#{d.prefix}/#{ref}/#{bundle.sha}.bundle",
                  opts
                )
              end
            end
          end)

        _ ->
          IO.puts("Invalid input")
          loop_fix_multiple(d, bundles, ref, opts)
      end
    end

    defp fix_head(%__MODULE__{} = d, repos, repo_name) do
      IO.puts("\nFix invalid HEAD for repo #{repo_name}")
      heads = get_in(repos, [repo_name, :refs]) |> Map.keys() |> Enum.filter(&String.contains?(&1, "heads"))
      opts = build_opts(nil)

      heads
      |> Enum.with_index(1)
      |> Enum.each(fn {head, i} ->
        IO.puts("#{i}. #{head |> String.split("/") |> List.last()}")
      end)

      loop_fix_head(d, heads, repo_name, opts)
    end

    defp loop_fix_head(%__MODULE__{} = d, heads, _repo_name, opts) do
      input = String.trim(IO.gets("Enter the number of the branch to use as head: "))

      case Integer.parse(input) do
        {i, ""} when i > 0 and i <= length(heads) ->
          head = Enum.at(heads, i - 1)
          IO.puts("Setting #{head} as HEAD")
          d.s3.put_object(d.bucket, "#{d.prefix}/HEAD", head, opts)

        _ ->
          IO.puts("Invalid input")
          loop_fix_head(d, heads, nil, opts)
      end
    end

    defp build_opts(nil), do: []
    defp build_opts(profile), do: [profile: profile]

    defp s3_client do
      Application.get_env(:git_remote_s3, :s3_client, GitRemoteS3.ExAwsS3Client)
    end
  end

  # ---------------------------------------------------------------------------
  # ManageBranch
  # ---------------------------------------------------------------------------

  defmodule ManageBranch do
    @moduledoc "Branch management operations (delete / protect / unprotect)."

    defstruct [:bucket, :prefix, :s3, :branch]

    def new(profile, bucket, prefix, branch) do
      s3 = s3_client()
      opts = build_opts(profile)

      case get_branch_content_raw(s3, bucket, prefix, branch, opts) do
        [] ->
          raise ArgumentError, message: "Branch #{branch} does not exist"

        _ ->
          %__MODULE__{bucket: bucket, prefix: prefix, s3: s3, branch: branch}
      end
    end

    def process_cmd(%__MODULE__{} = m, "delete-branch"), do: delete_branch(m)
    def process_cmd(%__MODULE__{} = m, "protect"), do: protect_branch(m)
    def process_cmd(%__MODULE__{} = m, "unprotect"), do: unprotect_branch(m)

    defp delete_branch(%__MODULE__{} = m) do
      opts = build_opts(nil)
      objs = get_branch_content_raw(m.s3, m.bucket, m.prefix, m.branch, opts)
      resp = String.trim(IO.gets("Delete #{m.branch} branch [yes/no]: "))

      if String.downcase(resp) == "yes" do
        Enum.each(objs, fn obj ->
          m.s3.delete_object(m.bucket, obj.key, opts)
        end)

        IO.puts("Branch #{m.branch} has been deleted")
      else
        IO.puts("Aborted")
      end
    end

    defp protect_branch(%__MODULE__{} = m) do
      opts = build_opts(nil)
      m.s3.put_object(m.bucket, "#{m.prefix}/refs/heads/#{m.branch}/PROTECTED#", "", opts)
      IO.puts("Branch #{m.branch} is now protected")
    end

    defp unprotect_branch(%__MODULE__{} = m) do
      opts = build_opts(nil)
      m.s3.delete_object(m.bucket, "#{m.prefix}/refs/heads/#{m.branch}/PROTECTED#", opts)
      IO.puts("Branch #{m.branch} is now unprotected")
    end

    defp get_branch_content_raw(s3, bucket, prefix, branch, opts) do
      case s3.list_objects_v2(bucket, "#{prefix}/refs/heads/#{branch}/", opts) do
        {:ok, %{contents: contents}} -> contents || []
        _ -> []
      end
    end

    defp build_opts(nil), do: []
    defp build_opts(profile), do: [profile: profile]

    defp s3_client do
      Application.get_env(:git_remote_s3, :s3_client, GitRemoteS3.ExAwsS3Client)
    end
  end

  # ---------------------------------------------------------------------------
  # main/1  (escript entry point)
  # ---------------------------------------------------------------------------

  @doc "Escript entry point for the `git-s3` management CLI."
  def main(argv) do
    {opts, positional, _} =
      OptionParser.parse(argv,
        strict: [
          delete_bundle: :boolean,
          lock_ttl: :integer,
          delete_stale_locks: :boolean
        ],
        aliases: [d: :delete_bundle]
      )

    delete_bundle = Keyword.get(opts, :delete_bundle, false)
    lock_ttl = Keyword.get(opts, :lock_ttl, @default_lock_ttl_seconds)
    delete_stale_locks = Keyword.get(opts, :delete_stale_locks, false)

    [command | rest] = positional

    remote_name = Enum.at(rest, 0)
    branch_arg = Enum.at(rest, 1)

    remote_url =
      try do
        Git.get_remote_url(remote_name)
      rescue
        e in GitError ->
          IO.write(:stderr, "fatal: #{e.message}\n")
          System.halt(1)
      end

    {_uri_scheme, profile, bucket, prefix} = Common.parse_git_url(remote_url)

    try do
      case command do
        "doctor" ->
          doctor = Doctor.new(profile, bucket, prefix, delete_bundle, lock_ttl, delete_stale_locks)
          Doctor.run(doctor)

        cmd when cmd in ["delete-branch", "protect", "unprotect"] ->
          if is_nil(branch_arg) do
            IO.write(:stderr, "fatal: branch argument is required\n")
            System.halt(1)
          end

          try do
            manage = ManageBranch.new(profile, bucket, prefix, branch_arg)
            ManageBranch.process_cmd(manage, cmd)
          rescue
            e in ArgumentError ->
              IO.write(:stderr, "fatal: #{e.message}\n")
              System.halt(1)
          end

        unknown ->
          IO.write(:stderr, "fatal: unknown command '#{unknown}'\n")
          System.halt(1)
      end

      System.halt(0)
    rescue
      e ->
        IO.write(:stderr, "fatal: invalid credentials #{inspect(e)}\n")
        System.halt(1)
    end
  end
end
