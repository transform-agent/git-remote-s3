-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Tests for 'GitRemoteS3.Common.parseGitUrl'.
--
-- Mirrors @test/parse_url_test.py@.
module ParseUrlSpec (spec) where

import           Test.Hspec
import           GitRemoteS3.Common  (parseGitUrl, ParseResult (..))
import           GitRemoteS3.Enums   (UriScheme (..))

spec :: Spec
spec = describe "parseGitUrl" $ do

  it "parses URL with trailing slash and no profile" $ do
    let url = "s3://bucket-name/path/to/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Nothing
        prPrefix  r `shouldBe` Just "path/to"

  it "parses URL without trailing slash and no profile" $ do
    let url = "s3://bucket-name/path/to"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Nothing
        prPrefix  r `shouldBe` Just "path/to"

  it "parses URL with profile" $ do
    let url = "s3://profile-test@bucket-name/path/to"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Just "profile-test"
        prPrefix  r `shouldBe` Just "path/to"

  it "parses URL (issue #5 – short profile)" $ do
    let url = "s3://er@bucket/path/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket"
        prProfile r `shouldBe` Just "er"
        prPrefix  r `shouldBe` Just "path"

  it "parses URL with 1-character profile" $ do
    let url = "s3://A@bucket/path/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket"
        prProfile r `shouldBe` Just "A"
        prPrefix  r `shouldBe` Just "path"

  it "parses URL with all supported symbols in profile" $ do
    let url = "s3://Ab-tr+54_quwww@bucket/path/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket"
        prProfile r `shouldBe` Just "Ab-tr+54_quwww"
        prPrefix  r `shouldBe` Just "path"

  it "parses URL with unsupported symbols in profile (permissive)" $ do
    -- Python's regex allows arbitrary chars before '@' in the profile group
    let url = "s3://A!@bucket/path/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket"
        prProfile r `shouldBe` Just "A!"
        prPrefix  r `shouldBe` Just "path"

  it "returns Nothing for empty profile (@@)" $ do
    parseGitUrl "s3://@bucket/path/" `shouldBe` Nothing

  it "parses URL with profile but no prefix (trailing slash)" $ do
    let url = "s3://profile-test@bucket-name/"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Just "profile-test"
        prPrefix  r `shouldBe` Nothing

  it "parses URL with profile but no prefix" $ do
    let url = "s3://profile-test@bucket-name"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Just "profile-test"
        prPrefix  r `shouldBe` Nothing

  it "parses URL with no profile and no prefix" $ do
    let url = "s3://bucket-name"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Nothing
        prPrefix  r `shouldBe` Nothing

  it "returns Nothing for invalid scheme (s4://)" $ do
    parseGitUrl "s4://bucket-name/path/to" `shouldBe` Nothing

  it "returns Nothing for empty / null URL" $ do
    parseGitUrl "" `shouldBe` Nothing

  it "parses s3+zip:// URL without profile" $ do
    let url = "s3+zip://bucket-name/path/to"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3Zip
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Nothing
        prPrefix  r `shouldBe` Just "path/to"

  it "parses s3+zip:// URL with profile" $ do
    let url = "s3+zip://profile-test@bucket-name/path/to"
    case parseGitUrl url of
      Nothing -> expectationFailure "expected Just"
      Just r  -> do
        prScheme  r `shouldBe` S3Zip
        prBucket  r `shouldBe` "bucket-name"
        prProfile r `shouldBe` Just "profile-test"
        prPrefix  r `shouldBe` Just "path/to"

  it "returns Nothing for invalid combined scheme (s3+foo://)" $ do
    parseGitUrl "s3+foo://bucket-name/path/to" `shouldBe` Nothing
