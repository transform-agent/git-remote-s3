-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Entry point for the @git-lfs-s3@ binary.
--
-- Mirrors the @main@ function in @git_remote_s3/lfs.py@.
module Main (main) where

import           System.Environment         (getArgs)
import           GitRemoteS3.Lfs            (lfsMain, LFSS3Ops (..))

-- ---------------------------------------------------------------------------
-- Stub S3 ops (replace with real amazonka-s3 wiring for deployment)
-- ---------------------------------------------------------------------------

realOps :: LFSS3Ops
realOps = LFSS3Ops
  { lfsS3ObjectExists = \_ -> ioStub "lfsS3ObjectExists"
  , lfsS3UploadFile   = \_ _ _ -> ioStub "lfsS3UploadFile"
  , lfsS3DownloadFile = \_ _ _ -> ioStub "lfsS3DownloadFile"
  }
  where
    ioStub :: String -> IO a
    ioStub name = ioError (userError (name ++ ": real AWS SDK not wired in"))

main :: IO ()
main = do
  args <- getArgs
  lfsMain realOps args
