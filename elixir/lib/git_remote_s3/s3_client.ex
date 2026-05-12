# SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
#
# SPDX-License-Identifier: Apache-2.0

defmodule GitRemoteS3.S3ClientBehaviour do
  @moduledoc """
  Behaviour that abstracts all S3 API calls made by this library.

  Having a behaviour lets us swap in a `Mox`-generated mock during tests
  without monkey-patching anything.
  """

  @type aws_opts :: keyword()
  @type s3_result :: {:ok, map()} | {:error, term()}

  @callback list_objects_v2(bucket :: String.t(), prefix :: String.t(), opts :: aws_opts()) ::
              s3_result()

  @callback get_object(bucket :: String.t(), key :: String.t(), opts :: aws_opts()) ::
              s3_result()

  @callback head_object(bucket :: String.t(), key :: String.t(), opts :: aws_opts()) ::
              s3_result()

  @callback put_object(
              bucket :: String.t(),
              key :: String.t(),
              body :: binary(),
              opts :: aws_opts()
            ) :: s3_result()

  @callback delete_object(bucket :: String.t(), key :: String.t(), opts :: aws_opts()) ::
              s3_result()

  @callback download_file(
              bucket :: String.t(),
              key :: String.t(),
              local_path :: String.t(),
              opts :: aws_opts()
            ) :: :ok | {:error, term()}

  @callback upload_file(
              local_path :: String.t(),
              bucket :: String.t(),
              key :: String.t(),
              opts :: aws_opts()
            ) :: :ok | {:error, term()}

  @callback copy_object(
              dest_bucket :: String.t(),
              dest_key :: String.t(),
              src_bucket :: String.t(),
              src_key :: String.t(),
              opts :: aws_opts()
            ) :: s3_result()
end

defmodule GitRemoteS3.ExAwsS3Client do
  @moduledoc """
  Production implementation of `GitRemoteS3.S3ClientBehaviour` backed by
  `ExAws.S3`.
  """

  @behaviour GitRemoteS3.S3ClientBehaviour

  # Build per-request ExAws options from an optional AWS profile name.
  defp ex_aws_opts(nil), do: []

  defp ex_aws_opts(profile) when is_binary(profile) do
    case GitRemoteS3.AwsProfile.credentials(profile) do
      {:ok, creds} -> [config: creds]
      _ -> []
    end
  end

  @impl true
  def list_objects_v2(bucket, prefix, opts) do
    profile = Keyword.get(opts, :profile)
    continuation_token = Keyword.get(opts, :continuation_token)

    req_opts =
      if continuation_token do
        [continuation_token: continuation_token]
      else
        []
      end

    ExAws.S3.list_objects_v2(bucket, Keyword.merge([prefix: prefix], req_opts))
    |> ExAws.request(ex_aws_opts(profile))
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      err -> err
    end
  end

  @impl true
  def get_object(bucket, key, opts) do
    profile = Keyword.get(opts, :profile)

    ExAws.S3.get_object(bucket, key)
    |> ExAws.request(ex_aws_opts(profile))
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      err -> err
    end
  end

  @impl true
  def head_object(bucket, key, opts) do
    profile = Keyword.get(opts, :profile)

    ExAws.S3.head_object(bucket, key)
    |> ExAws.request(ex_aws_opts(profile))
    |> case do
      {:ok, %{headers: headers}} ->
        last_modified =
          headers
          |> Enum.find_value(fn {k, v} -> String.downcase(k) == "last-modified" && v end)

        {:ok, %{last_modified: last_modified}}

      err ->
        err
    end
  end

  @impl true
  def put_object(bucket, key, body, opts) do
    profile = Keyword.get(opts, :profile)
    metadata = Keyword.get(opts, :metadata, %{})
    content_disposition = Keyword.get(opts, :content_disposition)
    if_none_match = Keyword.get(opts, :if_none_match)

    s3_opts =
      [metadata: metadata]
      |> then(fn o ->
        if content_disposition, do: Keyword.put(o, :content_disposition, content_disposition), else: o
      end)
      |> then(fn o ->
        if if_none_match,
          do: Keyword.put(o, :headers, [{"If-None-Match", if_none_match}]),
          else: o
      end)

    ExAws.S3.put_object(bucket, key, body, s3_opts)
    |> ExAws.request(ex_aws_opts(profile))
  end

  @impl true
  def delete_object(bucket, key, opts) do
    profile = Keyword.get(opts, :profile)

    ExAws.S3.delete_object(bucket, key)
    |> ExAws.request(ex_aws_opts(profile))
  end

  @impl true
  def download_file(bucket, key, local_path, opts) do
    profile = Keyword.get(opts, :profile)

    # ExAws S3 download_file returns a stream; write chunks to file.
    result =
      ExAws.S3.download_file(bucket, key, local_path)
      |> ExAws.request(ex_aws_opts(profile))

    case result do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @impl true
  def upload_file(local_path, bucket, key, opts) do
    profile = Keyword.get(opts, :profile)

    result =
      local_path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket, key)
      |> ExAws.request(ex_aws_opts(profile))

    case result do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @impl true
  def copy_object(dest_bucket, dest_key, src_bucket, src_key, opts) do
    profile = Keyword.get(opts, :profile)
    source = "#{src_bucket}/#{src_key}"

    ExAws.S3.put_object_copy(dest_bucket, dest_key, source)
    |> ExAws.request(ex_aws_opts(profile))
  end
end
