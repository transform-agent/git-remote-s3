-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Entry point for the @git-remote-s3@ (and @git-remote-s3-zip@) binaries.
--
-- Mirrors the @main@ function in @git_remote_s3/remote.py@.
--
-- The binary is invoked by git as:
-- > git-remote-s3 <remote-name> <url>
--
-- It reads commands from stdin and writes responses to stdout,
-- following the git remote-helper protocol.
module Main (main) where

import           Control.Exception          (catch, SomeException, IOException, try)
import           System.Environment         (getArgs)
import           System.Exit                (exitWith, exitSuccess, ExitCode (..))
import           System.IO                  ( hPutStrLn, hFlush, stderr, stdout
                                            , hSetBuffering, BufferMode (..)
                                            , stdin, openFile, IOMode (..) )

import           GitRemoteS3.Common         (parseGitUrl, ParseResult (..))
import           GitRemoteS3.Remote
import           GitRemoteS3.Enums          (UriScheme (..))

-- ---------------------------------------------------------------------------
-- Stub S3Ops (replace with real amazonka-s3 wiring for deployment)
-- ---------------------------------------------------------------------------

mkRealS3Ops :: Maybe String -> String -> String -> S3Ops
mkRealS3Ops _profile _bucket _prefix =
  S3Ops
    { s3ListObjects           = \_ -> ioStub "s3ListObjects"
    , s3GetObjectBody         = \_ -> ioStub "s3GetObjectBody"
    , s3PutObject             = \_ _ _ -> ioStub "s3PutObject"
    , s3PutObjectConditional  = \_ -> ioStub "s3PutObjectConditional"
    , s3DeleteObject          = \_ -> ioStub "s3DeleteObject"
    , s3DownloadFile          = \_ _ -> ioStub "s3DownloadFile"
    , s3UploadFile            = \_ _ -> ioStub "s3UploadFile"
    , s3HeadObject            = \_ -> ioStub "s3HeadObject"
    }
  where
    ioStub :: String -> IO a
    ioStub name = ioError (userError (name ++ ": real AWS SDK not wired in"))

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  hSetBuffering stdin  LineBuffering
  hSetBuffering stdout LineBuffering

  args <- getArgs

  let remote = if length args >= 2 then args !! 1 else ""
  case parseGitUrl remote of
    Nothing -> do
      hPutStrLn stderr
        ("fatal: invalid remote '" ++ remote
         ++ "'. You need to have a bucket and a prefix.")
      exitWith (ExitFailure 1)
    Just (ParseResult scheme profile bucket mPrefix) -> do
      let prefix = maybe "" id mPrefix
      if null prefix
        then do
          hPutStrLn stderr
            ("fatal: invalid remote '" ++ remote
             ++ "'. You need to have a bucket and a prefix.")
          exitWith (ExitFailure 1)
        else do
          let ops = mkRealS3Ops profile bucket prefix
          remoteResult <- try (newS3Remote scheme profile bucket prefix ops)
                            :: IO (Either SomeException S3Remote)
          case remoteResult of
            Left e -> do
              hPutStrLn stderr ("fatal: " ++ show e)
              exitWith (ExitFailure 1)
            Right s3remote ->
              runLoop s3remote
                `catch` handleBrokenPipe
                `catch` \(e :: SomeException) -> do
                  hPutStrLn stderr ("fatal: unknown error: " ++ show e)
                  exitWith (ExitFailure 1)

runLoop :: S3Remote -> IO ()
runLoop s3remote = do
  mLine <- (Just <$> getLine) `catch` (\(_ :: IOException) -> return Nothing)
  case mLine of
    Nothing -> return ()
    Just l  -> do
      processCmd s3remote (l ++ "\n")
      runLoop s3remote

handleBrokenPipe :: IOException -> IO ()
handleBrokenPipe _ = do
  -- Redirect stdout to /dev/null to suppress further writes (Unix-style)
  devnull <- openFile "/dev/null" WriteMode
  hSetBuffering devnull NoBuffering
  exitSuccess
