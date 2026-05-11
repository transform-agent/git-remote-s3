-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Git LFS custom-transfer agent implementation.
--
-- Mirrors @git_remote_s3/lfs.py@.
--
-- Protocol: the agent reads JSON lines from stdin and writes JSON
-- lines to stdout.  See the git-lfs custom-transfer documentation:
-- https://github.com/git-lfs/git-lfs/blob/main/docs/custom-transfers.md
module GitRemoteS3.Lfs
  ( LFSProcess (..)
  , LFSS3Ops (..)
  , newLFSProcess
  , lfsUpload
  , lfsDownload
  , lfsInstall
  , lfsMain
  ) where

import           Control.Concurrent         (MVar, newMVar, withMVar, modifyMVar_)
import           Control.Exception          (SomeException, try)
import           Control.Monad              (unless, when)
import           Data.Aeson                 ( Value (..), object, (.=)
                                            , encode )
import qualified Data.Aeson                as Aeson
import qualified Data.Aeson.KeyMap         as KM
import qualified Data.Aeson.Key            as AKey
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.IORef                 (IORef, newIORef, readIORef, modifyIORef')
import           Data.Maybe                 (fromMaybe)
import qualified Data.Text                 as T
import           System.Directory           (makeAbsolute, createDirectoryIfMissing)
import           System.Exit                (exitWith, exitSuccess, ExitCode (..))
import           System.IO                  ( hPutStrLn, hFlush, stderr, stdout
                                            , hSetBuffering, BufferMode (..)
                                            , stdin )
import           System.Process             (readProcessWithExitCode)

import           GitRemoteS3.Common         (parseGitUrl, ParseResult (..))
import           GitRemoteS3.Git            (validateRefName)

-- ---------------------------------------------------------------------------
-- Progress callback
-- ---------------------------------------------------------------------------

-- | Emits @progress@ JSON events to stdout as bytes are transferred.
-- Mirrors the Python @ProgressPercentage@ callable class.
data ProgressCallback = ProgressCallback
  { pcOid        :: String
  , pcSeenSoFar  :: IORef Integer
  , pcLock       :: MVar ()
  }

newProgressCallback :: String -> IO ProgressCallback
newProgressCallback oid = do
  seenRef <- newIORef 0
  lock    <- newMVar ()
  return ProgressCallback
    { pcOid       = oid
    , pcSeenSoFar = seenRef
    , pcLock      = lock
    }

reportProgress :: ProgressCallback -> Integer -> IO ()
reportProgress cb bytesAmount =
  withMVar (pcLock cb) $ \_ -> do
    modifyIORef' (pcSeenSoFar cb) (+ bytesAmount)
    seenSoFar <- readIORef (pcSeenSoFar cb)
    let evt = object
          [ "event"          .= ("progress" :: String)
          , "oid"            .= pcOid cb
          , "bytesSoFar"     .= seenSoFar
          , "bytesSinceLast" .= bytesAmount
          ]
    BLC.putStrLn (encode evt)
    hFlush stdout

-- ---------------------------------------------------------------------------
-- Error event helper
-- ---------------------------------------------------------------------------

writeErrorEvent :: String -> String -> IO ()
writeErrorEvent oid errMsg = do
  let evt = object
        [ "event" .= ("complete" :: String)
        , "oid"   .= oid
        , "error" .= object [ "code" .= (2 :: Int), "message" .= errMsg ]
        ]
  BLC.putStrLn (encode evt)
  hFlush stdout

-- ---------------------------------------------------------------------------
-- LFSProcess record
-- ---------------------------------------------------------------------------

-- | State for a running LFS transfer session.
data LFSProcess = LFSProcess
  { lfsBucket  :: String
  , lfsPrefix  :: String
  , lfsProfile :: Maybe String
  , lfsS3Ops   :: LFSS3Ops   -- ^ injectable S3 operations
  }

-- | Minimal S3 operations required by the LFS agent.
data LFSS3Ops = LFSS3Ops
  { lfsS3ObjectExists   :: String         -- ^ key
                        -> IO Bool
  , lfsS3UploadFile     :: FilePath       -- ^ local path
                        -> String         -- ^ key
                        -> (Integer -> IO ())  -- ^ progress callback
                        -> IO ()
  , lfsS3DownloadFile   :: String         -- ^ key
                        -> FilePath       -- ^ destination
                        -> (Integer -> IO ())  -- ^ progress callback
                        -> IO ()
  }

-- | Build an 'LFSProcess' from a parsed S3 URI.
-- Returns @Nothing@ when the URI is invalid (writes an error JSON
-- event to stdout and returns @Nothing@).
newLFSProcess :: LFSS3Ops -> String -> IO (Maybe LFSProcess)
newLFSProcess ops s3uri =
  case parseGitUrl s3uri of
    Nothing -> do
      let evt = object
            [ "error" .= object
                [ "code"    .= (32 :: Int)
                , "message" .= ("s3 uri " ++ s3uri ++ " is invalid")
                ]
            ]
      BLC.putStrLn (encode evt)
      hFlush stdout
      return Nothing
    Just (ParseResult _ _ _ Nothing) -> do
      let evt = object
            [ "error" .= object
                [ "code"    .= (32 :: Int)
                , "message" .= ("s3 uri " ++ s3uri ++ " is missing prefix")
                ]
            ]
      BLC.putStrLn (encode evt)
      hFlush stdout
      return Nothing
    Just (ParseResult _ profile bucket (Just prefix)) -> do
      -- Signal ready to git-lfs
      BLC.putStrLn "{}"
      hFlush stdout
      return (Just LFSProcess
        { lfsBucket  = bucket
        , lfsPrefix  = prefix
        , lfsProfile = profile
        , lfsS3Ops   = ops
        })

-- ---------------------------------------------------------------------------
-- Upload
-- ---------------------------------------------------------------------------

lfsUpload :: LFSProcess -> Aeson.Object -> IO ()
lfsUpload lfs event = do
  let ops   = lfsS3Ops lfs
      oid   = lookupText "oid"  event
      path  = lookupText "path" event
      key   = lfsPrefix lfs ++ "/lfs/" ++ oid
  result <- try (do
    exists <- lfsS3ObjectExists ops key
    if exists
      then do
        let evt = object [ "event" .= ("complete" :: String), "oid" .= oid ]
        BLC.putStrLn (encode evt)
        hFlush stdout
      else do
        cb <- newProgressCallback oid
        lfsS3UploadFile ops path key (reportProgress cb)
        let evt = object [ "event" .= ("complete" :: String), "oid" .= oid ]
        BLC.putStrLn (encode evt)
        hFlush stdout
    ) :: IO (Either SomeException ())
  case result of
    Left e  -> writeErrorEvent oid (show e)
    Right _ -> return ()

-- ---------------------------------------------------------------------------
-- Download
-- ---------------------------------------------------------------------------

lfsDownload :: LFSProcess -> Aeson.Object -> IO ()
lfsDownload lfs event = do
  let ops     = lfsS3Ops lfs
      oid     = lookupText "oid" event
      key     = lfsPrefix lfs ++ "/lfs/" ++ oid
  tempDir <- makeAbsolute ".git/lfs/tmp"
  createDirectoryIfMissing True tempDir
  let destPath = tempDir ++ "/" ++ oid
  result <- try (do
    cb <- newProgressCallback oid
    lfsS3DownloadFile ops key destPath (reportProgress cb)
    let evt = object
          [ "event" .= ("complete" :: String)
          , "oid"   .= oid
          , "path"  .= destPath
          ]
    BLC.putStrLn (encode evt)
    hFlush stdout
    ) :: IO (Either SomeException ())
  case result of
    Left e  -> writeErrorEvent oid (show e)
    Right _ -> return ()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Look up a text field in an Aeson Object, returning "" on failure.
lookupText :: String -> Aeson.Object -> String
lookupText k obj =
  case KM.lookup (AKey.fromString k) obj of
    Just (String t) -> T.unpack t
    _               -> ""

-- ---------------------------------------------------------------------------
-- install
-- ---------------------------------------------------------------------------

lfsInstall :: IO ()
lfsInstall = do
  (code1, _, err1) <- readProcessWithExitCode "git"
    ["config", "--add", "lfs.customtransfer.git-lfs-s3.path", "git-lfs-s3"] ""
  case code1 of
    ExitFailure _ -> do
      hPutStrLn stderr err1
      hFlush stderr
      exitWith (ExitFailure 1)
    ExitSuccess -> return ()

  (code2, _, err2) <- readProcessWithExitCode "git"
    ["config", "--add", "lfs.standalonetransferagent", "git-lfs-s3"] ""
  case code2 of
    ExitFailure _ -> do
      hPutStrLn stderr err2
      hFlush stderr
      exitWith (ExitFailure 1)
    ExitSuccess -> return ()

  putStrLn "git-lfs-s3 installed"
  hFlush stdout

-- ---------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------

-- | The main event loop for the git-lfs-s3 custom transfer agent.
-- Takes an 'LFSS3Ops' so that tests can inject a fake.
lfsMain :: LFSS3Ops -> [String] -> IO ()
lfsMain ops args = do
  hSetBuffering stdin  LineBuffering
  hSetBuffering stdout LineBuffering

  case args of
    ["install"] -> do
      lfsInstall
      exitSuccess
    ["enable-debug"] -> do
      _ <- readProcessWithExitCode "git"
        ["config", "--add", "lfs.customtransfer.git-lfs-s3.args", "debug"] ""
      putStrLn "debug enabled"
      exitSuccess
    ["disable-debug"] -> do
      _ <- readProcessWithExitCode "git"
        ["config", "--unset", "lfs.customtransfer.git-lfs-s3.args"] ""
      putStrLn "debug disabled"
      exitSuccess
    [unknown] -> do
      putStrLn ("unknown command " ++ unknown)
      exitWith (ExitFailure 1)
    _ -> runLfsLoop ops Nothing

runLfsLoop :: LFSS3Ops -> Maybe LFSProcess -> IO ()
runLfsLoop ops mLfs = do
  line <- getLine
  case Aeson.decode (BLC.pack line) :: Maybe Aeson.Value of
    Nothing -> do
      hPutStrLn stderr ("failed to parse JSON: " ++ line)
      runLfsLoop ops mLfs
    Just (Aeson.Object obj) -> do
      let event = lookupText "event" obj
      case event of
        "init" -> do
          let remoteName = lookupText "remote" obj
          unless (validateRefName remoteName) $ do
            BLC.putStrLn "{}"
            hFlush stdout
            exitWith (ExitFailure 1)
          (code, out, errStr) <- readProcessWithExitCode "git"
            ["remote", "get-url", remoteName] ""
          case code of
            ExitFailure _ -> do
              let errEvt = object
                    [ "error" .= object
                        [ "code"    .= (2 :: Int)
                        , "message" .= ("cannot resolve remote \"" ++ remoteName ++ "\"")
                        ]
                    ]
              BLC.putStrLn (encode errEvt)
              hFlush stdout
              exitWith (ExitFailure 1)
            ExitSuccess -> do
              let s3uri = reverse . dropWhile (== '\n') . reverse $ out
              newLfs <- newLFSProcess ops s3uri
              runLfsLoop ops newLfs

        "upload" ->
          case mLfs of
            Nothing  -> runLfsLoop ops mLfs
            Just lfs -> do
              lfsUpload lfs obj
              runLfsLoop ops (Just lfs)

        "download" ->
          case mLfs of
            Nothing  -> runLfsLoop ops mLfs
            Just lfs -> do
              lfsDownload lfs obj
              runLfsLoop ops (Just lfs)

        _ -> runLfsLoop ops mLfs

    _ -> runLfsLoop ops mLfs
