-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Entry point for the @git-s3@ management binary.
--
-- Mirrors the @main@ function in @git_remote_s3/manage.py@.
module Main (main) where

import           Control.Exception          (try, SomeException)
import           Options.Applicative
import           System.Exit                (exitWith, exitSuccess, ExitCode (..))
import           System.IO                  (hPutStrLn, hFlush, stderr)

import           GitRemoteS3.Common         (parseGitUrl, ParseResult (..))
import           GitRemoteS3.Git            (getRemoteUrl, GitError (..))
import           GitRemoteS3.Manage
import           GitRemoteS3.Remote         (defaultLockTtlSeconds)

-- ---------------------------------------------------------------------------
-- CLI argument parsing
-- ---------------------------------------------------------------------------

data Opts = Opts
  { optCommand          :: String
  , optRemote           :: String
  , optDeleteBundle     :: Bool
  , optLockTtl          :: Int
  , optDeleteStaleLocks :: Bool
  , optBranch           :: Maybe String
  } deriving (Show)

optsParser :: Parser Opts
optsParser = Opts
  <$> argument str (metavar "COMMAND"
        <> help "Command: doctor | delete-branch | protect | unprotect")
  <*> argument str (metavar "REMOTE"
        <> help "The remote S3 URI to analyze, including the AWS profile if used")
  <*> switch
        ( long "delete-bundle"
        <> short 'd'
        <> help "Delete the bundle instead of creating a new branch" )
  <*> option auto
        ( long "lock-ttl"
        <> metavar "SECONDS"
        <> value defaultLockTtlSeconds
        <> showDefault
        <> help ("Seconds after which a lock is considered stale (default: "
                 ++ show defaultLockTtlSeconds ++ ")") )
  <*> switch
        ( long "delete-stale-locks"
        <> help "Delete stale lock files found during doctor run" )
  <*> optional
        ( argument str
            ( metavar "BRANCH"
            <> help "Branch to operate on" ) )

-- ---------------------------------------------------------------------------
-- Stub S3 ops (replace with real amazonka wiring for deployment)
-- ---------------------------------------------------------------------------

mkRealManageOps :: Maybe String -> String -> ManageS3Ops
mkRealManageOps _profile _bucket =
  ManageS3Ops
    { mgListObjects   = \_ -> ioStub "mgListObjects"
    , mgGetObjectBody = \_ -> ioStub "mgGetObjectBody"
    , mgPutObject     = \_ _ -> ioStub "mgPutObject"
    , mgDeleteObject  = \_ -> ioStub "mgDeleteObject"
    , mgCopyObject    = \_ _ -> ioStub "mgCopyObject"
    }
  where
    ioStub :: String -> IO a
    ioStub name = ioError (userError (name ++ ": real AWS SDK not wired in"))

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  opts <- execParser (info (optsParser <**> helper)
                          (fullDesc <> progDesc "Manage git-remote-s3 repositories"))

  -- Resolve remote URL via git
  remoteUrlResult <- try (getRemoteUrl (optRemote opts)) :: IO (Either GitError String)
  remoteUrl <- case remoteUrlResult of
    Left (GitError msg) -> do
      hPutStrLn stderr ("fatal: " ++ msg)
      hFlush stderr
      exitWith (ExitFailure 1)
    Right url -> return url

  case parseGitUrl remoteUrl of
    Nothing -> do
      hPutStrLn stderr ("fatal: invalid remote URL: " ++ remoteUrl)
      exitWith (ExitFailure 1)
    Just (ParseResult _scheme profile bucket mPrefix) -> do
      let prefix = maybe "" id mPrefix
          ops    = mkRealManageOps profile bucket

      result <- try (dispatch opts profile bucket prefix ops)
                  :: IO (Either SomeException ())
      case result of
        Left e -> do
          hPutStrLn stderr ("fatal: " ++ show e)
          exitWith (ExitFailure 1)
        Right _ -> exitSuccess

dispatch :: Opts -> Maybe String -> String -> String -> ManageS3Ops -> IO ()
dispatch opts _profile _bucket prefix ops = do
  let cmd = optCommand opts
  case cmd of
    "doctor" -> do
      let doc = newDoctor ops _bucket prefix
                          (optDeleteBundle opts)
                          (optLockTtl opts)
                          (optDeleteStaleLocks opts)
      runDoctor doc

    _ | cmd `elem` ["delete-branch", "protect", "unprotect"] ->
        case optBranch opts of
          Nothing -> do
            hPutStrLn stderr "fatal: branch name is required"
            hFlush stderr
            exitWith (ExitFailure 1)
          Just branch -> do
            mb <- newManageBranch ops _bucket prefix branch
            processBranchCmd mb cmd

    _ -> do
      hPutStrLn stderr ("fatal: unknown command '" ++ cmd ++ "'")
      exitWith (ExitFailure 1)
