-- Copyright (c) 2014-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file. An additional grant of patent rights can
-- be found in the PATENTS file.

{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
#if __GLASGOW_HASKELL >= 800
{-# OPTIONS_GHC -Wno-name-shadowing #-}
#else
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
#endif

-- | Base types used by all of Haxl. Most users should import
-- "Haxl.Core" instead of importing this module directly.
module Haxl.Core.Types (

  -- * Tracing flags
  Flags(..),
  defaultFlags,
  ifTrace,
  ifReport,
  ifProfiling,

  -- * Statistics
  Stats(..),
  FetchStats(..),
  Microseconds,
  emptyStats,
  numRounds,
  numFetches,
  ppStats,
  ppFetchStats,
  Profile,
  emptyProfile,
  profile,
  Round,
  profileRound,
  profileCache,
  ProfileLabel,
  ProfileData(..),
  emptyProfileData,
  AllocCount,
  MemoHitCount,

  -- * Data fetching
  DataSource(..),
  DataSourceName(..),
  Request,
  BlockedFetch(..),
  PerformFetch(..),
  SchedulerHint(..),

  -- * DataCache
  DataCache(..),
  SubCache(..),
  emptyDataCache,

  -- * Result variables
  ResultVar(..),
  mkResultVar,
  putFailure,
  putResult,
  putSuccess,

  -- * Default fetch implementations
  asyncFetch, asyncFetchWithDispatch,
  stubFetch,
  syncFetch,

  -- * Utilities
  except,
  setError,

  ) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif
import Control.Exception
import Control.Monad
import Data.Aeson
import Data.Functor.Constant
import Data.Int
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.List (intercalate)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable.Internal
import Text.Printf

#if __GLASGOW_HASKELL__ < 708
import Haxl.Core.Util (tryReadMVar)
#endif
import Haxl.Core.ShowP
import Haxl.Core.StateStore

-- ---------------------------------------------------------------------------
-- Flags

-- | Flags that control the operation of the engine.
data Flags = Flags
  { trace :: {-# UNPACK #-} !Int
    -- ^ Tracing level (0 = quiet, 3 = very verbose).
  , report :: {-# UNPACK #-} !Int
    -- ^ Report level:
    --    * 0 = quiet
    --    * 1 = quiet (legacy, this used to do something)
    --    * 2 = data fetch stats
    --    * 3 = # of errors
    --    * 4 = profiling
    --    * 5 = log stack traces of dataFetch calls
  , caching :: {-# UNPACK #-} !Int
    -- ^ Non-zero if caching is enabled.  If caching is disabled, then
    -- we still do batching and de-duplication within a round, but do
    -- not cache results between rounds.
  }

defaultFlags :: Flags
defaultFlags = Flags
  { trace = 0
  , report = 0
  , caching = 1
  }

#if __GLASGOW_HASKELL__ >= 710
#define FUNMONAD Monad m
#else
#define FUNMONAD (Functor m, Monad m)
#endif

-- | Runs an action if the tracing level is above the given threshold.
ifTrace :: FUNMONAD => Flags -> Int -> m a -> m ()
ifTrace flags i = when (trace flags >= i) . void

-- | Runs an action if the report level is above the given threshold.
ifReport :: FUNMONAD => Flags -> Int -> m a -> m ()
ifReport flags i = when (report flags >= i) . void

ifProfiling :: FUNMONAD => Flags -> m a -> m ()
ifProfiling flags = when (report flags >= 4) . void

#undef FUNMONAD

-- ---------------------------------------------------------------------------
-- Stats

type Microseconds = Int

-- | Stats that we collect along the way.
newtype Stats = Stats [FetchStats]
  deriving (Show, ToJSON)

-- | Pretty-print Stats.
ppStats :: Stats -> String
ppStats (Stats rss) =
  intercalate "\n"
     [ "Fetch: " ++ show i ++ " - " ++ ppFetchStats rs
     | (i, rs) <- zip [(1::Int)..] (filter isFetchStats (reverse rss)) ]
 where
  isFetchStats FetchStats{} = True
  isFetchStats _ = False

-- | Maps data source name to the number of requests made in that round.
-- The map only contains entries for sources that made requests in that
-- round.
data FetchStats
    -- | Timing stats for a (batched) data fetch
  = FetchStats
    { fetchDataSource :: Text
    , fetchBatchSize :: {-# UNPACK #-} !Int
    , fetchTime :: {-# UNPACK #-} !Microseconds
    , fetchSpace :: {-# UNPACK #-} !Int64
    , fetchFailures :: {-# UNPACK #-} !Int
    }

    -- | The stack trace of a call to 'dataFetch'.  These are collected
    -- only when profiling and reportLevel is 5 or greater.
  | FetchCall
    { fetchReq :: String
    , fetchStack :: [String]
    }
  deriving (Show)

-- | Pretty-print RoundStats.
ppFetchStats :: FetchStats -> String
ppFetchStats FetchStats{..} =
  printf "%s: %d fetches (%.2fus, %d bytes, %d failures)"
    (Text.unpack fetchDataSource) fetchBatchSize
    (fromIntegral fetchTime / 1000000 :: Double)  fetchSpace fetchFailures
ppFetchStats (FetchCall r ss) = show r ++ '\n':show ss

instance ToJSON FetchStats where
  toJSON FetchStats{..} = object
    [ "datasource" .= fetchDataSource
    , "fetches" .= fetchBatchSize
    , "time" .= fetchTime
    , "allocation" .= fetchSpace
    , "failures" .= fetchFailures
    ]
  toJSON (FetchCall req strs) = object
    [ "request" .= req
    , "stack" .= strs
    ]

emptyStats :: Stats
emptyStats = Stats []

numRounds :: Stats -> Int
numRounds (Stats rs) = length rs        -- not really

numFetches :: Stats -> Int
numFetches (Stats rs) = sum [ fetchBatchSize | FetchStats{..} <- rs ]


-- ---------------------------------------------------------------------------
-- Profiling

type ProfileLabel = Text
type AllocCount = Int64
type MemoHitCount = Int64

type Round = Int

data Profile = Profile
  { profileRound :: {-# UNPACK #-} !Round
     -- ^ Keep track of what the current fetch round is.
  , profile      :: HashMap ProfileLabel ProfileData
     -- ^ Data on individual labels.
  , profileCache :: DataCache (Constant Int)
     -- ^ Keep track of the round requests first appear in.
  }

emptyProfile :: Profile
emptyProfile = Profile 1 HashMap.empty emptyDataCache

data ProfileData = ProfileData
  { profileAllocs :: {-# UNPACK #-} !AllocCount
     -- ^ allocations made by this label
  , profileDeps :: HashSet ProfileLabel
     -- ^ labels that this label depends on
  , profileFetches :: Map Round (HashMap Text Int)
     -- ^ map from round to {datasource name => fetch count}
  , profileMemoHits :: {-# UNPACK #-} !MemoHitCount
    -- ^ number of hits to memoized computation at this label
  }
  deriving Show

emptyProfileData :: ProfileData
emptyProfileData = ProfileData 0 HashSet.empty Map.empty 0

-- ---------------------------------------------------------------------------
-- DataCache

-- | A @'DataCache' res@ maps things of type @req a@ to @res a@, for
-- any @req@ and @a@ provided @req a@ is an instance of 'Typeable'. In
-- practice @req a@ will be a request type parameterised by its result.
--
newtype DataCache res = DataCache (HashMap TypeRep (SubCache res))

-- | The implementation is a two-level map: the outer level maps the
-- types of requests to 'SubCache', which maps actual requests to their
-- results.  So each 'SubCache' contains requests of the same type.
-- This works well because we only have to store the dictionaries for
-- 'Hashable' and 'Eq' once per request type.
--
data SubCache res =
  forall req a . (Hashable (req a), Eq (req a), Typeable (req a)) =>
       SubCache (req a -> String) (a -> String) ! (HashMap (req a) (res a))
       -- NB. the inner HashMap is strict, to avoid building up
       -- a chain of thunks during repeated insertions.

-- | A new, empty 'DataCache'.
emptyDataCache :: DataCache res
emptyDataCache = DataCache HashMap.empty

-- ---------------------------------------------------------------------------
-- DataSource class

-- | The class of data sources, parameterised over the request type for
-- that data source. Every data source must implement this class.
--
-- A data source keeps track of its state by creating an instance of
-- 'StateKey' to map the request type to its state. In this case, the
-- type of the state should probably be a reference type of some kind,
-- such as 'IORef'.
--
-- For a complete example data source, see
-- <https://github.com/facebook/Haxl/tree/master/example Examples>.
--
class (DataSourceName req, StateKey req, ShowP req) => DataSource u req where

  -- | Issues a list of fetches to this 'DataSource'. The 'BlockedFetch'
  -- objects contain both the request and the 'ResultVar's into which to put
  -- the results.
  fetch
    :: State req
      -- ^ Current state.
    -> Flags
      -- ^ Tracing flags.
    -> u
      -- ^ User environment.
    -> [BlockedFetch req]
      -- ^ Requests to fetch.
    -> PerformFetch
      -- ^ Fetch the data; see 'PerformFetch'.

  schedulerHint :: u -> SchedulerHint req
  schedulerHint _ = TryToBatch

class DataSourceName req where
  -- | The name of this 'DataSource', used in tracing and stats. Must
  -- take a dummy request.
  dataSourceName :: req a -> Text

-- The 'ShowP' class is a workaround for the fact that we can't write
-- @'Show' (req a)@ as a superclass of 'DataSource', without also
-- parameterizing 'DataSource' over @a@, which is a pain (I tried
-- it). 'ShowP' seems fairly benign, though.

-- | A convenience only: package up 'Eq', 'Hashable', 'Typeable', and 'Show'
-- for requests into a single constraint.
type Request req a =
  ( Eq (req a)
  , Hashable (req a)
  , Typeable (req a)
  , Show (req a)
  , Show a
  )

-- | Hints to the scheduler about this data source
data SchedulerHint (req :: * -> *)
  = TryToBatch
    -- ^ Hold data-source requests while we execute as much as we can, so
    -- that we can hopefully collect more requests to batch.
  | SubmitImmediately
    -- ^ Submit a request via fetch as soon as we have one, don't try to
    -- batch multiple requests.  This is really only useful if the data source
    -- returns FullyAsyncFetch, otherwise requests to this data source will
    -- be performed synchronously, one at a time.

-- | A data source can fetch data in one of four ways.
--
data PerformFetch
  = SyncFetch  (IO ())
    -- ^ Fully synchronous, returns only when all the data is fetched.
    -- See 'syncFetch' for an example.
  | AsyncFetch (IO () -> IO ())
    -- ^ Asynchronous; performs an arbitrary IO action while the data
    -- is being fetched, but only returns when all the data is
    -- fetched.  See 'asyncFetch' for an example.
  | FullyAsyncFetch (IO ())
    -- ^ Fetches the data in the background, calling 'putResult' at
    -- any time in the future.  This is the best kind of fetch,
    -- because it provides the most concurrency.
  | FutureFetch (IO (IO ()))
    -- ^ Returns an IO action that, when performed, waits for the data
    -- to be received.  This is the second-best type of fetch, because
    -- the scheduler still has to perform the blocking wait at some
    -- point in the future, and when it has multiple blocking waits to
    -- perform, it can't know which one will return first.
    --
    -- Why not just forkIO the IO action to make a FutureFetch into a
    -- FullyAsyncFetch?  The blocking wait will probably do a safe FFI
    -- call, which means it needs its own OS thread.  If we don't want
    -- to create an arbitrary number of OS threads, then FutureFetch
    -- enables all the blocking waits to be done on a single thread.
    -- Also, you might have a data source that requires all calls to
    -- be made in the same OS thread.


-- | A 'BlockedFetch' is a pair of
--
--   * The request to fetch (with result type @a@)
--
--   * A 'ResultVar' to store either the result or an error
--
-- We often want to collect together multiple requests, but they return
-- different types, and the type system wouldn't let us put them
-- together in a list because all the elements of the list must have the
-- same type. So we wrap up these types inside the 'BlockedFetch' type,
-- so that they all look the same and we can put them in a list.
--
-- When we unpack the 'BlockedFetch' and get the request and the 'ResultVar'
-- out, the type system knows that the result type of the request
-- matches the type parameter of the 'ResultVar', so it will let us take the
-- result of the request and store it in the 'ResultVar'.
--
data BlockedFetch r = forall a. BlockedFetch (r a) (ResultVar a)


-- -----------------------------------------------------------------------------
-- ResultVar

-- | A sink for the result of a data fetch in 'BlockedFetch'
newtype ResultVar a = ResultVar (Either SomeException a -> IO ())

mkResultVar :: (Either SomeException a -> IO ()) -> ResultVar a
mkResultVar = ResultVar

putFailure :: (Exception e) => ResultVar a -> e -> IO ()
putFailure r = putResult r . except

putSuccess :: ResultVar a -> a -> IO ()
putSuccess r = putResult r . Right

putResult :: ResultVar a -> Either SomeException a -> IO ()
putResult (ResultVar io) res =  io res

-- | Function for easily setting a fetch to a particular exception
setError :: (Exception e) => (forall a. r a -> e) -> BlockedFetch r -> IO ()
setError e (BlockedFetch req m) = putFailure m (e req)

except :: (Exception e) => e -> Either SomeException a
except = Left . toException


-- -----------------------------------------------------------------------------
-- Fetch templates

stubFetch
  :: (Exception e) => (forall a. r a -> e)
  -> State r -> Flags -> u -> [BlockedFetch r] -> PerformFetch
stubFetch e _state _flags _si bfs = SyncFetch $ mapM_ (setError e) bfs

-- | Common implementation templates for 'fetch' of 'DataSource'.
--
-- Example usage:
--
-- > fetch = syncFetch MyDS.withService MyDS.retrieve
-- >   $ \service request -> case request of
-- >     This x -> MyDS.fetchThis service x
-- >     That y -> MyDS.fetchThat service y
--
asyncFetchWithDispatch
  :: ((service -> IO ()) -> IO ())
  -- ^ Wrapper to perform an action in the context of a service.

  -> (service -> IO ())
  -- ^ Dispatch all the pending requests

  -> (service -> IO ())
  -- ^ Wait for the results

  -> (forall a. service -> request a -> IO (IO (Either SomeException a)))
  -- ^ Enqueue an individual request to the service.

  -> State request
  -- ^ Currently unused.

  -> Flags
  -- ^ Currently unused.

  -> u
  -- ^ Currently unused.

  -> [BlockedFetch request]
  -- ^ Requests to submit.

  -> PerformFetch

asyncFetch, syncFetch
  :: ((service -> IO ()) -> IO ())
  -- ^ Wrapper to perform an action in the context of a service.

  -> (service -> IO ())
  -- ^ Dispatch all the pending requests and wait for the results

  -> (forall a. service -> request a -> IO (IO (Either SomeException a)))
  -- ^ Submits an individual request to the service.

  -> State request
  -- ^ Currently unused.

  -> Flags
  -- ^ Currently unused.

  -> u
  -- ^ Currently unused.

  -> [BlockedFetch request]
  -- ^ Requests to submit.

  -> PerformFetch

asyncFetchWithDispatch
  withService dispatch wait enqueue _state _flags _si requests =
  AsyncFetch $ \inner -> withService $ \service -> do
    getResults <- mapM (submitFetch service enqueue) requests
    dispatch service
    inner
    wait service
    sequence_ getResults

asyncFetch withService wait enqueue _state _flags _si requests =
  AsyncFetch $ \inner -> withService $ \service -> do
    getResults <- mapM (submitFetch service enqueue) requests
    inner
    wait service
    sequence_ getResults

syncFetch withService dispatch enqueue _state _flags _si requests =
  SyncFetch . withService $ \service -> do
  getResults <- mapM (submitFetch service enqueue) requests
  dispatch service
  sequence_ getResults

-- | Used by 'asyncFetch' and 'syncFetch' to retrieve the results of
-- requests to a service.
submitFetch
  :: service
  -> (forall a. service -> request a -> IO (IO (Either SomeException a)))
  -> BlockedFetch request
  -> IO (IO ())
submitFetch service fetch (BlockedFetch request result)
  = (putResult result =<<) <$> fetch service request
