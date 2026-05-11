-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Core git-remote-helper protocol implementation.
--
-- Mirrors @git_remote_s3/remote.py@.
--
-- NOTE on AWS SDK usage:
--   This module uses IORef\/MVar-based abstractions for the S3 operations
--   so that tests can inject a pure in-memory fake implementation.
--   The real implementation wires in @amazonka-s3@ calls.
--   All S3 calls that need the @IfNoneMatch="*"@ conditional header are
--   performed via 's3PutObjectConditional'; see 'acquireLock'.
module GitRemoteS3.Remote
  ( -- * Types
    S3Remote (..)
  , Mode (..)
  , BucketNotFoundError (..)
  , NotAuthorizedError (..)
  , S3Object (..)
  , S3Ops (..)
    -- * Construction
  , newS3Remote
    -- * Protocol commands
  , cmdCapabilities
  , cmdList
  , cmdFetch
  , cmdPush
  , cmdOption
  , processCmd
  , processFetchCmds
    -- * Helpers exposed for tests
  , listRefs
  , getRemoteHead
  , initRemoteHead
  , getBundlesForRef
  , isProtected
  , acquireLock
  , releaseLock
  , removeRemoteRef
    -- * Constants
  , defaultLockTtlSeconds
  ) where

import           Control.Concurrent         (MVar, newMVar, withMVar, modifyMVar_)
import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Exception          (Exception, SomeException, try, throwIO)
import           Control.Monad              (forM_, unless, when)
import           Data.IORef                 ( IORef, newIORef, readIORef
                                            , writeIORef, modifyIORef')
import           Data.List                  (isPrefixOf, isSuffixOf, sortBy, tails)
import           Data.Maybe                 (isNothing)
import           Data.Ord                   (comparing, Down (..))
import           Data.Time                  ( UTCTime, getCurrentTime
                                            , diffUTCTime )
import           System.Directory           (removeFile, doesFileExist)
import           System.Environment         (lookupEnv)
import           System.Exit                (exitWith, ExitCode (..))
import           System.IO                  ( hPutStrLn, hFlush, stderr, stdout
                                            , hPutStr )
import           System.IO.Temp             (createTempDirectory)
import           Text.Regex.TDFA            ((=~))

import qualified GitRemoteS3.Git           as Git
import           GitRemoteS3.Enums          (UriScheme (..))

-- ---------------------------------------------------------------------------
-- Exceptions
-- ---------------------------------------------------------------------------

newtype BucketNotFoundError = BucketNotFoundError { bucketName :: String }
  deriving (Show)
instance Exception BucketNotFoundError

data NotAuthorizedError = NotAuthorizedError { naAction :: String, naBucket :: String }
  deriving (Show)
instance Exception NotAuthorizedError

-- ---------------------------------------------------------------------------
-- S3 abstraction layer (injectable for tests)
-- ---------------------------------------------------------------------------

-- | A single S3 object with its key and last-modified timestamp.
data S3Object = S3Object
  { objKey          :: String
  , objLastModified :: UTCTime
  } deriving (Eq, Show)

-- | Abstract S3 operations.  The real implementation is wired in
-- 'newS3Remote'; tests provide their own.
data S3Ops = S3Ops
  { s3ListObjects  :: String  -- ^ prefix
                   -> IO [S3Object]
    -- ^ List objects with the given prefix.  Returns all pages.

  , s3GetObjectBody :: String  -- ^ key
                    -> IO String
    -- ^ Get the UTF-8 body of an object.

  , s3PutObject    :: String   -- ^ key
                   -> String   -- ^ body
                   -> [(String, String)]  -- ^ extra metadata headers
                   -> IO ()
    -- ^ Upload an object.

  , s3PutObjectConditional :: String  -- ^ key
                           -> IO Bool
    -- ^ @PUT@ with @IfNoneMatch: *@.  Returns @True@ on success,
    -- @False@ when the object already exists (412).

  , s3DeleteObject  :: String  -- ^ key
                   -> IO ()
    -- ^ Delete an object.

  , s3DownloadFile :: String   -- ^ key
                   -> FilePath -- ^ destination path
                   -> IO ()
    -- ^ Download an object to a local file.

  , s3UploadFile   :: FilePath  -- ^ source path
                   -> String    -- ^ key
                   -> IO ()
    -- ^ Upload a local file to S3.

  , s3HeadObject   :: String  -- ^ key
                   -> IO (Maybe UTCTime)
    -- ^ @HEAD@ an object, returning its last-modified time if it exists.
  }

-- ---------------------------------------------------------------------------
-- Mode
-- ---------------------------------------------------------------------------

data Mode = Fetch | Push deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Default lock TTL
-- ---------------------------------------------------------------------------

defaultLockTtlSeconds :: Int
defaultLockTtlSeconds = 60

-- ---------------------------------------------------------------------------
-- S3Remote record
-- ---------------------------------------------------------------------------

data S3Remote = S3Remote
  { remoteUriScheme      :: UriScheme
  , remoteProfile        :: Maybe String
  , remoteBucket         :: String
  , remotePrefix         :: String
  , remoteS3Ops          :: S3Ops
  , remoteFetchedRefs    :: MVar [String]
  , remotePushCmds       :: IORef [String]
  , remoteFetchCmds      :: IORef [String]
  , remoteMode           :: IORef (Maybe Mode)
  , remoteLockTtlSeconds :: Int
  , remoteVerbose        :: IORef Bool
  }

-- | Log to stderr when verbose is enabled.
logInfo :: S3Remote -> String -> IO ()
logInfo remote msg = do
  verbose <- readIORef (remoteVerbose remote)
  when verbose $ hPutStrLn stderr msg

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Build an 'S3Remote' using the provided S3 operations.
newS3Remote
  :: UriScheme
  -> Maybe String   -- ^ AWS profile (Nothing = default credential chain)
  -> String         -- ^ S3 bucket name
  -> String         -- ^ S3 key prefix
  -> S3Ops          -- ^ injectable S3 operations
  -> IO S3Remote
newS3Remote scheme profile bucket prefix ops = do
  -- Verify bucket is accessible by listing with the prefix
  result <- try (s3ListObjects ops prefix) :: IO (Either SomeException [S3Object])
  case result of
    Left _  -> throwIO (BucketNotFoundError bucket)
    Right _ -> return ()

  fetchedRefs <- newMVar []
  pushCmds    <- newIORef []
  fetchCmds   <- newIORef []
  mode        <- newIORef Nothing
  verbose     <- newIORef False

  ttl <- do
    menv <- lookupEnv "GIT_REMOTE_S3_LOCK_TTL_SECONDS"
    case menv of
      Nothing -> return defaultLockTtlSeconds
      Just v  -> case reads v of
        [(n, "")] -> return n
        _         -> return defaultLockTtlSeconds

  verboseEnv <- lookupEnv "GIT_REMOTE_S3_VERBOSE"
  let isVerbose = case verboseEnv of
        Just s -> s `elem` ["1", "true", "yes"]
        Nothing -> False
  writeIORef verbose isVerbose

  return S3Remote
    { remoteUriScheme      = scheme
    , remoteProfile        = profile
    , remoteBucket         = bucket
    , remotePrefix         = prefix
    , remoteS3Ops          = ops
    , remoteFetchedRefs    = fetchedRefs
    , remotePushCmds       = pushCmds
    , remoteFetchCmds      = fetchCmds
    , remoteMode           = mode
    , remoteLockTtlSeconds = ttl
    , remoteVerbose        = verbose
    }

-- ---------------------------------------------------------------------------
-- listRefs
-- ---------------------------------------------------------------------------

-- | List remote refs, sorted newest-first by last-modified time.
-- Returns only bundle objects (*.bundle under refs/).
listRefs :: S3Remote -> IO [String]
listRefs remote = do
  let ops    = remoteS3Ops remote
      prefix = remotePrefix remote
  objs <- s3ListObjects ops prefix
  let sorted = sortBy (comparing (Down . objLastModified)) objs
      keys   = [ drop (length prefix + 1) (objKey o)
               | o <- sorted
               , (prefix ++ "/refs") `isPrefixOf` objKey o
               , ".bundle" `isSuffixOf` objKey o
               ]
  return keys

-- ---------------------------------------------------------------------------
-- cmdCapabilities
-- ---------------------------------------------------------------------------

cmdCapabilities :: IO ()
cmdCapabilities = do
  putStr "*push\n"
  putStr "*fetch\n"
  putStr "option\n"
  putStr "\n"
  hFlush stdout

-- ---------------------------------------------------------------------------
-- getRemoteHead / initRemoteHead
-- ---------------------------------------------------------------------------

getRemoteHead :: S3Remote -> IO String
getRemoteHead remote =
  s3GetObjectBody (remoteS3Ops remote)
                  (remotePrefix remote ++ "/HEAD")

initRemoteHead :: S3Remote -> String -> IO ()
initRemoteHead remote ref = do
  let ops = remoteS3Ops remote
      key = remotePrefix remote ++ "/HEAD"
  mtime <- s3HeadObject ops key
  when (isNothing mtime) $
    s3PutObject ops key ref []

-- ---------------------------------------------------------------------------
-- cmdList
-- ---------------------------------------------------------------------------

cmdList :: S3Remote -> Bool -> IO ()
cmdList remote forPush = do
  objs <- listRefs remote
  logInfo remote (show objs)

  unless forPush $ do
    result <- try (getRemoteHead remote) :: IO (Either SomeException String)
    case result of
      Left _        -> return ()   -- ignore missing HEAD
      Right headRef -> do
        logInfo remote ("HEAD=[" ++ headRef ++ "]")
        forM_ objs $ \o -> do
          let ref = pathDir o
          when (ref == headRef) $ do
            logInfo remote ("@" ++ ref ++ " HEAD")
            putStr ("@" ++ ref ++ " HEAD\n")

  forM_ [ o | o <- objs, o =~ bundlePattern :: Bool ] $ \o -> do
    let elements = splitPath o
        sha      = takeWhile (/= '.') (last elements)
        ref      = joinPath (init elements)
    putStr (sha ++ " " ++ ref ++ "\n")

  putStr "\n"
  hFlush stdout
  where
    bundlePattern :: String
    bundlePattern = ".+/.+/.+/[a-f0-9]{40}\\.bundle"

    -- Directory part of a path (everything except the last component)
    pathDir :: String -> String
    pathDir s = joinPath (init (splitPath s))

    splitPath :: String -> [String]
    splitPath ""  = []
    splitPath s   =
      let (h, t) = break (== '/') s
      in h : case t of { [] -> []; (_:t') -> splitPath t' }

    joinPath :: [String] -> String
    joinPath []     = ""
    joinPath [x]    = x
    joinPath (x:xs) = x ++ "/" ++ joinPath xs

-- ---------------------------------------------------------------------------
-- cmdOption
-- ---------------------------------------------------------------------------

cmdOption :: S3Remote -> String -> IO ()
cmdOption remote arg = do
  let parts  = words arg        -- ["option", <name>, <value>]
      option = if length parts > 1 then parts !! 1 else ""
      value  = if length parts > 2 then parts !! 2 else ""
  if option == "verbosity" && readInt value >= 2
    then do
      writeIORef (remoteVerbose remote) True
      putStr "ok\n"
    else putStr "unsupported\n"
  hFlush stdout
  where
    readInt s = case reads s :: [(Int, String)] of
      [(n, "")] -> n
      _         -> 0

-- ---------------------------------------------------------------------------
-- getBundlesForRef / isProtected
-- ---------------------------------------------------------------------------

getBundlesForRef :: S3Remote -> String -> IO [S3Object]
getBundlesForRef remote remoteRef = do
  let ops    = remoteS3Ops remote
      prefix = remotePrefix remote ++ "/" ++ remoteRef ++ "/"
  objs <- s3ListObjects ops prefix
  return
    [ o
    | o <- objs
    , not ("PROTECTED#" `isSuffixOf` objKey o)
    , not (".zip"        `isSuffixOf` objKey o)
    , not ("/LOCKS/"     `isInfixOf`  objKey o)
    , not (".lock"       `isSuffixOf` objKey o)
    ]
  where
    isInfixOf needle haystack =
      any (isPrefixOf needle) (tails haystack)

isProtected :: S3Remote -> String -> IO Bool
isProtected remote remoteRef = do
  let ops    = remoteS3Ops remote
      prefix = remotePrefix remote ++ "/" ++ remoteRef ++ "/PROTECTED#"
  objs <- s3ListObjects ops prefix
  return (not (null objs))

-- ---------------------------------------------------------------------------
-- removeRemoteRef
-- ---------------------------------------------------------------------------

removeRemoteRef :: S3Remote -> String -> IO String
removeRemoteRef remote remoteRef = do
  let ops = remoteS3Ops remote
  objsToDelete <- s3ListObjects ops
                                (remotePrefix remote ++ "/" ++ remoteRef ++ "/")
  let scheme    = remoteUriScheme remote
      expected  = case scheme of
                    S3    -> 1
                    S3Zip -> 2
  case length objsToDelete of
    0 -> return ("error " ++ remoteRef ++ " not found\n")
    n | n == expected ->
        do forM_ objsToDelete (\o -> s3DeleteObject ops (objKey o))
           return ("ok " ++ remoteRef ++ "\n")
      | otherwise ->
        return ("error " ++ remoteRef
                ++ " \"multiple bundles exists on server. "
                ++ "Run git-s3 doctor to fix.\"?\n")

-- ---------------------------------------------------------------------------
-- acquireLock / releaseLock
-- ---------------------------------------------------------------------------

acquireLock :: S3Remote -> String -> IO (Maybe String)
acquireLock remote remoteRef = do
  let ops     = remoteS3Ops remote
      lockKey = remotePrefix remote ++ "/" ++ remoteRef ++ "/LOCK#.lock"
  acquired <- s3PutObjectConditional ops lockKey
  if acquired
    then return (Just lockKey)
    else do
      -- Check for staleness
      mtime <- s3HeadObject ops lockKey
      case mtime of
        Nothing -> return Nothing
        Just lastModified -> do
          now <- getCurrentTime
          let age = realToFrac (diffUTCTime now lastModified) :: Double
          if age > fromIntegral (remoteLockTtlSeconds remote)
            then do
              -- Delete stale lock and retry once
              result <- try (s3DeleteObject ops lockKey) :: IO (Either SomeException ())
              case result of
                Left _  -> return Nothing
                Right _ -> do
                  acquired2 <- s3PutObjectConditional ops lockKey
                  if acquired2 then return (Just lockKey) else return Nothing
            else return Nothing

releaseLock :: S3Remote -> String -> IO ()
releaseLock remote lockKey = do
  let ops = remoteS3Ops remote
  result <- try (s3DeleteObject ops lockKey) :: IO (Either SomeException ())
  case result of
    Left _  -> logInfo remote ("lock " ++ lockKey ++ " already released or failed")
    Right _ -> return ()

-- ---------------------------------------------------------------------------
-- cmdFetch
-- ---------------------------------------------------------------------------

cmdFetch :: S3Remote -> String -> IO ()
cmdFetch remote args = do
  let parts  = words args   -- ["fetch", sha, ref]
      sha    = if length parts > 1 then parts !! 1 else ""
      ref    = if length parts > 2 then parts !! 2 else ""

  -- De-duplicate: skip if already fetched this session
  alreadyFetched <- withMVar (remoteFetchedRefs remote) (return . (sha `elem`))
  if alreadyFetched
    then return ()
    else do
      logInfo remote ("fetch " ++ sha ++ " " ++ ref)
      tempDir <- createTempDirectory "/tmp" "git_remote_s3_fetch_"
      let bundlePath = tempDir ++ "/" ++ sha ++ ".bundle"
          key        = remotePrefix remote ++ "/" ++ ref ++ "/" ++ sha ++ ".bundle"
      result <- try (s3DownloadFile (remoteS3Ops remote) key bundlePath)
                  :: IO (Either SomeException ())
      case result of
        Left e -> do
          cleanupFile tempDir sha
          throwIO e
        Right _ -> do
          logInfo remote ("fetched " ++ bundlePath ++ " " ++ ref)
          Git.unbundle tempDir sha ref
          modifyMVar_ (remoteFetchedRefs remote) (return . (sha :))
          cleanupFile tempDir sha
  where
    cleanupFile dir sha = do
      let p = dir ++ "/" ++ sha ++ ".bundle"
      exists <- doesFileExist p
      when exists (removeFile p)

-- ---------------------------------------------------------------------------
-- processFetchCmds
-- ---------------------------------------------------------------------------

processFetchCmds :: S3Remote -> [String] -> IO ()
processFetchCmds _ [] = return ()
processFetchCmds remote cmds = do
  logInfo remote ("Processing " ++ show (length cmds) ++ " fetch commands in parallel")
  mapConcurrently_ (cmdFetch remote) cmds
  logInfo remote ("Completed processing " ++ show (length cmds) ++ " fetch commands")

-- ---------------------------------------------------------------------------
-- cmdPush
-- ---------------------------------------------------------------------------

cmdPush :: S3Remote -> String -> IO String
cmdPush remote args = do
  let parts         = words args  -- ["push", "localRef:remoteRef"]
      refPair       = if length parts > 1 then parts !! 1 else ":"
      colonIdx      = break (== ':') refPair
      localRaw      = fst colonIdx
      remoteRef     = drop 1 (snd colonIdx)
      (forcePush0, localRef0) =
        if "+" `isPrefixOf` localRaw
          then (True, drop 1 localRaw)
          else (False, localRaw)

  -- Empty localRef => delete the remote ref
  if null localRef0
    then removeRemoteRef remote remoteRef
    else do
      protected <- isProtected remote remoteRef
      let forcePush = forcePush0 && not protected

      logInfo remote ("push !" ++ localRef0 ++ "! !" ++ remoteRef ++ "!")

      contents <- getBundlesForRef remote remoteRef
      if length contents > 1
        then return ("error " ++ remoteRef
                     ++ " \"multiple bundles exists on server. "
                     ++ "Run git-s3 doctor to fix.\"?\n")
        else do
          let remoteToRemove = if null contents then Nothing
                               else Just (objKey (head contents))

          tempDir <- createTempDirectory "/tmp" "git_remote_s3_push_"

          -- Local git rev-parse (before lock)
          shaResult <- try (Git.revParse localRef0) :: IO (Either SomeException String)
          case shaResult of
            Left _ -> do
              logInfo remote ("fatal: " ++ localRef0 ++ " not found")
              return ("error " ++ remoteRef ++ " \"" ++ localRef0 ++ " not found\"?\n")
            Right sha -> do
              -- Check ancestor relationship when not force-pushing
              ancestorOk <- case remoteToRemove of
                Nothing -> return True
                Just remKey -> do
                  let remoteSha = takeWhile (/= '.') (last (splitPath remKey))
                  if forcePush
                    then return True
                    else Git.isAncestor remoteSha sha
              if not ancestorOk
                then return ("error " ++ remoteRef
                              ++ " \"remote ref is not ancestor of "
                              ++ localRef0 ++ ".\"?\n")
                else do
                  -- Create bundle locally before acquiring lock
                  bundleResult <- try (Git.bundle tempDir sha localRef0)
                                    :: IO (Either SomeException FilePath)
                  case bundleResult of
                    Left e ->
                      return ("error " ++ remoteRef ++ " \"" ++ show e ++ "\"?\n")
                    Right tempFile -> do
                      -- Acquire per-ref lock
                      mLockKey <- acquireLock remote remoteRef
                      case mLockKey of
                        Nothing -> do
                          let lockPath = remotePrefix remote ++ "/"
                                         ++ remoteRef ++ "/LOCK#.lock"
                          return ( "error " ++ remoteRef
                                   ++ " \"failed to acquire ref lock at " ++ lockPath
                                   ++ ". Another client may be pushing. "
                                   ++ "If this persists beyond "
                                   ++ show (remoteLockTtlSeconds remote) ++ "s, "
                                   ++ "run git-remote-s3 doctor --lock-ttl "
                                   ++ show (remoteLockTtlSeconds remote)
                                   ++ " to inspect and optionally clear stale locks.\"?\n" )
                        Just lockKey ->
                          doPushWithLock remote remoteRef sha tempFile
                                         remoteToRemove lockKey localRef0
  where
    splitPath :: String -> [String]
    splitPath ""  = []
    splitPath s   =
      let (h, t) = break (== '/') s
      in h : case t of { [] -> []; (_:t') -> splitPath t' }

doPushWithLock :: S3Remote -> String -> String -> FilePath
               -> Maybe String -> String -> String -> IO String
doPushWithLock remote remoteRef sha tempFile remoteToRemove lockKey localRef = do
  result <- try (doUpload remote remoteRef sha tempFile remoteToRemove localRef)
              :: IO (Either SomeException String)
  releaseLock remote lockKey
  case result of
    Left e  -> return ("error " ++ remoteRef ++ " \"" ++ show e ++ "\"?\n")
    Right r -> return r

doUpload :: S3Remote -> String -> String -> FilePath
         -> Maybe String -> String -> IO String
doUpload remote remoteRef sha tempFile remoteToRemove localRef = do
  let ops    = remoteS3Ops remote
      prefix = remotePrefix remote

  -- Re-check for multiple bundles after acquiring lock
  currentContents <- getBundlesForRef remote remoteRef
  if length currentContents > 1
    then return ("error " ++ remoteRef
                 ++ " \"multiple bundles exists for the same ref on server. "
                 ++ "Run git-s3 doctor to fix. "
                 ++ "Upgrade git-remote-s3 to latest version to prevent this in the future.\"\n")
    else do
      let currentRemoteToRemove = if null currentContents then Nothing
                                  else Just (objKey (head currentContents))

      -- Stale-remote check
      let stale = case (remoteToRemove, currentRemoteToRemove) of
                    (Just r, Just c) -> r /= c
                    _                -> False
      if stale
        then return ("error " ++ remoteRef
                      ++ " \"stale remote. Please fetch and retry.\"?\n")
        else do
          -- Upload the bundle
          let bundleKey = prefix ++ "/" ++ remoteRef ++ "/" ++ sha ++ ".bundle"
          s3UploadFile ops tempFile bundleKey

          -- Set HEAD if needed
          initRemoteHead remote remoteRef
          logInfo remote ("pushed " ++ tempFile ++ " to " ++ remoteRef)

          -- Delete old bundle
          case remoteToRemove of
            Nothing  -> return ()
            Just key -> s3DeleteObject ops key

          -- S3_ZIP: also upload a repo.zip archive
          when (remoteUriScheme remote == S3Zip) $ do
            commitMsg    <- Git.getLastCommitMessage
            zipTempDir   <- createTempDirectory "/tmp" "git_remote_s3_zip_"
            archivePath  <- Git.archive zipTempDir localRef
            let zipKey = prefix ++ "/" ++ remoteRef ++ "/repo.zip"
            -- Upload zip with CodePipeline metadata
            -- TODO: In the real implementation, stream archivePath as Body
            -- and set Metadata and ContentDisposition via amazonka.
            s3PutObject ops zipKey ""
              [ ("codepipeline-artifact-revision-summary", commitMsg)
              , ("content-disposition",
                 "attachment; filename=repo-" ++ take 8 sha ++ ".zip")
              ]
            logInfo remote ("pushed " ++ archivePath ++ " to " ++ zipKey
                            ++ " with message " ++ commitMsg)

          return ("ok " ++ remoteRef ++ "\n")

-- ---------------------------------------------------------------------------
-- processCmd  (main protocol loop dispatcher)
-- ---------------------------------------------------------------------------

processCmd :: S3Remote -> String -> IO ()
processCmd remote cmd
  | "fetch" `isPrefixOf` trimCmd = do
      curMode <- readIORef (remoteMode remote)
      when (curMode /= Just Fetch) $ do
        writeIORef (remoteMode remote) (Just Fetch)
        writeIORef (remoteFetchCmds remote) []
      modifyIORef' (remoteFetchCmds remote) (++ [trimCmd])

  | "push" `isPrefixOf` trimCmd = do
      curMode <- readIORef (remoteMode remote)
      when (curMode /= Just Push) $ do
        writeIORef (remoteMode remote) (Just Push)
        writeIORef (remotePushCmds remote) []
      modifyIORef' (remotePushCmds remote) (++ [trimCmd])

  | "option" `isPrefixOf` trimCmd =
      cmdOption remote trimCmd

  | "list for-push" `isPrefixOf` trimCmd =
      cmdList remote True

  | "list" `isPrefixOf` trimCmd =
      cmdList remote False

  | "capabilities" `isPrefixOf` trimCmd =
      cmdCapabilities

  | trimCmd == "" = do
      curMode <- readIORef (remoteMode remote)
      case curMode of
        Just Push -> do
          pushCs <- readIORef (remotePushCmds remote)
          unless (null pushCs) $ do
            logInfo remote ("pushing " ++ show pushCs)
            results <- mapM (cmdPush remote) pushCs
            mapM_ putStr results
            writeIORef (remotePushCmds remote) []
        Just Fetch -> do
          fetchCs <- readIORef (remoteFetchCmds remote)
          unless (null fetchCs) $ do
            logInfo remote ("fetching " ++ show (length fetchCs) ++ " refs in parallel")
            processFetchCmds remote fetchCs
            writeIORef (remoteFetchCmds remote) []
        Nothing -> return ()
      putStr "\n"
      hFlush stdout

  | otherwise = do
      hPutStrLn stderr ("fatal: invalid command '" ++ trimCmd ++ "'")
      hFlush stderr
      exitWith (ExitFailure 1)

  where
    trimCmd = reverse . dropWhile (== '\n') . reverse $ cmd
