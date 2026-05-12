defmodule GitRemoteS3.ParseUrlTest do
  @moduledoc """
  Elixir translation of `test/parse_url_test.py`.

  Each Python `assert` maps to an ExUnit `assert`.
  `UriScheme.S3` / `UriScheme.S3_ZIP` map to `:s3` / `:s3_zip` atoms.
  """

  use ExUnit.Case, async: true

  alias GitRemoteS3.Common
  alias GitRemoteS3.UriScheme

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse(url), do: Common.parse_git_url(url)

  defp s3, do: UriScheme.s3()
  defp s3_zip, do: UriScheme.s3_zip()

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "parse_url_trailing_slash_no_profile" do
    url = "s3://bucket-name/path/to/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == nil
    assert prefix == "path/to"
  end

  test "parse_url_no_profile" do
    url = "s3://bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == nil
    assert prefix == "path/to"
  end

  test "parse_url" do
    url = "s3://profile-test@bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == "profile-test"
    assert prefix == "path/to"
  end

  test "parse_url_issue5" do
    url = "s3://er@bucket/path/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket"
    assert profile == "er"
    assert prefix == "path"
  end

  test "parse_url_1_char_profile" do
    url = "s3://A@bucket/path/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket"
    assert profile == "A"
    assert prefix == "path"
  end

  test "parse_url_all_supported_symbols_in_profile" do
    url = "s3://Ab-tr+54_quwww@bucket/path/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket"
    assert profile == "Ab-tr+54_quwww"
    assert prefix == "path"
  end

  test "parse_url_unsupported_symbols_in_profile" do
    # The Python regex captures "A!" as the profile (the `!` is not excluded
    # from `[^@]+`) – we mirror that behaviour.
    url = "s3://A!@bucket/path/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket"
    assert profile == "A!"
    assert prefix == "path"
  end

  test "parse_url_empty_profile" do
    # An empty profile (just "@") should be invalid.
    url = "s3://@bucket/path/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == nil
    assert bucket == nil
    assert profile == nil
    assert prefix == nil
  end

  test "parse_url_no_prefix_trailing_slash" do
    url = "s3://profile-test@bucket-name/"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == "profile-test"
    assert prefix == nil
  end

  test "parse_url_no_prefix" do
    url = "s3://profile-test@bucket-name"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == "profile-test"
    assert prefix == nil
  end

  test "parse_url_no_prefix_no_profile" do
    url = "s3://bucket-name"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3()
    assert bucket == "bucket-name"
    assert profile == nil
    assert prefix == nil
  end

  test "parse_url_not_valid" do
    url = "s4://bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == nil
    assert bucket == nil
    assert profile == nil
    assert prefix == nil
  end

  test "parse_url_none" do
    {uri_scheme, profile, bucket, prefix} = parse(nil)
    assert uri_scheme == nil
    assert bucket == nil
    assert profile == nil
    assert prefix == nil
  end

  test "parse_url_uri_scheme_s3_zip_no_profile" do
    url = "s3+zip://bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3_zip()
    assert bucket == "bucket-name"
    assert profile == nil
    assert prefix == "path/to"
  end

  test "parse_url_uri_scheme_s3_zip" do
    url = "s3+zip://profile-test@bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == s3_zip()
    assert bucket == "bucket-name"
    assert profile == "profile-test"
    assert prefix == "path/to"
  end

  test "parse_url_uri_scheme_not_valid" do
    url = "s3+foo://bucket-name/path/to"
    {uri_scheme, profile, bucket, prefix} = parse(url)
    assert uri_scheme == nil
    assert bucket == nil
    assert profile == nil
    assert prefix == nil
  end
end
