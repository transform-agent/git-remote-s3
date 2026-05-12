# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.Common do
  @moduledoc """
  Shared URL-parsing helpers.

  Mirrors `git_remote_s3/common.py`.
  """

  alias GitRemoteS3.UriScheme

  @type parse_result ::
          {UriScheme.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil}

  # Regex mirror of:
  #   r"(s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?"
  #
  # Named captures make extraction explicit.
  @url_regex ~r/\A(s3|s3\+zip):\/\/([^@]+@)?([a-z0-9][a-z0-9.\-]{2,62})\/?(.+)?\z/

  @doc """
  Parses the elements in a `s3://` or `s3+zip://` remote origin URI.

  Returns a 4-tuple `{uri_scheme, profile, bucket, prefix}`.
  Any element that could not be parsed is returned as `nil`.

  ## Examples

      iex> GitRemoteS3.Common.parse_git_url("s3://bucket-name/path/to")
      {:s3, nil, "bucket-name", "path/to"}

      iex> GitRemoteS3.Common.parse_git_url("s3://profile@bucket/path/")
      {:s3, "profile", "bucket", "path"}

      iex> GitRemoteS3.Common.parse_git_url(nil)
      {nil, nil, nil, nil}
  """
  @spec parse_git_url(String.t() | nil) :: parse_result()
  def parse_git_url(nil), do: {nil, nil, nil, nil}

  def parse_git_url(url) when is_binary(url) do
    case Regex.run(@url_regex, url, capture: :all_but_first) do
      [scheme_str, profile_raw, bucket, prefix_raw] ->
        uri_scheme = UriScheme.from_string(scheme_str)

        profile =
          case profile_raw do
            "" -> nil
            # strip trailing "@"
            p -> String.trim_trailing(p, "@")
          end

        prefix =
          case prefix_raw do
            nil -> nil
            "" -> nil
            p -> String.trim(p, "/")
          end

        if is_nil(uri_scheme) do
          {nil, nil, nil, nil}
        else
          {uri_scheme, profile, bucket, prefix}
        end

      _ ->
        {nil, nil, nil, nil}
    end
  end
end
