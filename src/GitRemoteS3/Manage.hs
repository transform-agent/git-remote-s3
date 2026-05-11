-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Repository management commands (@doctor@, @delete-branch@,
-- @protect@, @unprotect@).
--
-- Mirrors @git_remote_s3/manage.py@.
module GitRemoteS3.Manage
  ( -- * Types
    Doctor (..)
  , ManageBranch (..)
  , ManageS3Ops (..)
    -- * Construction
  , newDoctor
  , newManageBranch
    -- * Operations
  , runDoctor
  , processBranchCmd
  ) where

import           Control.Exception          (SomeException, try)
import           Control.Monad              (forM_, when)
import           Data.List                  (intercalate, isPrefixOf, isSuffixOf)
import           Data.Maybe                 (fromMaybe)
import           Data.Time                  ( UTCTime, getCurrentTime
                                            , diffUTCTime )
import           System.IO                  (hFlush, stdout, hPutStr)

-- ---------------------------------------------------------------------------
-- S3 abstraction (injectable for tests)
-- ---------------------------------------------------------------------------

-- | S3 operations required by the management commands.
data ManageS3Ops = ManageS3Ops
  { mgListObjects  :: String           -- ^ prefix
                   -> IO [(String, UTCTime)]
    -- ^ List all objects under the prefix.
    -- Returns @(key, lastModified)@ pairs.

  , mgGetObjectBody :: String          -- ^ key
                    -> IO String
    -- ^ Read the UTF-8 body of an S3 object.

  , mgPutObject    :: String           -- ^ key
                   -> String           -- ^ body
                   -> IO ()

  , mgDeleteObject :: String           -- ^ key
                   -> IO ()

  , mgCopyObject   :: String           -- ^ source key
                   -> String           -- ^ destination key
                   -> IO ()
  }

-- ---------------------------------------------------------------------------
-- Internal repo-analysis types
-- ---------------------------------------------------------------------------

data BundleInfo = BundleInfo
  { biSha          :: String
  , biLastModified :: UTCTime
  } deriving (Show)

data RefInfo = RefInfo
  { riProtected :: Bool
  , riBundles   :: [BundleInfo]
  } deriving (Show)

data RepoInfo = RepoInfo
  { riRefs :: [(String, RefInfo)]  -- ^ (ref-path, RefInfo)
  , riHead :: String               -- ^ "Missing" | "Invalid" | actual ref
  } deriving (Show)

type RepoMap = [(String, RepoInfo)]

-- ---------------------------------------------------------------------------
-- Utility helpers
-- ---------------------------------------------------------------------------

splitOn :: Char -> String -> [String]
splitOn _ "" = []
splitOn c s  =
  let (h, t) = break (== c) s
  in h : case t of { [] -> []; (_:t') -> splitOn c t' }

strip :: String -> String
strip = reverse . dropWhile (`elem` "\n\r ") . reverse

-- ---------------------------------------------------------------------------
-- Doctor
-- ---------------------------------------------------------------------------

data Doctor = Doctor
  { doctorBucket           :: String
  , doctorPrefix           :: String
  , doctorDeleteBundle     :: Bool
  , doctorLockTtlSeconds   :: Int
  , doctorDeleteStaleLocks :: Bool
  , doctorOps              :: ManageS3Ops
  }

newDoctor :: ManageS3Ops
          -> String    -- ^ bucket
          -> String    -- ^ prefix
          -> Bool      -- ^ delete-bundle flag
          -> Int       -- ^ lock TTL seconds
          -> Bool      -- ^ delete stale locks
          -> Doctor
newDoctor ops bucket prefix del ttl delLocks = Doctor
  { doctorBucket           = bucket
  , doctorPrefix           = prefix
  , doctorDeleteBundle     = del
  , doctorLockTtlSeconds   = ttl
  , doctorDeleteStaleLocks = delLocks
  , doctorOps              = ops
  }

runDoctor :: Doctor -> IO ()
runDoctor doc = do
  repos <- analyzeRepo doc
  forM_ repos $ \(repoName, info) -> do
    putStrLn (repoName ++ ":")
    forM_ (riRefs info) $ \(ref, refInfo) -> do
      let star   = if riProtected refInfo then "*" else " "
          status = if length (riBundles refInfo) == 1 then "Ok" else "Multiple refs"
      putStrLn ("  " ++ star ++ " " ++ ref ++ ": " ++ status)
    putStrLn ("  HEAD: " ++ riHead info)

  fixIssues doc repos

fixIssues :: Doctor -> RepoMap -> IO ()
fixIssues doc repos = do
  forM_ repos $ \(repoName, info) -> do
    forM_ (riRefs info) $ \(ref, refInfo) ->
      when (length (riBundles refInfo) > 1) $
        fixMultipleBundles doc repos repoName ref
    when (riHead info == "Invalid") $
      fixHead doc repos repoName
  listAndHandleStaleLocks doc

listAndHandleStaleLocks :: Doctor -> IO ()
listAndHandleStaleLocks doc = do
  putStrLn "\nScanning for stale locks..."
  let ops = doctorOps doc
  allObjs <- mgListObjects ops (doctorPrefix doc ++ "/")
  now <- getCurrentTime
  let stale = [ (key, round age :: Int)
              | (key, lastMod) <- allObjs
              , ".lock" `isSuffixOf` key
              , let age = realToFrac (diffUTCTime now lastMod) :: Double
              , age > fromIntegral (doctorLockTtlSeconds doc)
              ]
  if null stale
    then putStrLn "No stale locks found."
    else do
      putStrLn "Found stale locks:"
      forM_ stale $ \(key, age) ->
        putStrLn ("  - " ++ key ++ " (age: " ++ show age ++ "s)")
      if doctorDeleteStaleLocks doc
        then do
          putStrLn "\nDeleting stale locks..."
          forM_ stale $ \(key, _) -> do
            result <- try (mgDeleteObject ops key) :: IO (Either SomeException ())
            case result of
              Left e  -> putStrLn ("Failed to delete " ++ key ++ ": " ++ show e)
              Right _ -> putStrLn ("Deleted " ++ key)
        else putStrLn "\nRun with --delete-stale-locks to remove them automatically."

analyzeRepo :: Doctor -> IO RepoMap
analyzeRepo doc = do
  let ops    = doctorOps doc
      prefix = doctorPrefix doc
  allObjs <- mgListObjects ops (prefix ++ "/")
  foldl (processObj doc) (return []) allObjs

processObj :: Doctor -> IO RepoMap -> (String, UTCTime) -> IO RepoMap
processObj doc accIO (key, lastMod) = do
  acc <- accIO
  let keyParts = splitOn '/' key
  if null keyParts
    then return acc
    else do
      let repoName = head keyParts
          repo     = fromMaybe (RepoInfo [] "Missing") (lookup repoName acc)
          acc'     = filter ((/= repoName) . fst) acc

      newRepo <-
        if length keyParts >= 2 && keyParts !! 1 == "HEAD"
          then do
            body <- mgGetObjectBody (doctorOps doc) key
            return repo { riHead = strip body }
          else do
            let refs'    = intercalate "/" (drop 1 (init keyParts))
                refInfo  = fromMaybe (RefInfo False []) (lookup refs' (riRefs repo))
                lastName = if null keyParts then "" else last keyParts
                refInfo' =
                  if lastName == "PROTECTED#"
                    then refInfo { riProtected = True }
                    else let sha = takeWhile (/= '.') lastName
                             bi  = BundleInfo sha lastMod
                         in refInfo { riBundles = riBundles refInfo ++ [bi] }
                newRefs = (refs', refInfo') : filter ((/= refs') . fst) (riRefs repo)
            return repo { riRefs = newRefs }

      -- Mark HEAD as Invalid if it doesn't match any known ref
      let finalRepo
            | riHead newRepo /= "Missing"
            , riHead newRepo /= "Invalid"
            , riHead newRepo `notElem` map fst (riRefs newRepo)
              = newRepo { riHead = "Invalid" }
            | otherwise = newRepo

      return ((repoName, finalRepo) : acc')

fixMultipleBundles :: Doctor -> RepoMap -> String -> String -> IO ()
fixMultipleBundles doc repos repoName ref = do
  putStrLn ("\nFix multiple bundles for repo " ++ repoName ++ " and ref " ++ ref)
  let bundles = case lookup repoName repos >>= lookup ref . riRefs of
                  Nothing -> []
                  Just ri -> riBundles ri
  forM_ (zip [1 :: Int ..] bundles) $ \(i, bi) ->
    putStrLn (show i ++ ". " ++ biSha bi ++ " " ++ show (biLastModified bi))
  promptBundle doc bundles ref

promptBundle :: Doctor -> [BundleInfo] -> String -> IO ()
promptBundle doc bundles ref = do
  hPutStr stdout "Enter the number of the bundle to keep: "
  hFlush stdout
  line <- getLine
  case reads line :: [(Int, String)] of
    [(i, "")] | i >= 1 && i <= length bundles -> do
      let keepSha  = biSha (bundles !! (i - 1))
          toRemove = [ biSha b | b <- bundles, biSha b /= keepSha ]
      putStrLn ("Keeping " ++ keepSha)
      hPutStr stdout "Press enter to confirm or Ctrl+C to cancel\n"
      hFlush stdout
      _ <- getLine
      forM_ toRemove $ \sha ->
        if doctorDeleteBundle doc
          then do
            putStrLn ("Removing " ++ sha)
            mgDeleteObject (doctorOps doc)
              (doctorPrefix doc ++ "/" ++ ref ++ "/" ++ sha ++ ".bundle")
          else do
            let tmpBranch = ref ++ "_tmp"
            putStrLn ("Moving " ++ sha ++ " to new branch " ++ tmpBranch)
            mgCopyObject (doctorOps doc)
              (doctorPrefix doc ++ "/" ++ ref ++ "/" ++ sha ++ ".bundle")
              (doctorPrefix doc ++ "/" ++ tmpBranch ++ "/" ++ sha ++ ".bundle")
            mgDeleteObject (doctorOps doc)
              (doctorPrefix doc ++ "/" ++ ref ++ "/" ++ sha ++ ".bundle")
    _ -> do
      putStrLn "Invalid input"
      promptBundle doc bundles ref

fixHead :: Doctor -> RepoMap -> String -> IO ()
fixHead doc repos repoName = do
  putStrLn ("\nFix invalid HEAD for repo " ++ repoName)
  let heads = case lookup repoName repos of
                Nothing   -> []
                Just info -> [ ref | (ref, _) <- riRefs info
                                   , "heads" `elem` splitOn '/' ref ]
  forM_ (zip [1 :: Int ..] heads) $ \(i, h) ->
    putStrLn (show i ++ ". " ++ last (splitOn '/' h))
  promptHead doc heads

promptHead :: Doctor -> [String] -> IO ()
promptHead doc heads = do
  hPutStr stdout "Enter the number of the branch to use as head: "
  hFlush stdout
  line <- getLine
  case reads line :: [(Int, String)] of
    [(i, "")] | i >= 1 && i <= length heads -> do
      let headRef = heads !! (i - 1)
      putStrLn ("Setting " ++ headRef ++ " as HEAD")
      mgPutObject (doctorOps doc) (doctorPrefix doc ++ "/HEAD") headRef
    _ -> do
      putStrLn "Invalid input"
      promptHead doc heads

-- ---------------------------------------------------------------------------
-- ManageBranch
-- ---------------------------------------------------------------------------

data ManageBranch = ManageBranch
  { mbBucket  :: String
  , mbPrefix  :: String
  , mbBranch  :: String
  , mbOps     :: ManageS3Ops
  }

newManageBranch :: ManageS3Ops
                -> String   -- ^ bucket
                -> String   -- ^ prefix
                -> String   -- ^ branch name
                -> IO ManageBranch
newManageBranch ops _bucket prefix branch = do
  content <- mgListObjects ops (prefix ++ "/refs/heads/" ++ branch ++ "/")
  if null content
    then ioError (userError ("Branch " ++ branch ++ " does not exist"))
    else return ManageBranch
           { mbBucket = _bucket
           , mbPrefix = prefix
           , mbBranch = branch
           , mbOps    = ops
           }

processBranchCmd :: ManageBranch -> String -> IO ()
processBranchCmd mb cmd = case cmd of
  "delete-branch" -> deleteBranch mb
  "protect"       -> protectBranch mb
  "unprotect"     -> unprotectBranch mb
  _               -> putStrLn ("unknown command: " ++ cmd)

deleteBranch :: ManageBranch -> IO ()
deleteBranch mb = do
  objs <- mgListObjects (mbOps mb)
                        (mbPrefix mb ++ "/refs/heads/" ++ mbBranch mb ++ "/")
  hPutStr stdout ("Delete " ++ mbBranch mb ++ " branch [yes/no]: ")
  hFlush stdout
  resp <- getLine
  if map toLower resp == "yes"
    then do
      forM_ objs $ \(key, _) -> mgDeleteObject (mbOps mb) key
      putStrLn ("Branch " ++ mbBranch mb ++ " has been deleted")
    else putStrLn "Aborted"
  where
    toLower c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise             = c

protectBranch :: ManageBranch -> IO ()
protectBranch mb = do
  let key = mbPrefix mb ++ "/refs/heads/" ++ mbBranch mb ++ "/PROTECTED#"
  mgPutObject (mbOps mb) key ""
  putStrLn ("Branch " ++ mbBranch mb ++ " is now protected")

unprotectBranch :: ManageBranch -> IO ()
unprotectBranch mb = do
  let key = mbPrefix mb ++ "/refs/heads/" ++ mbBranch mb ++ "/PROTECTED#"
  mgDeleteObject (mbOps mb) key
  putStrLn ("Branch " ++ mbBranch mb ++ " is now unprotected")
