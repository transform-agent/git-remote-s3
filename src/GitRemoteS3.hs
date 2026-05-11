-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Public API for the @git-remote-s3@ library.
--
-- Mirrors the re-exports in @git_remote_s3\/__init__.py@.
module GitRemoteS3
  ( -- * URI scheme
    UriScheme (..)
    -- * URL parsing
  , parseGitUrl
  , ParseResult (..)
    -- * S3 remote helper
  , S3Remote (..)
  , newS3Remote
  , S3Ops (..)
  , S3Object (..)
  , processCmd
  , defaultLockTtlSeconds
    -- * Diagnostics
  , Doctor (..)
  , ManageS3Ops (..)
  , newDoctor
  , runDoctor
  , ManageBranch (..)
  , newManageBranch
  , processBranchCmd
  ) where

import GitRemoteS3.Enums   (UriScheme (..))
import GitRemoteS3.Common  (parseGitUrl, ParseResult (..))
import GitRemoteS3.Remote  ( S3Remote (..), newS3Remote, S3Ops (..), S3Object (..)
                           , processCmd, defaultLockTtlSeconds )
import GitRemoteS3.Manage  ( Doctor (..), ManageS3Ops (..), newDoctor, runDoctor
                           , ManageBranch (..), newManageBranch, processBranchCmd )
