-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Wrappers around @git@ subprocess calls.
--
-- Mirrors @git_remote_s3/git.py@.
module GitRemoteS3.Git
  ( GitError (..)
  , archive
  , bundle
  , unbundle
  , revParse
  , isAncestor
  , getRemoteUrl
  , validateRefName
  , getLastCommitMessage
  ) where

import           Control.Exception          (Exception, throwIO)
import           System.Exit                (ExitCode (..))
import           System.IO                  (stderr, hPutStr)
import           System.Process             ( readProcessWithExitCode
                                            , createProcess
                                            , proc
                                            , std_out
                                            , std_err
                                            , StdStream (..)
                                            , waitForProcess
                                            )
import           Text.Regex.TDFA            ((=~))

-- ---------------------------------------------------------------------------
-- Exception type
-- ---------------------------------------------------------------------------

-- | Raised when a @git@ subprocess call fails.
newtype GitError = GitError String
  deriving (Show)

instance Exception GitError

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Run a @git@ command, capturing stdout and stderr.
-- Throws 'GitError' on non-zero exit code.
runGit :: [String] -> IO String
runGit args = do
  (code, out, err) <- readProcessWithExitCode "git" args ""
  case code of
    ExitSuccess   -> return out
    ExitFailure _ -> throwIO (GitError err)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | @git archive --format zip --output \<folder\>\/repo.zip \<ref\>@
--
-- Returns the path to the created archive file.
archive :: FilePath  -- ^ Destination folder
        -> String    -- ^ Git ref to archive
        -> IO FilePath
archive folder ref = do
  let filePath = folder ++ "/repo.zip"
  _ <- runGit ["archive", "--format", "zip", "--output", filePath, ref]
  return filePath

-- | @git bundle create \<folder\>\/\<sha\>.bundle \<ref\>@
--
-- Returns the path to the created bundle file.
bundle :: FilePath  -- ^ Destination folder
       -> String    -- ^ SHA (used as the bundle file name stem)
       -> String    -- ^ Git ref to bundle
       -> IO FilePath
bundle folder sha ref = do
  let filePath = folder ++ "/" ++ sha ++ ".bundle"
  _ <- runGit ["bundle", "create", filePath, ref]
  return filePath

-- | @git bundle unbundle \<folder\>\/\<sha\>.bundle \<ref\>@
--
-- stdout is redirected to stderr so git's progress output reaches the
-- user (mirrors the Python implementation which sets @stdout=sys.stderr@).
unbundle :: FilePath  -- ^ Folder containing the bundle
         -> String    -- ^ SHA (bundle file name stem)
         -> String    -- ^ Git ref
         -> IO ()
unbundle folder sha ref = do
  let bundlePath = folder ++ "/" ++ sha ++ ".bundle"
  (_, _, _, ph) <- createProcess
    (proc "git" ["bundle", "unbundle", bundlePath, ref])
      { std_out = UseHandle stderr
      , std_err = UseHandle stderr
      }
  code <- waitForProcess ph
  case code of
    ExitSuccess   -> return ()
    ExitFailure _ -> throwIO (GitError "git bundle unbundle failed")

-- | @git rev-parse \<ref\>@
--
-- Returns the full SHA for the given ref.
-- Throws 'GitError' when the ref is not found.
revParse :: String -> IO String
revParse ref = do
  (code, out, _) <- readProcessWithExitCode "git" ["rev-parse", ref] ""
  case code of
    ExitSuccess   -> return (strip out)
    ExitFailure _ -> throwIO (GitError ("fatal: " ++ ref ++ " not found"))
  where
    strip = reverse . dropWhile (== '\n') . reverse

-- | @git merge-base --is-ancestor \<ancestor\> \<descendant\>@
--
-- Returns @True@ iff @ancestor@ is an ancestor of @descendant@.
isAncestor :: String -> String -> IO Bool
isAncestor ancestor descendant = do
  (code, _, _) <- readProcessWithExitCode
    "git" ["merge-base", "--is-ancestor", ancestor, descendant] ""
  return (code == ExitSuccess)

-- | @git remote get-url \<remote\>@
--
-- Returns the URL configured for the named remote.
-- Throws 'GitError' when the remote is not found.
getRemoteUrl :: String -> IO String
getRemoteUrl remote = do
  (code, out, _) <- readProcessWithExitCode "git" ["remote", "get-url", remote] ""
  case code of
    ExitSuccess   -> return (strip out)
    ExitFailure _ -> throwIO (GitError ("fatal: " ++ remote ++ " not found"))
  where
    strip = reverse . dropWhile (== '\n') . reverse

-- | Validate a git ref name according to git's own rules.
--
-- Returns @True@ iff the name is valid.
-- Mirrors the regex from @refs.c@ in the git source tree:
-- https://github.com/git/git/blob/406f326d/refs.c#L170
validateRefName :: String -> Bool
validateRefName name =
  not (name =~ badPattern :: Bool)
  where
    badPattern :: String
    badPattern =
      "(^\\.)|(\\.\\.)|([:?\\[\\\\\\^~\\s\\*]])|\\.lock$|(/$)|(@\\{)|([\\x00-\\x1f])"

-- | @git log -1 --pretty=%h %s@
--
-- Returns a short summary of the last commit.
-- Throws 'GitError' on failure.
getLastCommitMessage :: IO String
getLastCommitMessage = do
  (code, out, _) <- readProcessWithExitCode "git" ["log", "-1", "--pretty=%h %s"] ""
  case code of
    ExitSuccess   -> return (strip out)
    ExitFailure _ -> throwIO (GitError "fatal: an error has occurred")
  where
    strip = reverse . dropWhile (== '\n') . reverse
