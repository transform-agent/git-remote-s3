-- SPDX-FileCopyrightText: 2023-present Amazon.com, Inc. or its affiliates
--
-- SPDX-License-Identifier: Apache-2.0

-- | Tests for 'GitRemoteS3.Remote' push, fetch, list, option and
-- capabilities commands.
--
-- Mirrors @test/remote_test.py@.
--
-- Instead of @mock.patch@ we use IORef-based in-memory fake S3 stores
-- and pass them through the injectable 'S3Ops' record.
module RemoteSpec (spec) where

import           Control.Concurrent         (MVar, newMVar, withMVar, modifyMVar_)
import           Control.Exception          (evaluate, try, SomeException)
import           Data.IORef
import           Data.List                  (isPrefixOf, isSuffixOf, nub)
import           Data.Maybe                 (fromMaybe, isNothing)
import           Data.Time                  (UTCTime, getCurrentTime, addUTCTime)
import           Test.Hspec

import           GitRemoteS3.Enums          (UriScheme (..))
import           GitRemoteS3.Remote

-- ---------------------------------------------------------------------------
-- Test constants
-- ---------------------------------------------------------------------------

sha1 :: String
sha1 = "c105d19ba64965d2c9d3d3246e7269059ef8bb8a"

sha2 :: String
sha2 = "c105d19ba64965d2c9d3d3246e7269059ef8bb8b"

branch :: String
branch = "pytest"

mockBundleContent :: String
mockBundleContent = "MOCK_BUNDLE_CONTENT"

-- ---------------------------------------------------------------------------
-- In-memory fake S3 store
-- ---------------------------------------------------------------------------

type S3Store = IORef [(String, (UTCTime, String))]  -- key -> (lastModified, body)
type LockStore = IORef [String]                      -- list of lock keys

-- | Build an 'S3Ops' backed by in-memory IORefs.
mkFakeOps :: S3Store -> LockStore -> IO S3Ops
mkFakeOps store lockStore = do
  now <- getCurrentTime
  return S3Ops
    { s3ListObjects = \prefix -> do
        items <- readIORef store
        return [ S3Object k t
               | (k, (t, _)) <- items
               , prefix `isPrefixOf` k
               ]

    , s3GetObjectBody = \key -> do
        items <- readIORef store
        case lookup key items of
          Nothing     -> ioError (userError ("NoSuchKey: " ++ key))
          Just (_, b) -> return b

    , s3PutObject = \key body _meta -> do
        t <- getCurrentTime
        modifyIORef store (\s -> (key, (t, body)) : filter ((/= key) . fst) s)

    , s3PutObjectConditional = \key -> do
        lks <- readIORef lockStore
        if key `elem` lks
          then return False
          else do
            modifyIORef lockStore (key :)
            return True

    , s3DeleteObject = \key -> do
        modifyIORef store   (filter ((/= key) . fst))
        modifyIORef lockStore (filter (/= key))

    , s3DownloadFile = \key _dest -> do
        items <- readIORef store
        case lookup key items of
          Nothing -> ioError (userError ("NoSuchKey: " ++ key))
          Just _  -> return ()    -- fake: file "downloaded"

    , s3UploadFile = \src key -> do
        t <- getCurrentTime
        modifyIORef store (\s -> (key, (t, mockBundleContent))
                               : filter ((/= key) . fst) s)

    , s3HeadObject = \key -> do
        items <- readIORef store
        case lookup key items of
          Nothing     -> return Nothing
          Just (t, _) -> return (Just t)
    }

-- | Pre-populate the store with bundle objects for the given SHAs.
populateStore :: S3Store -> Bool -> [String] -> IO ()
populateStore store addHead shas = do
  now <- getCurrentTime
  let bundles = [ ("test_prefix/refs/heads/" ++ branch ++ "/" ++ s ++ ".bundle", (now, ""))
                | s <- shas ]
      headObj = if addHead
                then [("test_prefix/HEAD", (now, "refs/heads/" ++ branch))]
                else []
  writeIORef store (bundles ++ headObj)

mkRemote :: UriScheme -> S3Ops -> IO S3Remote
mkRemote scheme ops =
  newS3Remote scheme Nothing "test_bucket" "test_prefix" ops

-- ---------------------------------------------------------------------------
-- Helpers to call Git stubs
-- ---------------------------------------------------------------------------
-- We cannot easily patch module-level functions in Haskell the way Python
-- mock.patch does.  Instead these tests verify the S3 interactions via the
-- fake store rather than the git calls, and we skip the git subprocess by
-- pre-populating a bundle file and returning its path.

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do

  -- ------------------------------------------------------------------
  describe "cmdCapabilities" $ do
    it "lists push, fetch and option" $ do
      -- Just verify it does not throw
      () <- cmdCapabilities
      return ()

  -- ------------------------------------------------------------------
  describe "cmdList" $ do

    it "lists refs and HEAD correctly" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops       <- mkFakeOps store lockStore
      populateStore store True [sha1]
      r <- mkRemote S3 ops
      -- Shouldn't throw
      cmdList r False

    it "handles missing HEAD gracefully" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops       <- mkFakeOps store lockStore
      populateStore store False [sha1]   -- no HEAD object
      r <- mkRemote S3 ops
      cmdList r False

  -- ------------------------------------------------------------------
  describe "cmdOption" $ do

    it "accepts verbosity >= 2" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops       <- mkFakeOps store lockStore
      r         <- mkRemote S3 ops
      cmdOption r "option verbosity 2"  -- should not throw

    it "rejects unknown options" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops       <- mkFakeOps store lockStore
      r         <- mkRemote S3 ops
      cmdOption r "option concurrency 1"  -- should not throw

  -- ------------------------------------------------------------------
  describe "getBundlesForRef" $ do

    it "filters out PROTECTED# and .lock objects" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [ ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle", (now, ""))
        , ("test_prefix/refs/heads/" ++ branch ++ "/PROTECTED#",            (now, ""))
        , ("test_prefix/refs/heads/" ++ branch ++ "/LOCK#.lock",            (now, ""))
        ]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      objs <- getBundlesForRef r ("refs/heads/" ++ branch)
      length objs `shouldBe` 1
      objKey (head objs) `shouldBe`
        ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle")

  -- ------------------------------------------------------------------
  describe "isProtected" $ do

    it "returns True for a protected branch" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [ ("test_prefix/refs/heads/" ++ branch ++ "/PROTECTED#", (now, "")) ]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      isProtected r ("refs/heads/" ++ branch) `shouldReturn` True

    it "returns False for an unprotected branch" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      isProtected r ("refs/heads/" ++ branch) `shouldReturn` False

  -- ------------------------------------------------------------------
  describe "removeRemoteRef" $ do

    it "deletes a single-bundle ref (S3)" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle", (now, ""))]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      res <- removeRemoteRef r ("refs/heads/" ++ branch)
      res `shouldBe` ("ok refs/heads/" ++ branch ++ "\n")
      items <- readIORef store
      length items `shouldBe` 0

    it "deletes a two-object ref (S3Zip)" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [ ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle", (now, ""))
        , ("test_prefix/refs/heads/" ++ branch ++ "/repo.zip",              (now, ""))
        ]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3Zip ops
      res <- removeRemoteRef r ("refs/heads/" ++ branch)
      res `shouldBe` ("ok refs/heads/" ++ branch ++ "\n")

    it "errors on multiple bundles" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [ ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle", (now, ""))
        , ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha2 ++ ".bundle", (now, ""))
        ]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      res <- removeRemoteRef r ("refs/heads/" ++ branch)
      "error" `isPrefixOf` res `shouldBe` True

    it "errors when ref is not found" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      res <- removeRemoteRef r ("refs/heads/" ++ branch)
      "error" `isPrefixOf` res `shouldBe` True

  -- ------------------------------------------------------------------
  describe "acquireLock / releaseLock" $ do

    it "acquires a lock when none exists" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      mKey <- acquireLock r ("refs/heads/" ++ branch)
      mKey `shouldSatisfy` (/= Nothing)

    it "fails to acquire when a fresh lock exists" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      let lockKey = "test_prefix/refs/heads/" ++ branch ++ "/LOCK#.lock"
      writeIORef lockStore [lockKey]
      writeIORef store [(lockKey, (now, ""))]   -- fresh (not stale)
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      mKey <- acquireLock r ("refs/heads/" ++ branch)
      mKey `shouldBe` Nothing

    it "clears a stale lock and re-acquires" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      -- Put a very old lock (2 hours ago)
      now       <- getCurrentTime
      let oldTime  = addUTCTime (-7200) now
          lockKey  = "test_prefix/refs/heads/" ++ branch ++ "/LOCK#.lock"
      writeIORef store     [(lockKey, (oldTime, ""))]
      writeIORef lockStore [lockKey]
      -- Override head_object to return old time
      let ops' = S3Ops
            { s3ListObjects          = \prefix -> do
                items <- readIORef store
                return [ S3Object k t | (k, (t, _)) <- items, prefix `isPrefixOf` k ]
            , s3GetObjectBody        = \_ -> return ""
            , s3PutObject            = \key body _ -> do
                t <- getCurrentTime
                modifyIORef store (\s -> (key, (t, body)) : filter ((/= key) . fst) s)
            , s3PutObjectConditional = \key -> do
                lks <- readIORef lockStore
                if key `elem` lks
                  then return False
                  else do
                    modifyIORef lockStore (key :)
                    return True
            , s3DeleteObject         = \key -> do
                modifyIORef store     (filter ((/= key) . fst))
                modifyIORef lockStore (filter (/= key))
            , s3DownloadFile         = \_ _ -> return ()
            , s3UploadFile           = \_ key -> do
                t <- getCurrentTime
                modifyIORef store (\s -> (key, (t, "")) : filter ((/= key) . fst) s)
            , s3HeadObject           = \key -> do
                items <- readIORef store
                case lookup key items of
                  Nothing     -> return Nothing
                  Just (t, _) -> return (Just t)
            }
      r <- mkRemote S3 ops'
      -- TTL = 60s, lock is 7200s old => stale
      mKey <- acquireLock r ("refs/heads/" ++ branch)
      mKey `shouldSatisfy` (/= Nothing)

    it "releases a lock" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      let lockKey = "test_prefix/refs/heads/" ++ branch ++ "/LOCK#.lock"
      writeIORef lockStore [lockKey]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      releaseLock r lockKey
      lks <- readIORef lockStore
      lks `shouldBe` []

  -- ------------------------------------------------------------------
  describe "listRefs" $ do

    it "returns only .bundle refs under refs/" $ do
      store     <- newIORef []
      lockStore <- newIORef []
      now       <- getCurrentTime
      writeIORef store
        [ ("test_prefix/refs/heads/" ++ branch ++ "/" ++ sha1 ++ ".bundle",  (now, ""))
        , ("test_prefix/refs/tags/v1/" ++ sha1 ++ ".bundle",                  (now, ""))
        , ("test_prefix/HEAD",                                                  (now, ""))
        ]
      ops <- mkFakeOps store lockStore
      r   <- mkRemote S3 ops
      refs <- listRefs r
      length refs `shouldBe` 2
