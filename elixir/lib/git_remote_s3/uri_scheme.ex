# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.UriScheme do
  @moduledoc """
  Atom-based enumeration for the supported S3 URI schemes.

  Mirrors the Python `UriScheme` enum:

      class UriScheme(Enum):
          S3     = "s3"
          S3_ZIP = "s3+zip"
  """

  @type t :: :s3 | :s3_zip

  @s3 :s3
  @s3_zip :s3_zip

  @doc "The plain `s3://` scheme."
  def s3, do: @s3

  @doc "The `s3+zip://` scheme (bundle + CodePipeline archive)."
  def s3_zip, do: @s3_zip

  @doc "Convert a string to a `t:t/0` atom, or `nil` for unrecognised values."
  @spec from_string(String.t()) :: t() | nil
  def from_string("s3"), do: @s3
  def from_string("s3+zip"), do: @s3_zip
  def from_string(_), do: nil

  @doc "Convert a `t:t/0` atom back to its URI string."
  @spec to_string(t()) :: String.t()
  def to_string(:s3), do: "s3"
  def to_string(:s3_zip), do: "s3+zip"
end
