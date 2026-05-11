-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | URL parsing utilities for S3 remote URIs.
--
-- Mirrors @git_remote_s3/common.py@.
module GitRemoteS3.Common
  ( parseGitUrl
  , ParseResult (..)
  ) where

import           GitRemoteS3.Enums      (UriScheme (..))
import           Text.Regex.TDFA        ((=~))

-- | The parsed components of an S3 remote URI.
--
-- Corresponds to the 4-tuple @(uri_scheme, profile, bucket, prefix)@
-- returned by the Python @parse_git_url@ function.
-- All fields are @Maybe@ – the whole value is @Nothing@ when the URI
-- is invalid (Python returns a 4-tuple of @None@s in that case).
data ParseResult = ParseResult
  { prScheme  :: UriScheme
  , prProfile :: Maybe String   -- ^ AWS profile name (may be absent)
  , prBucket  :: String
  , prPrefix  :: Maybe String   -- ^ key prefix (may be absent)
  } deriving (Eq, Show)

-- | Parse an S3 remote URI.
--
-- Returns @'Just' 'ParseResult'@ when the URI is valid, @'Nothing'@
-- otherwise (including when the input is the empty string, which
-- mirrors Python's @None@ input returning all-@None@s).
--
-- Valid forms:
--
-- > s3://bucket/prefix
-- > s3://profile@bucket/prefix
-- > s3+zip://profile@bucket/prefix/deeper
--
-- The regex used is identical to the Python original:
--
-- > (s3|s3\+zip)://([^@]+@)?([a-z0-9][a-z0-9\.-]{2,62})/?(.+)?
parseGitUrl :: String -> Maybe ParseResult
parseGitUrl url
  | null url  = Nothing
  | otherwise =
      case url =~ pat :: (String, String, String, [String]) of
        (_, _, _, [schemeStr, profileRaw, bucketStr, prefixRaw])
          | not (null bucketStr) ->
              let
                profile = stripAt profileRaw
                prefix  = stripSlash prefixRaw
                scheme  = if schemeStr == "s3+zip" then S3Zip else S3
              in Just ParseResult
                   { prScheme  = scheme
                   , prProfile = profile
                   , prBucket  = bucketStr
                   , prPrefix  = prefix
                   }
        _ -> Nothing
  where
    pat :: String
    pat = "(s3|s3\\+zip)://([^@]+@)?([a-z0-9][a-z0-9\\.\\-]{2,62})/?(.*)"

    -- Remove trailing '@' from the profile capture group.
    -- Returns Nothing for an empty (or absent) profile.
    stripAt :: String -> Maybe String
    stripAt ""  = Nothing
    stripAt s   =
      let stripped = if last s == '@' then init s else s
      in if null stripped then Nothing else Just stripped

    -- Remove leading/trailing '/' from prefix.
    -- Returns Nothing for an empty prefix.
    stripSlash :: String -> Maybe String
    stripSlash "" = Nothing
    stripSlash s  =
      let s' = reverse . dropWhile (== '/') . reverse
             . dropWhile (== '/') $ s
      in if null s' then Nothing else Just s'
