-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | URI scheme enum, mirroring the Python @UriScheme@ Enum class.
module GitRemoteS3.Enums
  ( UriScheme (..)
  , uriSchemeText
  ) where

-- | The two supported S3 URI schemes.
--
-- * 'S3'    corresponds to @s3:\/\/@
-- * 'S3Zip' corresponds to @s3+zip:\/\/@
data UriScheme
  = S3      -- ^ Plain git bundle store
  | S3Zip   -- ^ Git bundle store plus a @repo.zip@ archive (for AWS CodePipeline)
  deriving (Eq)

instance Show UriScheme where
  show S3    = "s3"
  show S3Zip = "s3+zip"

-- | Convert a 'UriScheme' to its textual representation.
uriSchemeText :: UriScheme -> String
uriSchemeText = show
