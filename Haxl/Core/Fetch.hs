-- Copyright (c) 2014, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file. An additional grant of patent rights can
-- be found in the PATENTS file.

{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Generic fetching infrastructure, used by 'Haxl.Core.Monad'.
module Haxl.Core.Fetch
  ( performFetches
  ) where

import Haxl.Core.DataCache as DataCache
import Haxl.Core.Env
import Haxl.Core.Exception
import Haxl.Core.RequestStore
import Haxl.Core.Show1
import Haxl.Core.StateStore
import Haxl.Core.Types
import Haxl.Core.Util
import {-# SOURCE #-} Haxl.Core.Monad

import Control.Exception
import Control.Monad
import Data.IORef
import Data.List
import Data.Time
import Text.Printf
import Data.Monoid
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text
import Data.Hashable

-- | Issues a batch of fetches in a 'RequestStore'. After
-- 'performFetches', all the requests in the 'RequestStore' are
-- complete, and all of the 'ResultVar's are full.
performFetches :: forall u. Env u -> RequestStore u -> IO [IO ()]
performFetches env reqs = do
  let f = flags env
      sref = statsRef env
      jobs = contents reqs

  t0 <- getCurrentTime

  let
    roundstats =
      [ (dataSourceName (getReq reqs), length reqs)
      | BlockedFetches reqs <- jobs ]
      where
      getReq :: [BlockedFetch r] -> r a
      getReq = undefined

  modifyIORef' sref $ \(Stats rounds) ->
     Stats (RoundStats (HashMap.fromList roundstats) : rounds)

  ifTrace f 1 $
    printf "Batch data fetch (%s)\n" $
       intercalate (", "::String) $
           map (\(name,num) -> printf "%d %s" num (Text.unpack name)) roundstats

  ifTrace f 3 $
    forM_ jobs $ \(BlockedFetches reqs) ->
      forM_ reqs $ \(BlockedFetch r _) -> putStrLn (show1 r)

  let
    applyFetch (BlockedFetches (reqs :: [BlockedFetch r])) =
      case stateGet (states env) of
        Nothing ->
          return (SyncFetch (mapM_ (setError (const e)) reqs))
          where req :: r a; req = undefined
                e = DataSourceError $
                      "data source not initialized: " <> dataSourceName req
        Just state ->
          return $ wrapFetch reqs $ fetch state f (userEnv env) reqs

  fetches <- mapM applyFetch jobs

  waits <- scheduleFetches fetches

  ifTrace f 1 $ do
    t1 <- getCurrentTime
    printf "Batch data fetch done (%.2fs)\n"
      (realToFrac (diffUTCTime t1 t0) :: Double)

  return waits

-- Catch exceptions arising from the data source and stuff them into
-- the appropriate requests.  We don't want any exceptions propagating
-- directly from the data sources, because we want the exception to be
-- thrown by dataFetch instead.
--
wrapFetch :: [BlockedFetch req] -> PerformFetch -> PerformFetch
wrapFetch reqs fetch =
  case fetch of
    SyncFetch io -> SyncFetch (io `catch` handler)
    AsyncFetch fio -> AsyncFetch (\io -> fio io `catch` handler)
    FutureFetch io -> FutureFetch (io `catch` (\e -> handler e >> return (return ())))
    FullyAsyncFetch io -> FullyAsyncFetch (io `catch` handler)
  where
    handler :: SomeException -> IO ()
    handler e = mapM_ (forceError e) reqs

    -- Set the exception even if the request already had a result.
    -- Otherwise we could be discarding an exception.
    forceError e (BlockedFetch _ rvar) =
      putResult rvar (except e)

-- | Start all the async fetches first, then perform the sync fetches before
-- getting the results of the async fetches.
scheduleFetches :: [PerformFetch] -> IO [IO ()]
scheduleFetches fetches = do
  fully_async_fetches
  waits <- future_fetches
  async_fetches sync_fetches
  return waits
 where
  fully_async_fetches :: IO ()
  fully_async_fetches = sequence_ [f | FullyAsyncFetch f <- fetches]

  future_fetches :: IO [IO ()]
  future_fetches = sequence [f | FutureFetch f <- fetches]

  async_fetches :: IO () -> IO ()
  async_fetches = compose [f | AsyncFetch f <- fetches]

  sync_fetches :: IO ()
  sync_fetches = sequence_ [io | SyncFetch io <- fetches]


