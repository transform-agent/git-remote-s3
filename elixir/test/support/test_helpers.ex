defmodule GitRemoteS3.TestHelpers do
  @moduledoc """
  Shared test helpers used across the test suite.
  """

  @sha1 "c105d19ba64965d2c9d3d3246e7269059ef8bb8a"
  @sha2 "c105d19ba64965d2c9d3d3246e7269059ef8bb8b"
  @branch "pytest"

  def sha1, do: @sha1
  def sha2, do: @sha2
  def branch, do: @branch

  @doc """
  Build a mock `list_objects_v2` response matching the Python helper
  `create_list_objects_v2_mock`.
  """
  def list_objects_v2_response(opts \\ []) do
    protected = Keyword.get(opts, :protected, false)
    no_head = Keyword.get(opts, :no_head, false)
    branch = Keyword.get(opts, :branch, @branch)
    shas = Keyword.get(opts, :shas, [@sha1])

    now = DateTime.utc_now()

    contents =
      Enum.map(shas, fn sha ->
        %{key: "test_prefix/refs/heads/#{branch}/#{sha}.bundle", last_modified: now}
      end)

    contents =
      if protected do
        contents ++
          [%{key: "test_prefix/refs/heads/#{branch}/PROTECTED#", last_modified: now}]
      else
        contents
      end

    contents =
      if not no_head do
        contents ++ [%{key: "test_prefix/HEAD", last_modified: now}]
      else
        contents
      end

    fn bucket, prefix, _opts ->
      filtered = Enum.filter(contents, fn obj -> String.starts_with?(obj.key, prefix) end)
      {:ok, %{contents: filtered, next_continuation_token: nil}}
    end
  end
end
