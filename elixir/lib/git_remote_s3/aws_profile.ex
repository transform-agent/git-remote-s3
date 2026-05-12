# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.AwsProfile do
  @moduledoc """
  Loads AWS credentials from `~/.aws/credentials` for a named profile.

  This replicates the behaviour of `boto3.Session(profile_name=…)` which
  reads the INI-style `~/.aws/credentials` file.
  """

  @doc """
  Return `{:ok, keyword_list}` with ExAws-compatible credentials for
  `profile`, or `{:error, reason}` if the profile is not found.
  """
  @spec credentials(String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def credentials(profile) do
    creds_file = Path.expand("~/.aws/credentials")
    config_file = Path.expand("~/.aws/config")

    with {:ok, creds} <- read_ini_section(creds_file, profile),
         {:ok, _cfg} <- maybe_read_ini_section(config_file, "profile #{profile}") do
      access_key = Map.get(creds, "aws_access_key_id")
      secret_key = Map.get(creds, "aws_secret_access_key")
      session_token = Map.get(creds, "aws_session_token")
      region = Map.get(creds, "region")

      kw =
        []
        |> maybe_put(:access_key_id, access_key)
        |> maybe_put(:secret_access_key, secret_key)
        |> maybe_put(:security_token, session_token)
        |> maybe_put(:region, region)

      {:ok, kw}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp read_ini_section(path, section) do
    case File.read(path) do
      {:ok, content} ->
        case parse_ini_section(content, section) do
          nil -> {:error, "profile '#{section}' not found in #{path}"}
          map -> {:ok, map}
        end

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp maybe_read_ini_section(path, section) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, parse_ini_section(content, section) || %{}}

      _ ->
        {:ok, %{}}
    end
  end

  # Minimal INI parser: extract key=value pairs from [section].
  defp parse_ini_section(content, section) do
    lines = String.split(content, ~r/\r?\n/)

    {found, pairs} =
      Enum.reduce(lines, {false, []}, fn line, {in_section, acc} ->
        stripped = String.trim(line)

        cond do
          String.starts_with?(stripped, "[") ->
            header = stripped |> String.trim_leading("[") |> String.trim_trailing("]") |> String.trim()
            {header == section, acc}

          in_section and String.contains?(stripped, "=") ->
            [k | rest] = String.split(stripped, "=", parts: 2)
            v = Enum.join(rest, "=")
            {true, [{String.trim(k), String.trim(v)} | acc]}

          true ->
            {in_section, acc}
        end
      end)

    if found or pairs != [] do
      Map.new(pairs)
    else
      nil
    end
  end
end
