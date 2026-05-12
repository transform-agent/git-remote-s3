# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3 do
  @moduledoc """
  Public API facade for `git-remote-s3`.

  Re-exports the key symbols used by downstream code and tests, mirroring
  `git_remote_s3/__init__.py`:

      from .remote import S3Remote
      from . import git
      from .common import parse_git_url
      from .manage import Doctor
      from .enums import UriScheme

  In Elixir there is no need for explicit re-exports — callers simply alias the
  sub-module they need.  This module documents the surface area and provides
  convenience delegations for the most commonly used functions.
  """

  alias GitRemoteS3.Common
  alias GitRemoteS3.UriScheme

  @doc """
  Parse an S3 remote URL.  Delegates to `GitRemoteS3.Common.parse_git_url/1`.
  """
  defdelegate parse_git_url(url), to: Common

  @doc "The `:s3` URI scheme atom."
  defdelegate s3, to: UriScheme

  @doc "The `:s3_zip` URI scheme atom."
  defdelegate s3_zip, to: UriScheme
end
