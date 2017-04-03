-- Copyright (c) 2014-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file. An additional grant of patent rights can
-- be found in the PATENTS file.

{- TODO

- fetch stats for BackgroundFetch
- fetch failure stats
- do EVENTLOG stuff, track the data fetch numbers for performFetch

- write different scheduling policies
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}
#if __GLASGOW_HASKELL >= 800
{-# OPTIONS_GHC -Wno-name-shadowing #-}
#else
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
#endif

-- | The implementation of the 'Haxl' monad.  Most users should
-- import "Haxl.Core" instead of importing this module directly.
module Haxl.Core.Monad (
    -- * The monad
    GenHaxl (..), runHaxl,
    env, withEnv, withLabel, withFingerprintLabel,

    -- * IVar
    IVar(..), IVarContents(..), ResultVal(..),

    -- * Env
    Env(..), Caches, caches, initEnvWithData, initEnv, emptyEnv,

    -- * Exceptions
    throw, catch, catchIf, try, tryToHaxlException,

    -- * Data fetching and caching
    ShowReq, dataFetch, dataFetchWithShow, uncachedRequest, cacheRequest,
    cacheResult, cacheResultWithShow, cachedComputation,
    dumpCacheAsHaskell, dumpCacheAsHaskellFn,

    -- * Memoization Machinery
    newMemo, newMemoWith, prepareMemo, runMemo,

    newMemo1, newMemoWith1, prepareMemo1, runMemo1,
    newMemo2, newMemoWith2, prepareMemo2, runMemo2,

    -- * Unsafe operations
    unsafeLiftIO, unsafeToHaxlException,

    -- * Parallel operaitons
    pAnd, pOr
  ) where

import Haxl.Core.Types
import Haxl.Core.ShowP
import Haxl.Core.StateStore
import Haxl.Core.Exception
import Haxl.Core.RequestStore as RequestStore
import Haxl.Core.Util
import Haxl.Core.DataCache as DataCache

import Control.Arrow (left)
import Control.Concurrent.STM
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Control.Monad.Catch as Catch
import Control.Exception (Exception(..), SomeException, throwIO)
#if __GLASGOW_HASKELL__ >= 708
import Control.Exception (SomeAsyncException(..))
#endif
#if __GLASGOW_HASKELL__ >= 710
import Control.Exception (AllocationLimitExceeded(..))
import GHC.Conc (getAllocationCounter, setAllocationCounter)
#endif
import Control.Monad
import qualified Control.Exception as Exception
#if __GLASGOW_HASKELL__ < 710
import Control.Applicative hiding (Const)
#endif
import Control.DeepSeq
import GHC.Exts (IsString(..), Addr#)
#if __GLASGOW_HASKELL__ < 706
import Prelude hiding (catch)
#endif
import Data.Functor.Constant
import Data.Hashable
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import Data.IORef
import Data.List
import qualified Data.Map as Map
import Data.Monoid
import Data.Time
import Data.Typeable
import Text.PrettyPrint hiding ((<>))
import Text.Printf
#ifdef EVENTLOG
import Control.Exception (bracket_)
import Debug.Trace (traceEventIO)
#endif

#ifdef PROFILING
import GHC.Stack
#endif

import Unsafe.Coerce

#if __GLASGOW_HASKELL__ < 710
import Data.Int (Int64)

getAllocationCounter :: IO Int64
getAllocationCounter = return 0

setAllocationCounter :: Int64 -> IO ()
setAllocationCounter _ = return ()
#endif


trace_ :: String -> a -> a
trace_ _ = id
--trace_ = Debug.Trace.trace

-- -----------------------------------------------------------------------------
-- The environment

-- | The data we carry around in the Haxl monad.
data Env u = Env
  { cacheRef     :: {-# UNPACK #-} !(IORef (DataCache (IVar u)))
                    -- ^ cached data fetches
  , memoRef      :: {-# UNPACK #-} !(IORef (DataCache (IVar u)))
                    -- ^ memoized computations
  , flags        :: !Flags
                     -- conservatively not unpacking, because this is passed
                     -- to 'fetch' and would need to be rebuilt.
  , userEnv      :: u
  , statsRef     :: {-# UNPACK #-} !(IORef Stats)
  , profLabel    :: ProfileLabel
  , profRef      :: {-# UNPACK #-} !(IORef Profile)
  , states       :: StateStore
  -- ^ Data sources and other components can store their state in
  -- here. Items in this store must be instances of 'StateKey'.
  }

type Caches u = (IORef (DataCache (IVar u)), IORef (DataCache (IVar u)))

caches :: Env u -> Caches u
caches env = (cacheRef env, memoRef env)

-- | Initialize an environment with a 'StateStore', an input map, a
-- preexisting 'DataCache', and a seed for the random number generator.
initEnvWithData :: StateStore -> u -> Caches u -> IO (Env u)
initEnvWithData states e (cref, mref) = do
  sref <- newIORef emptyStats
  pref <- newIORef emptyProfile
  return Env
    { cacheRef = cref
    , memoRef = mref
    , flags = defaultFlags
    , userEnv = e
    , states = states
    , statsRef = sref
    , profLabel = "MAIN"
    , profRef = pref
    }

-- | Initializes an environment with 'StateStore' and an input map.
initEnv :: StateStore -> u -> IO (Env u)
initEnv states e = do
  cref <- newIORef emptyDataCache
  mref <- newIORef emptyDataCache
  initEnvWithData states e (cref,mref)

-- | A new, empty environment.
emptyEnv :: u -> IO (Env u)
emptyEnv = initEnv stateEmpty


-- -----------------------------------------------------------------------------
-- | The Haxl monad, which does several things:
--
--  * It is a reader monad for 'Env' and 'SchedState', The
--    latter is the current state of the scheduler, including
--    unfetched requests and the run queue of computations.
--
--  * It is a concurrency, or resumption, monad. A computation may run
--    partially and return 'Blocked', in which case the framework should
--    perform the outstanding requests in the 'RequestStore', and then
--    resume the computation.
--
--  * The Applicative combinator '<*>' explores /both/ branches in the
--    event that the left branch is 'Blocked', so that we can collect
--    multiple requests and submit them as a batch.
--
--  * It contains IO, so that we can perform real data fetching.
--
newtype GenHaxl u a = GenHaxl
  { unHaxl :: Env u -> SchedState u -> IO (Result u a) }

data SchedState u = SchedState
  { reqStoreRef :: {-# UNPACK #-} !(IORef (RequestStore u))
       -- ^ The set of requests that we have not submitted to data sources yet.
       -- Owned by the scheduler.
  , runQueueRef :: {-# UNPACK #-} !(IORef (JobList u))
       -- ^ runnable computations. Things get added to here when we wake up
       -- a computation that was waiting for something.  When the list is
       -- empty, either we're finished, or we're waiting for some data fetch
       -- to return.
  , completions :: {-# UNPACK #-} !(TVar [CompleteReq u])
       -- ^ Requests that have completed.  Modified by data sources
       -- (via putResult) and the scheduler.  Waiting for this list to
       -- become non-empty is how the scheduler blocks waiting for
       -- data fetches to return.
  , pendingWaits :: [IO ()]
       -- ^ this is a list of IO actions returned by 'FutureFetch'
       -- data sources.  These do a blocking wait for the results of
       -- some data fetch.
  }


-- -----------------------------------------------------------------------------
-- JobList

-- | A list of computations together with the IVar into which they
-- should put their result.
data JobList u
 = JobNil
 | forall a . JobCons (GenHaxl u a) {-# UNPACK #-} !(IVar u a) (JobList u)

appendJobList :: JobList u -> JobList u -> JobList u
appendJobList JobNil c = c
appendJobList c JobNil = c
appendJobList (JobCons a b c) d = JobCons a b (appendJobList c d)

lengthJobList :: JobList u -> Int
lengthJobList JobNil = 0
lengthJobList (JobCons _ _ j) = 1 + lengthJobList j


-- -----------------------------------------------------------------------------
-- IVar

-- | A synchronisation point.  It either contains a value, or a list
-- of computations waiting for the value.
newtype IVar u a = IVar (IORef (IVarContents u a))

data IVarContents u a
  = IVarFull (ResultVal a)
  | IVarEmpty (JobList u)
    -- morally this is a list of @a -> GenHaxl u ()@, but instead of
    -- using a function, each computation begins with `getIVar` to grab
    -- the value it is waiting for.  This is less type safe but a little
    -- faster (benchmarked with tests/MonadBench.hs).

newIVar :: IO (IVar u a)
newIVar = IVar <$> newIORef (IVarEmpty JobNil)

newFullIVar :: ResultVal a -> IO (IVar u a)
newFullIVar r = IVar <$> newIORef (IVarFull r)

getIVarApply :: IVar u (a -> b) -> a -> GenHaxl u b
getIVarApply (IVar !ref) a = GenHaxl $ \_env _sref -> do
  e <- readIORef ref
  case e of
    IVarFull (Ok f) -> return (Done (f a))
    IVarFull (ThrowHaxl e) -> return (Throw e)
    IVarFull (ThrowIO e) -> throwIO e
    IVarEmpty _ ->
      return (Blocked (IVar ref) (Cont (getIVarApply (IVar ref) a)))

getIVar :: IVar u a -> GenHaxl u a
getIVar (IVar !ref) = GenHaxl $ \_env _sref -> do
  e <- readIORef ref
  case e of
    IVarFull (Ok a) -> return (Done a)
    IVarFull (ThrowHaxl e) -> return (Throw e)
    IVarFull (ThrowIO e) -> throwIO e
    IVarEmpty _ -> return (Blocked (IVar ref) (Cont (getIVar (IVar ref))))

putIVar :: IVar u a -> ResultVal a -> SchedState u -> IO ()
putIVar (IVar ref) a SchedState{..} = do
  e <- readIORef ref
  case e of
    IVarEmpty jobs -> do
      writeIORef ref (IVarFull a)
      modifyIORef' runQueueRef (appendJobList jobs)
    IVarFull{} -> error "putIVar: multiple put"

{-# INLINE addJob #-}
addJob :: GenHaxl u b -> IVar u b -> IVar u a -> IO ()
addJob !haxl !resultIVar (IVar !ref) =
  modifyIORef' ref $ \contents ->
    case contents of
      IVarEmpty list -> IVarEmpty ((JobCons haxl) resultIVar list)
      _ -> addJobPanic

addJobPanic :: forall a . a
addJobPanic = error "addJob: not empty"

-- -----------------------------------------------------------------------------
-- ResultVal

data ResultVal a
  = Ok a
  | ThrowHaxl SomeException
  | ThrowIO SomeException

done :: ResultVal a -> IO (Result u a)
done (Ok a) = return (Done a)
done (ThrowHaxl e) = return (Throw e)
done (ThrowIO e) = throwIO e

eitherToResultThrowIO :: Either SomeException a -> ResultVal a
eitherToResultThrowIO (Right a) = Ok a
eitherToResultThrowIO (Left e)
  | Just HaxlException{} <- fromException e = ThrowHaxl e
  | otherwise = ThrowIO e

eitherToResult :: Either SomeException a -> ResultVal a
eitherToResult (Right a) = Ok a
eitherToResult (Left e) = ThrowHaxl e


-- -----------------------------------------------------------------------------
-- CompleteReq

-- | A completed request from a data source, containing the result,
-- and the 'IVar' representing the blocked computations.  The job of a
-- data source is just to add these to a queue (completions) using
-- putResult; the scheduler collects them from the queue and unblocks
-- the relevant computations.
data CompleteReq u =
  forall a . CompleteReq (Either SomeException a)
                         !(IVar u a)  -- IVar because the result is cached


-- -----------------------------------------------------------------------------
-- Result

-- | The result of a computation is either 'Done' with a value, 'Throw'
-- with an exception, or 'Blocked' on the result of a data fetch with
-- a continuation.
data Result u a
  = Done a
  | Throw SomeException
  | forall b . Blocked
      {-# UNPACK #-} !(IVar u b)      -- ^ What we are blocked on
      (Cont u a)
         -- ^ The continuation.  This might be wrapped further if
         -- we're nested inside multiple '>>=', before finally being
         -- added to the 'ContVar'.  Morally @b -> GenHaxl u a@, but see
         -- 'ContVar',

instance (Show a) => Show (Result u a) where
  show (Done a) = printf "Done(%s)" $ show a
  show (Throw e) = printf "Throw(%s)" $ show e
  show Blocked{} = "Blocked"

{- Note [Exception]

How do we want to represent Haxl exceptions (those that are thrown by
"throw" in the Haxl monad)?

1) Explicitly via a Throw constructor in the Result type
2) Using throwIO in the IO monad

If we did (2), we would have to use an exception handler in <*>,
because an exception in the right-hand argument of <*> should not
necessarily be thrown by the whole computation - an exception on the
left should get priority, and the left might currently be Blocked.

We must be careful about turning IO monad exceptions into Haxl
exceptions.  An IO monad exception will normally propagate right
out of runHaxl and terminate the whole computation, whereas a Haxl
exception can get dropped on the floor, if it is on the right of
<*> and the left side also throws, for example.  So turning an IO
monad exception into a Haxl exception is a dangerous thing to do.
In particular, we never want to do it for an asynchronous exception
(AllocationLimitExceeded, ThreadKilled, etc.), because these are
supposed to unconditionally terminate the computation.

There are three places where we take an arbitrary IO monad exception and
turn it into a Haxl exception:

 * wrapFetchInCatch.  Here we want to propagate a failure of the
   data source to the callers of the data source, but if the
   failure came from elsewhere (an asynchronous exception), then we
   should just propagate it

 * cacheResult (cache the results of IO operations): again,
   failures of the IO operation should be visible to the caller as
   a Haxl exception, but we exclude asynchronous exceptions from
   this.

 * unsafeToHaxlException: assume the caller knows what they're
   doing, and just wrap all exceptions.
-}


-- -----------------------------------------------------------------------------
-- Cont

data Cont u a
  = Cont (GenHaxl u a)
  | forall b. Cont u b :>>= (b -> GenHaxl u a)
  | forall b. (b -> a) :<$> (Cont u b)

toHaxl :: Cont u a -> GenHaxl u a
toHaxl (Cont haxl) = haxl
toHaxl (m :>>= k) = toHaxlBind m k
toHaxl (f :<$> x) = toHaxlFmap f x

toHaxlBind :: Cont u b -> (b -> GenHaxl u a) -> GenHaxl u a
toHaxlBind (m :>>= k) k2 = toHaxlBind m (k >=> k2)
toHaxlBind (Cont haxl) k = haxl >>= k
toHaxlBind (f :<$> x) k = toHaxlBind x (k . f)

toHaxlFmap :: (a -> b) -> Cont u a -> GenHaxl u b
toHaxlFmap f (m :>>= k) = toHaxlBind m (k >=> return . f)
toHaxlFmap f (Cont haxl) = f <$> haxl
toHaxlFmap f (g :<$> x) = toHaxlFmap (f . g) x

-- Note [Tree]
-- This implements the following re-association:
--
--           <*>
--          /   \
--       <$>     <$>
--      /   \   /   \
--     f     i g     j
--
-- to:
--
--           <*>
--          /   \
--       <$>     j
--      /   \         where h = (\x y -> f x (g y))
--     h     i
--
-- I suspect this is mostly useful because it eliminates one :<$> constructor
-- within the Blocked returned by `tree 1`, which is replicated a lot by the
-- tree benchmark (tree 1 is near the leaves). So this rule might just be
-- optimizing for a microbenchmark.


-- -----------------------------------------------------------------------------
-- Monad/Applicative instances

instance Monad (GenHaxl u) where
  return a = GenHaxl $ \_env _ref -> return (Done a)
  GenHaxl m >>= k = GenHaxl $ \env ref -> do
    e <- m env ref
    case e of
      Done a -> unHaxl (k a) env ref
      Throw e -> return (Throw e)
      Blocked ivar cont -> trace_ ">>= Blocked" $
        return (Blocked ivar (cont :>>= k))
  fail msg = GenHaxl $ \_env _ref ->
    return $ Throw $ toException $ MonadFail $ Text.pack msg

  -- We really want the Applicative version of >>
  (>>) = (*>)

instance Functor (GenHaxl u) where
  fmap f (GenHaxl m) = GenHaxl $ \env ref -> do
    r <- m env ref
    case r of
      Done a -> return (Done (f a))
      Throw e -> return (Throw e)
      Blocked ivar cont -> trace_ "fmap Blocked" $
        return (Blocked ivar (f :<$> cont))

instance Applicative (GenHaxl u) where
  pure = return
  GenHaxl ff <*> GenHaxl aa = GenHaxl $ \env st -> do
    rf <- ff env st
    case rf of
      Done f -> do
        ra <- aa env st
        case ra of
          Done a -> trace_ "Done/Done" $ return (Done (f a))
          Throw e -> trace_ "Done/Throe" $ return (Throw e)
          Blocked ivar fcont -> trace_ "Done/Blocked" $
            return (Blocked ivar (f :<$> fcont))
      Throw e -> trace_ "Throw" $ return (Throw e)
      Blocked ivar1 fcont -> do
         ra <- aa env st
         case ra of
           Done a -> trace_ "Blocked/Done" $
             return (Blocked ivar1 (($ a) :<$> fcont))
           Throw e -> trace_ "Blocked/Throw" $
             return (Blocked ivar1 (fcont :>>= (\_ -> throw e)))
           Blocked ivar2 acont -> trace_ "Blocked/Blocked" $ do
             -- Note [Blocked/Blocked]
              i <- newIVar
              addJob (toHaxl fcont) i ivar1
              let cont = acont :>>= \a -> getIVarApply i a
              return (Blocked ivar2 cont)

-- Note [Blocked/Blocked]
--
-- This is the tricky case: we're blocked on both sides of the <*>.
-- We need to divide the computation into two pieces that may continue
-- independently when the resources they are blocked on become
-- available.  Moreover, the computation as a whole depends on the two
-- pieces.  It works like this:
--
--   ff <*> aa
--
-- becomes
--
--   (ff >>= putIVar i) <*> (a <- aa; f <- getIVar i; return (f a)
--
-- where the IVar i is a new synchronisation point.  If the right side
-- gets to the `getIVar` first, it will block until the left side has
-- called 'putIVar'.
--
-- We can also do it the other way around:
--
--   (do ff <- f; getIVar i; return (ff a)) <*> (a >>= putIVar i)
--
-- The first was slightly faster according to tests/MonadBench.hs.


-- -----------------------------------------------------------------------------
-- runHaxl

{- TODO: later
data SchedPolicy
  = SubmitImmediately
  | WaitAtLeast Int{-ms-}
  | WaitForAllPendingRequests
-}

-- | Runs a 'Haxl' computation in the given 'Env'.
runHaxl :: forall u a. Env u -> GenHaxl u a -> IO a
runHaxl env@Env{flags=flags} haxl = do
  result@(IVar resultRef) <- newIVar -- where to put the final result
  rs <- newIORef noRequests          -- RequestStore
  rq <- newIORef JobNil
  comps <- newTVarIO []              -- completion queue
  let
    st = SchedState
           { reqStoreRef = rs
           , runQueueRef = rq
           , completions = comps
           , pendingWaits = [] }

    -- Run the next job on the JobList, and put its result in the given IVar
    schedule :: SchedState u -> JobList u -> GenHaxl u b -> IVar u b -> IO ()
    schedule st@SchedState{..} rq (GenHaxl run) (IVar !ref) = do
      ifTrace flags 3 $ printf "schedule: %d\n" (1 + lengthJobList rq)
      let {-# INLINE result #-}
          result r = do
            e <- readIORef ref
            case e of
              IVarFull _ -> error "multiple put"
              IVarEmpty haxls -> do
                writeIORef ref (IVarFull r)
                -- Have we got the final result now?
                if ref == unsafeCoerce resultRef
                        -- comparing IORefs of different types is safe, it's
                        -- pointer-equality on the MutVar#.
                   then return ()
                   else reschedule st (appendJobList haxls rq)
      r <- Exception.try $ run env st
      case r of
        Left e -> do
          rethrowAsyncExceptions e
          result (ThrowIO e)
        Right (Done a) -> result (Ok a)
        Right (Throw ex) -> result (ThrowHaxl ex)
        Right (Blocked ivar fn) -> do
          addJob (toHaxl fn) (IVar ref) ivar
          reschedule st rq
  
    -- Here we have a choice:
    --   - If the requestStore is non-empty, we could submit those
    --     requests right away without waiting for more.  This might
    --     be good for latency, especially if the data source doesn't
    --     support batching, or if batching is pessmial.
    --   - To optimise the batch sizes, we want to execute as much as
    --     we can and only submit requests when we have no more
    --     computation to do.
    --   - compromise: wait at least Nms for an outstanding result
    --     before giving up and submitting new requests.
    --
    -- For now we use the batching strategy in the scheduler, but
    -- individual data sources can request that their requests are
    -- sent eagerly by using schedulerHint.
    --
    reschedule :: SchedState u -> JobList u -> IO ()
    reschedule q@SchedState{..} haxls = do
      case haxls of
        JobNil -> do
          rq <- readIORef runQueueRef
          case rq of
            JobNil -> emptyRunQueue q
            JobCons a b c -> do
              writeIORef runQueueRef JobNil
              schedule q c a b
        JobCons a b c ->
          schedule q c a b
  
    emptyRunQueue :: SchedState u -> IO ()
    emptyRunQueue q@SchedState{..} = do
      ifTrace flags 3 $ printf "emptyRunQueue\n"
      haxls <- checkCompletions q
      case haxls of
        JobNil -> do
          case pendingWaits of
            [] -> checkRequestStore q
            wait:waits -> do
              ifTrace flags 3 $ printf "invoking wait\n"
              wait
              emptyRunQueue q { pendingWaits = waits } -- check completions
        _ -> reschedule q haxls
  
    checkRequestStore :: SchedState u -> IO ()
    checkRequestStore q@SchedState{..} = do
      reqStore <- readIORef reqStoreRef
      if RequestStore.isEmpty reqStore
        then waitCompletions q
        else do
          writeIORef reqStoreRef noRequests
          (_, waits) <- performRequestStore 0 env reqStore
          ifTrace flags 3 $ printf "performFetches: %d waits\n" (length waits)
          -- empty the cache if we're not caching.  Is this the best
          -- place to do it?  We do get to de-duplicate requests that
          -- happen simultaneously.
          when (caching flags == 0) $
            writeIORef (cacheRef env) emptyDataCache
          emptyRunQueue q{ pendingWaits = waits ++ pendingWaits }
  
    checkCompletions :: SchedState u -> IO (JobList u)
    checkCompletions SchedState{..} = do
      ifTrace flags 3 $ printf "checkCompletions\n"
      comps <- atomically $ do
        c <- readTVar completions
        writeTVar completions []
        return c
      case comps of
        [] -> return JobNil
        _ -> do
          ifTrace flags 3 $ printf "%d complete\n" (length comps)
          let getComplete (CompleteReq a (IVar cr)) = do
                r <- readIORef cr
                case r of
                  IVarFull _ -> do
                    ifTrace flags 3 $ printf "existing result\n"
                    return JobNil
                    -- this happens if a data source reports a result,
                    -- and then throws an exception.  We call putResult
                    -- a second time for the exception, which comes
                    -- ahead of the original request (because it is
                    -- pushed on the front of the completions list) and
                    -- therefore overrides it.
                  IVarEmpty cv -> do
                    writeIORef cr (IVarFull (eitherToResult a))
                    return cv
          jobs <- mapM getComplete comps
          return (foldr appendJobList JobNil jobs)
  
    waitCompletions :: SchedState u -> IO ()
    waitCompletions q@SchedState{..} = do
      ifTrace flags 3 $ printf "waitCompletions\n"
      atomically $ do
        c <- readTVar completions
        when (null c) retry
      emptyRunQueue q

  --
  schedule st JobNil haxl result
  r <- readIORef resultRef
  case r of
    IVarEmpty _ -> throwIO (CriticalError "runHaxl: missing result")
    IVarFull (Ok a)  -> return a
    IVarFull (ThrowHaxl e)  -> throwIO e
    IVarFull (ThrowIO e)  -> throwIO e


-- -----------------------------------------------------------------------------
-- Env utils

-- | Extracts data from the 'Env'.
env :: (Env u -> a) -> GenHaxl u a
env f = GenHaxl $ \env _ref -> return (Done (f env))

-- | Returns a version of the Haxl computation which always uses the
-- provided 'Env', ignoring the one specified by 'runHaxl'.
withEnv :: Env u -> GenHaxl u a -> GenHaxl u a
withEnv newEnv (GenHaxl m) = GenHaxl $ \_env ref -> do
  r <- m newEnv ref
  case r of
    Done a -> return (Done a)
    Throw e -> return (Throw e)
    Blocked ivar k ->
      return (Blocked ivar (Cont (withEnv newEnv (toHaxl k))))


-- -----------------------------------------------------------------------------
-- Profiling

-- | Label a computation so profiling data is attributed to the label.
withLabel :: ProfileLabel -> GenHaxl u a -> GenHaxl u a
withLabel l (GenHaxl m) = GenHaxl $ \env st ->
  if report (flags env) < 4
     then m env st
     else collectProfileData l m env st

-- | Label a computation so profiling data is attributed to the label.
-- Intended only for internal use by 'memoFingerprint'.
withFingerprintLabel :: Addr# -> Addr# -> GenHaxl u a -> GenHaxl u a
withFingerprintLabel mnPtr nPtr (GenHaxl m) = GenHaxl $ \env ref ->
  if report (flags env) < 4
     then m env ref
     else collectProfileData
            (Text.unpackCString# mnPtr <> "." <> Text.unpackCString# nPtr)
            m env ref

-- | Collect profiling data and attribute it to given label.
collectProfileData
  :: ProfileLabel
  -> (Env u -> SchedState u -> IO (Result u a))
  -> Env u -> SchedState u
  -> IO (Result u a)
collectProfileData l m env st = do
   a0 <- getAllocationCounter
   r <- m env{profLabel=l} st -- what if it throws?
   a1 <- getAllocationCounter
   modifyProfileData env l (a0 - a1)
   -- So we do not count the allocation overhead of modifyProfileData
   setAllocationCounter a1
   case r of
     Done a -> return (Done a)
     Throw e -> return (Throw e)
     Blocked ivar k -> return (Blocked ivar (Cont (withLabel l (toHaxl k))))
{-# INLINE collectProfileData #-}

modifyProfileData :: Env u -> ProfileLabel -> AllocCount -> IO ()
modifyProfileData env label allocs =
  modifyIORef' (profRef env) $ \ p ->
    p { profile =
          HashMap.insertWith updEntry label newEntry .
          HashMap.insertWith updCaller caller newCaller $
          profile p }
  where caller = profLabel env
        newEntry =
          emptyProfileData
            { profileAllocs = allocs
            , profileDeps = HashSet.singleton caller }
        updEntry _ old =
          old { profileAllocs = profileAllocs old + allocs
              , profileDeps = HashSet.insert caller (profileDeps old) }
        -- subtract allocs from caller, so they are not double counted
        -- we don't know the caller's caller, but it will get set on
        -- the way back out, so an empty hashset is fine for now
        newCaller =
          emptyProfileData { profileAllocs = -allocs }
        updCaller _ old =
          old { profileAllocs = profileAllocs old - allocs }

incrementMemoHitCounterFor :: ProfileLabel -> Profile -> Profile
incrementMemoHitCounterFor lbl p =
  p { profile = HashMap.adjust incrementMemoHitCounter lbl (profile p) }

incrementMemoHitCounter :: ProfileData -> ProfileData
incrementMemoHitCounter pd = pd { profileMemoHits = succ (profileMemoHits pd) }


-- -----------------------------------------------------------------------------
-- Exceptions

-- | Throw an exception in the Haxl monad
throw :: (Exception e) => e -> GenHaxl u a
throw e = GenHaxl $ \_env _ref -> raise e

raise :: (Exception e) => e -> IO (Result u a)
raise e
#ifdef PROFILING
  | Just (HaxlException Nothing h) <- fromException somex = do
    stk <- currentCallStack
    return (Throw (toException (HaxlException (Just stk) h)))
  | otherwise
#endif
    = return (Throw somex)
  where
    somex = toException e

-- | Catch an exception in the Haxl monad
catch :: Exception e => GenHaxl u a -> (e -> GenHaxl u a) -> GenHaxl u a
catch (GenHaxl m) h = GenHaxl $ \env ref -> do
   r <- m env ref
   case r of
     Done a    -> return (Done a)
     Throw e | Just e' <- fromException e -> unHaxl (h e') env ref
             | otherwise -> return (Throw e)
     Blocked ivar k -> return (Blocked ivar (Cont (catch (toHaxl k) h)))

-- | Catch exceptions that satisfy a predicate
catchIf
  :: Exception e => (e -> Bool) -> GenHaxl u a -> (e -> GenHaxl u a)
  -> GenHaxl u a
catchIf cond haxl handler =
  catch haxl $ \e -> if cond e then handler e else throw e

-- | Returns @'Left' e@ if the computation throws an exception @e@, or
-- @'Right' a@ if it returns a result @a@.
try :: Exception e => GenHaxl u a -> GenHaxl u (Either e a)
try haxl = (Right <$> haxl) `catch` (return . Left)

-- | @since 0.3.1.0
instance Catch.MonadThrow (GenHaxl u) where throwM = Haxl.Core.Monad.throw
-- | @since 0.3.1.0
instance Catch.MonadCatch (GenHaxl u) where catch = Haxl.Core.Monad.catch


-- -----------------------------------------------------------------------------
-- Unsafe operations

-- | Under ordinary circumstances this is unnecessary; users of the Haxl
-- monad should generally /not/ perform arbitrary IO.
unsafeLiftIO :: IO a -> GenHaxl u a
unsafeLiftIO m = GenHaxl $ \_env _ref -> Done <$> m

-- | Convert exceptions in the underlying IO monad to exceptions in
-- the Haxl monad.  This is morally unsafe, because you could then
-- catch those exceptions in Haxl and observe the underlying execution
-- order.  Not to be exposed to user code.
unsafeToHaxlException :: GenHaxl u a -> GenHaxl u a
unsafeToHaxlException (GenHaxl m) = GenHaxl $ \env ref -> do
  r <- m env ref `Exception.catch` \e -> return (Throw e)
  case r of
    Blocked cvar c ->
      return (Blocked cvar (Cont (unsafeToHaxlException (toHaxl c))))
    other -> return other

-- | Like 'try', but lifts all exceptions into the 'HaxlException'
-- hierarchy.  Uses 'unsafeToHaxlException' internally.  Typically
-- this is used at the top level of a Haxl computation, to ensure that
-- all exceptions are caught.
tryToHaxlException :: GenHaxl u a -> GenHaxl u (Either HaxlException a)
tryToHaxlException h = left asHaxlException <$> try (unsafeToHaxlException h)


-- -----------------------------------------------------------------------------
-- Data fetching and caching

-- | Possible responses when checking the cache.
data CacheResult u a
  -- | The request hadn't been seen until now.
  = Uncached
       (ResultVar a)
       {-# UNPACK #-} !(IVar u a)

  -- | The request has been seen before, but its result has not yet been
  -- fetched.
  | CachedNotFetched
      {-# UNPACK #-} !(IVar u a)

  -- | The request has been seen before, and its result has already been
  -- fetched.
  | Cached (ResultVal a)


-- | Show functions for request and its result.
type ShowReq r a = (r a -> String, a -> String)

-- Note [showFn]
--
-- Occasionally, for tracing purposes or generating exceptions, we need to
-- call 'show' on the request in a place where we *cannot* have a Show
-- dictionary. (Because the function is a worker which is called by one of
-- the *WithShow variants that take explicit show functions via a ShowReq
-- argument.) None of the functions that does this is exported, so this is
-- hidden from the Haxl user.

cachedWithInsert
  :: Typeable (r a)
  => (r a -> String)    -- See Note [showFn]
  -> (r a -> IVar u a -> DataCache (IVar u) -> DataCache (IVar u))
  -> Env u -> SchedState u -> r a -> IO (CacheResult u a)
cachedWithInsert showFn insertFn env SchedState{..} req = do
  let !ref = cacheRef env
  cache <- readIORef ref
  let
    doFetch = do
      ivar <- newIVar
      let done r = atomically $ do
            cs <- readTVar completions
            writeTVar completions (CompleteReq r ivar : cs)
      writeIORef (cacheRef env) $! insertFn req ivar cache
      return (Uncached (mkResultVar done) ivar)
  case DataCache.lookup req cache of
    Nothing -> doFetch
    Just (IVar cr) -> do
      e <- readIORef cr
      case e of
        IVarEmpty _ -> return (CachedNotFetched (IVar cr))
        IVarFull r -> do
          ifTrace (flags env) 3 $ putStrLn $ case r of
            ThrowIO _ -> "Cached error: " ++ showFn req
            ThrowHaxl _ -> "Cached error: " ++ showFn req
            Ok _ -> "Cached request: " ++ showFn req
          return (Cached r)

-- | Record the call stack for a data fetch in the Stats.  Only useful
-- when profiling.
logFetch :: Env u -> (r a -> String) -> r a -> IO ()
#ifdef PROFILING
logFetch env showFn req = do
  ifReport (flags env) 5 $ do
    stack <- currentCallStack
    modifyIORef' (statsRef env) $ \(Stats s) ->
      Stats (FetchCall (showFn req) stack : s)
#else
logFetch _ _ _ = return ()
#endif

-- | Performs actual fetching of data for a 'Request' from a 'DataSource'.
dataFetch :: (DataSource u r, Request r a) => r a -> GenHaxl u a
dataFetch = dataFetchWithInsert show DataCache.insert

-- | Performs actual fetching of data for a 'Request' from a 'DataSource', using
-- the given show functions for requests and their results.
dataFetchWithShow
  :: (DataSource u r, Eq (r a), Hashable (r a), Typeable (r a))
  => ShowReq r a
  -> r a -> GenHaxl u a
dataFetchWithShow (showReq, showRes) = dataFetchWithInsert showReq
  (DataCache.insertWithShow showReq showRes)

-- | Performs actual fetching of data for a 'Request' from a 'DataSource', using
-- the given function to insert requests in the cache.
dataFetchWithInsert
  :: forall u r a
   . (DataSource u r, Eq (r a), Hashable (r a), Typeable (r a))
  => (r a -> String)    -- See Note [showFn]
  -> (r a -> IVar u a -> DataCache (IVar u) -> DataCache (IVar u))
  -> r a
  -> GenHaxl u a
dataFetchWithInsert showFn insertFn req =
  GenHaxl $ \env@Env{..} st@SchedState{..} -> do
  -- First, check the cache
  res <- cachedWithInsert showFn insertFn env st req
  ifProfiling flags $ addProfileFetch env req
  case res of
    -- This request has not been seen before
    Uncached rvar ivar -> do
      logFetch env showFn req
      --
      -- Check whether the data source wants to submit requests
      -- eagerly, or batch them up.
      --
      case schedulerHint userEnv :: SchedulerHint r of
        SubmitImmediately -> do
          (_,ios) <- performFetches 0 env
            [BlockedFetches [BlockedFetch req rvar]]
          when (not (null ios)) $
            error "bad data source:SubmitImmediately but returns FutureFetch"
        TryToBatch ->
          -- add the request to the RequestStore and continue
          modifyIORef' reqStoreRef $ \bs ->
            addRequest (BlockedFetch req rvar) bs
      --
      return $ Blocked ivar (Cont (getIVar ivar))

    -- Seen before but not fetched yet.  We're blocked, but we don't have
    -- to add the request to the RequestStore.
    CachedNotFetched ivar -> return $ Blocked ivar (Cont (getIVar ivar))

    -- Cached: either a result, or an exception
    Cached r -> done r

{-# NOINLINE addProfileFetch #-}
addProfileFetch
  :: (DataSourceName r, Eq (r a), Hashable (r a), Typeable (r a))
  => Env u -> r a -> IO ()
addProfileFetch env req = do
  c <- getAllocationCounter
  modifyIORef' (profRef env) $ \ p ->
    let
      dsName :: Text.Text
      dsName = dataSourceName req

      upd :: Round -> ProfileData -> ProfileData
      upd round d =
        d { profileFetches = Map.alter (Just . f) round (profileFetches d) }

      f Nothing   = HashMap.singleton dsName 1
      f (Just hm) = HashMap.insertWith (+) dsName 1 hm
    in case DataCache.lookup req (profileCache p) of
        Nothing ->
          let r = profileRound p
          in p { profile = HashMap.adjust (upd r) (profLabel env) (profile p)
               , profileCache =
                  DataCache.insertNotShowable req (Constant r) (profileCache p)
               }
        Just (Constant r) ->
          p { profile = HashMap.adjust (upd r) (profLabel env) (profile p) }
  -- So we do not count the allocation overhead of addProfileFetch
  setAllocationCounter c


-- | A data request that is not cached.  This is not what you want for
-- normal read requests, because then multiple identical requests may
-- return different results, and this invalidates some of the
-- properties that we expect Haxl computations to respect: that data
-- fetches can be aribtrarily reordered, and identical requests can be
-- commoned up, for example.
--
-- 'uncachedRequest' is useful for performing writes, provided those
-- are done in a safe way - that is, not mixed with reads that might
-- conflict in the same Haxl computation.
--
uncachedRequest :: (DataSource u r, Show (r a)) => r a -> GenHaxl u a
uncachedRequest req = GenHaxl $ \_env SchedState{..} -> do
  cr <- IVar <$> newIORef (IVarEmpty JobNil)
  let done r = atomically $ do
        cs <- readTVar completions
        writeTVar completions (CompleteReq r cr : cs)
  modifyIORef' reqStoreRef $ \bs ->
    addRequest (BlockedFetch req (mkResultVar done)) bs
  return $ Blocked cr (Cont (getIVar cr))


-- | Transparently provides caching. Useful for datasources that can
-- return immediately, but also caches values.  Exceptions thrown by
-- the IO operation (except for asynchronous exceptions) are
-- propagated into the Haxl monad and can be caught by 'catch' and
-- 'try'.
cacheResult :: Request r a => r a -> IO a -> GenHaxl u a
cacheResult = cacheResultWithInsert show DataCache.insert

-- | Transparently provides caching in the same way as 'cacheResult', but uses
-- the given functions to show requests and their results.
cacheResultWithShow
  :: (Eq (r a), Hashable (r a), Typeable (r a))
  => ShowReq r a -> r a -> IO a -> GenHaxl u a
cacheResultWithShow (showReq, showRes) = cacheResultWithInsert showReq
  (DataCache.insertWithShow showReq showRes)

-- Transparently provides caching, using the given function to insert requests
-- into the cache.
cacheResultWithInsert
  :: Typeable (r a)
  => (r a -> String)    -- See Note [showFn]
  -> (r a -> IVar u a -> DataCache (IVar u) -> DataCache (IVar u)) -> r a
  -> IO a -> GenHaxl u a
cacheResultWithInsert showFn insertFn req val = GenHaxl $ \env st -> do
  cachedResult <- cachedWithInsert showFn insertFn env st req
  case cachedResult of
    Uncached rvar _ivar -> do
      result <- Exception.try val
      case result of
        Left e -> rethrowAsyncExceptions e
        _ -> return ()
      putResult rvar result
      -- important to re-throw IO exceptions here
      done (eitherToResultThrowIO result)
    Cached result -> done result
    CachedNotFetched _ -> corruptCache
  where
    corruptCache = raise . DataSourceError $ Text.concat
      [ Text.pack (showFn req)
      , " has a corrupted cache value: these requests are meant to"
      , " return immediately without an intermediate value. Either"
      , " the cache was updated incorrectly, or you're calling"
      , " cacheResult on a query that involves a blocking fetch."
      ]


rethrowAsyncExceptions :: SomeException -> IO ()
rethrowAsyncExceptions e
#if __GLASGOW_HASKELL__ >= 708
  | Just SomeAsyncException{} <- fromException e = Exception.throw e
#endif
#if __GLASGOW_HASKELL__ >= 710
  | Just AllocationLimitExceeded{} <- fromException e = Exception.throw e
    -- AllocationLimitExceeded is not a child of SomeAsyncException,
    -- but it should be.
#endif
  | otherwise = return ()

-- | Inserts a request/result pair into the cache. Throws an exception
-- if the request has already been issued, either via 'dataFetch' or
-- 'cacheRequest'.
--
-- This can be used to pre-populate the cache when running tests, to
-- avoid going to the actual data source and ensure that results are
-- deterministic.
--
cacheRequest
  :: Request req a => req a -> Either SomeException a -> GenHaxl u ()
cacheRequest request result = GenHaxl $ \env _st -> do
  cache <- readIORef (cacheRef env)
  case DataCache.lookup request cache of
    Nothing -> do
      cr <- newFullIVar (eitherToResult result)
      writeIORef (cacheRef env) $! DataCache.insert request cr cache
      return (Done ())

    -- It is an error if the request is already in the cache.  We can't test
    -- whether the cached result is the same without adding an Eq constraint,
    -- and we don't necessarily have Eq for all results.
    _other -> raise $
      DataSourceError "cacheRequest: request is already in the cache"

instance IsString a => IsString (GenHaxl u a) where
  fromString s = return (fromString s)

performRequestStore
   :: forall u. Int -> Env u -> RequestStore u -> IO (Int, [IO ()])
performRequestStore n env reqStore =
  performFetches n env (contents reqStore)

-- | Issues a batch of fetches in a 'RequestStore'. After
-- 'performFetches', all the requests in the 'RequestStore' are
-- complete, and all of the 'ResultVar's are full.
performFetches
  :: forall u. Int -> Env u -> [BlockedFetches u] -> IO (Int, [IO ()])
performFetches n env@Env{flags=f, statsRef=sref} jobs = do
  let !n' = n + length jobs

  t0 <- getCurrentTime

  let
    roundstats =
      [ (dataSourceName (getReq reqs), length reqs)
      | BlockedFetches reqs <- jobs ]
      where
      getReq :: [BlockedFetch r] -> r a
      getReq = undefined

  ifTrace f 1 $
    printf "Batch data fetch (%s)\n" $
      intercalate (", "::String) $
        map (\(name,num) -> printf "%d %s" num (Text.unpack name)) roundstats

  ifTrace f 3 $
    forM_ jobs $ \(BlockedFetches reqs) ->
      forM_ reqs $ \(BlockedFetch r _) -> putStrLn (showp r)

  let
    applyFetch i (BlockedFetches (reqs :: [BlockedFetch r])) =
      case stateGet (states env) of
        Nothing ->
          return (FetchToDo reqs (SyncFetch (mapM_ (setError (const e)))))
         where
           e = DataSourceError $ "data source not initialized: " <> dsName
                  ": " <>
                  Text.pack (showp req)
        Just state ->
          return
            $ FetchToDo reqs
            $ (if report f >= 2
                then wrapFetchInStats sref dsName (length reqs)
                else id)
            $ wrapFetchInTrace i (length reqs)
               (dataSourceName (undefined :: r a))
            $ wrapFetchInCatch reqs
            $ fetch state f (userEnv env))


      where
        req :: r a; req = undefined; dsName = dataSourceName req

  fetches <- zipWithM applyFetch [n..] jobs

  waits <- scheduleFetches fetches

{- TODO
  failures <-
    if report f >= 3
    then
      forM jobs $ \(BlockedFetches reqs) ->
        fmap (Just . length) . flip filterM reqs $ \(BlockedFetch _ rvar) -> do
          mb <- readIORef rvar
          return $ case mb of
            Just (Right _) -> False
            _ -> True
    else return $ repeat Nothing
-}

  t1 <- getCurrentTime
  let roundtime = realToFrac (diffUTCTime t1 t0) :: Double

  ifTrace f 1 $
    printf "Batch data fetch done (%.2fs)\n" (realToFrac roundtime :: Double)

  ifProfiling f $
    modifyIORef' (profRef env) $ \ p -> p { profileRound = 1 + profileRound p }

  return (n', waits)

data FetchToDo where
  FetchToDo :: [BlockedFetch req] -> PerformFetch req -> FetchToDo

-- Catch exceptions arising from the data source and stuff them into
-- the appropriate requests.  We don't want any exceptions propagating
-- directly from the data sources, because we want the exception to be
-- thrown by dataFetch instead.
--
wrapFetchInCatch :: [BlockedFetch req] -> PerformFetch req -> PerformFetch req
wrapFetchInCatch reqs fetch =
  case fetch of
    SyncFetch f ->
      SyncFetch $ \reqs -> f reqs `Exception.catch` handler
    AsyncFetch f ->
      AsyncFetch $ \reqs io -> f reqs io `Exception.catch` handler
    FutureFetch f ->
      FutureFetch $ \reqs -> f reqs `Exception.catch` (
                     \e -> handler e >> return (return ()))
    BackgroundFetch f ->
      BackgroundFetch $ \reqs -> f reqs `Exception.catch` handler
  where
    handler :: SomeException -> IO ()
    handler e = do
      rethrowAsyncExceptions e
      mapM_ (forceError e) reqs

    -- Set the exception even if the request already had a result.
    -- Otherwise we could be discarding an exception.
    forceError e (BlockedFetch _ rvar) =
      putResult rvar (except e)


wrapFetchInStats
  :: IORef Stats
  -> Text
  -> Int
  -> PerformFetch req
  -> PerformFetch req

wrapFetchInStats !statsRef dataSource batchSize perform = do
  case perform of
    SyncFetch f ->
      SyncFetch $ \reqs -> do
        (t,alloc,_) <- statsForIO (f reqs)
        updateFetchStats t alloc
    AsyncFetch f -> do
      AsyncFetch $ \reqs inner -> do
         inner_r <- newIORef (0, 0)
         let inner' = do
               (t,alloc,_) <- statsForIO inner
               writeIORef inner_r (t,alloc)
         (totalTime, totalAlloc, _) <- statsForIO (f reqs inner')
         (innerTime, innerAlloc) <- readIORef inner_r
         updateFetchStats (totalTime - innerTime) (totalAlloc - innerAlloc)
    FutureFetch submit ->
      FutureFetch $ \reqs -> do
         (submitTime, submitAlloc, wait) <- statsForIO (submit reqs)
         return $ do
           (waitTime, waitAlloc, _) <- statsForIO wait
           updateFetchStats (submitTime + waitTime) (submitAlloc + waitAlloc)
    BackgroundFetch io -> do
      BackgroundFetch $ \reqs -> do
        startTimeRef <- newIORef =<< getCurrentTime
        io (map (addTimer startTimeRef) reqs)
  where
    statsForIO io = do
      prevAlloc <- getAllocationCounter
      (t,a) <- time io
      postAlloc <- getAllocationCounter
      return (t, fromIntegral $ prevAlloc - postAlloc, a)

    addTimer startTimeRef (BlockedFetch req (ResultVar fn)) =
      BlockedFetch req $ ResultVar $ \result -> do
        t0 <- readIORef startTimeRef
        t1 <- getCurrentTime
        updateFetchStats (microsecs (realToFrac (t1 `diffUTCTime` t0))) 0
        fn result

    updateFetchStats :: Microseconds -> Int64 -> IO ()
    updateFetchStats time space = do
      let this = FetchStats { fetchDataSource = dataSource
                            , fetchBatchSize = batchSize
                            , fetchTime = time
                            , fetchSpace = space
                            , fetchFailures = 0 {- TODO -} }
      atomicModifyIORef' statsRef $ \(Stats fs) -> (Stats (this : fs), ())


wrapFetchInTrace
  :: Int
  -> Int
  -> Text.Text
  -> PerformFetch req
  -> PerformFetch req
#ifdef EVENTLOG
wrapFetchInTrace i n dsName f =
  case f of
    SyncFetch io -> SyncFetch (wrapF "Sync" io)
    AsyncFetch fio -> AsyncFetch (wrapF "Async" . fio . unwrapF "Async")
  where
    d = Text.unpack dsName
    wrapF :: String -> IO a -> IO a
    wrapF ty = bracket_ (traceEventIO $ printf "START %d %s (%d %s)" i d n ty)
                        (traceEventIO $ printf "STOP %d %s (%d %s)" i d n ty)
    unwrapF :: String -> IO a -> IO a
    unwrapF ty = bracket_ (traceEventIO $ printf "STOP %d %s (%d %s)" i d n ty)
                          (traceEventIO $ printf "START %d %s (%d %s)" i d n ty)
#else
wrapFetchInTrace _ _ _ f = f
#endif

time :: IO a -> IO (Microseconds,a)
time io = do
  t0 <- getCurrentTime
  a <- io
  t1 <- getCurrentTime
  return (microsecs (realToFrac (t1 `diffUTCTime` t0)), a)

microsecs :: Double -> Microseconds
microsecs t = round (t * 10^(6::Int))

-- | Start all the async fetches first, then perform the sync fetches before
-- getting the results of the async fetches.
scheduleFetches :: [FetchToDo] -> IO [IO ()]
scheduleFetches fetches = do
  fully_async_fetches
  waits <- future_fetches
  async_fetches sync_fetches
  return waits
 where
  fully_async_fetches :: IO ()
  fully_async_fetches =
    sequence_ [f reqs | FetchToDo reqs (BackgroundFetch f) <- fetches]

  future_fetches :: IO [IO ()]
  future_fetches = sequence [f reqs | FetchToDo reqs (FutureFetch f) <- fetches]

  async_fetches :: IO () -> IO ()
  async_fetches = compose [f reqs | FetchToDo reqs (AsyncFetch f) <- fetches]

  sync_fetches :: IO ()
  sync_fetches = sequence_ [f reqs | FetchToDo reqs (SyncFetch f) <- fetches]


-- -----------------------------------------------------------------------------
-- Memoization

-- | 'cachedComputation' memoizes a Haxl computation.  The key is a
-- request.
--
-- /Note:/ These cached computations will /not/ be included in the output
-- of 'dumpCacheAsHaskell'.
--
cachedComputation
   :: forall req u a.
      ( Eq (req a)
      , Hashable (req a)
      , Typeable (req a))
   => req a -> GenHaxl u a -> GenHaxl u a

cachedComputation req haxl = GenHaxl $ \env ref@SchedState{..} -> do
  let !memo = memoRef env
  cache <- readIORef memo
  ifProfiling (flags env) $
     modifyIORef' (profRef env) (incrementMemoHitCounterFor (profLabel env))
  case DataCache.lookup req cache of
    Just ivar -> unHaxl (getIVar ivar) env ref
    Nothing -> do
      ivar <- newIVar
      writeIORef memo $! DataCache.insertNotShowable req ivar cache
      unHaxl (execMemoNow haxl ivar) env ref


-- -----------------------------------------------------------------------------

-- | Dump the contents of the cache as Haskell code that, when
-- compiled and run, will recreate the same cache contents.  For
-- example, the generated code looks something like this:
--
-- > loadCache :: GenHaxl u ()
-- > loadCache = do
-- >   cacheRequest (ListWombats 3) (Right ([1,2,3]))
-- >   cacheRequest (CountAardvarks "abcabc") (Right (2))
--
dumpCacheAsHaskell :: GenHaxl u String
dumpCacheAsHaskell = dumpCacheAsHaskellFn "loadCache" "GenHaxl u ()"

-- | Dump the contents of the cache as Haskell code that, when
-- compiled and run, will recreate the same cache contents.
--
-- Takes the name and type for the resulting function as arguments.
dumpCacheAsHaskellFn :: String -> String -> GenHaxl u String
dumpCacheAsHaskellFn fnName fnType = do
  ref <- env cacheRef  -- NB. cacheRef, not memoRef.  We ignore memoized
                       -- results when dumping the cache.
  let
    readIVar (IVar ref) = do
      r <- readIORef ref
      case r of
        IVarFull (Ok a) -> return (Just (Right a))
        IVarFull (ThrowHaxl e) -> return (Just (Left e))
        IVarFull (ThrowIO e) -> return (Just (Left e))
        IVarEmpty _ -> return Nothing

    mk_cr (req, res) =
      text "cacheRequest" <+> parens (text req) <+> parens (result res)
    result (Left e) = text "except" <+> parens (text (show e))
    result (Right s) = text "Right" <+> parens (text s)

  entries <- unsafeLiftIO $ do
    cache <- readIORef ref
    showCache cache readIVar

  return $ show $
    text (fnName ++ " :: " ++ fnType) $$
    text (fnName ++ " = do") $$
      nest 2 (vcat (map mk_cr (concatMap snd entries))) $$
    text "" -- final newline

-- -----------------------------------------------------------------------------
-- Memoization

newtype MemoVar u a = MemoVar (IORef (MemoStatus u a))

data MemoStatus u a
  = MemoEmpty
  | MemoReady (GenHaxl u a)
  | MemoRun {-# UNPACK #-} !(IVar u a)

-- | Create a new @MemoVar@ for storing a memoized computation. The created
-- @MemoVar@ is initially empty, not tied to any specific computation. Running
-- this memo (with @runMemo@) without preparing it first (with @prepareMemo@)
-- will result in an exception.
newMemo :: GenHaxl u (MemoVar u a)
newMemo = unsafeLiftIO $ MemoVar <$> newIORef MemoEmpty

-- | Store a computation within a supplied @MemoVar@. Any memo stored within the
-- @MemoVar@ already (regardless of completion) will be discarded, in favor of
-- the supplied computation. A @MemoVar@ must be prepared before it is run.
prepareMemo :: MemoVar u a -> GenHaxl u a -> GenHaxl u ()
prepareMemo (MemoVar memoRef) memoCmp
  = unsafeLiftIO $ writeIORef memoRef (MemoReady memoCmp)

-- | Convenience function, combines @newMemo@ and @prepareMemo@.
newMemoWith :: GenHaxl u a -> GenHaxl u (MemoVar u a)
newMemoWith memoCmp = do
  memoVar <- newMemo
  prepareMemo memoVar memoCmp
  return memoVar

-- | Continue the memoized computation within a given @MemoVar@.
-- Notes:
--
--   1. If the memo contains a complete result, return that result.
--   2. If the memo contains an in-progress computation, continue it as far as
--      possible for this round.
--   3. If the memo is empty (it was not prepared), throw an error.
--
-- For example, to memoize the computation @one@ given by:
--
-- > one :: Haxl Int
-- > one = return 1
--
-- use:
--
-- > do
-- >   oneMemo <- newMemoWith one
-- >   let memoizedOne = runMemo aMemo one
-- >   oneResult <- memoizedOne
--
-- To memoize mutually dependent computations such as in:
--
-- > h :: Haxl Int
-- > h = do
-- >   a <- f
-- >   b <- g
-- >   return (a + b)
-- >  where
-- >   f = return 42
-- >   g = succ <$> f
--
-- without needing to reorder them, use:
--
-- > h :: Haxl Int
-- > h = do
-- >   fMemoRef <- newMemo
-- >   gMemoRef <- newMemo
-- >
-- >   let f = runMemo fMemoRef
-- >       g = runMemo gMemoRef
-- >
-- >   prepareMemo fMemoRef $ return 42
-- >   prepareMemo gMemoRef $ succ <$> f
-- >
-- >   a <- f
-- >   b <- g
-- >   return (a + b)
--
runMemo :: MemoVar u a -> GenHaxl u a
runMemo (MemoVar memoRef) = GenHaxl $ \env st -> do
  stored <- readIORef memoRef
  case stored of
    -- Memo was not prepared first; throw an exception.
    MemoEmpty -> raise $ CriticalError "Attempting to run empty memo."
    -- Memo has been prepared but not run yet
    MemoReady cont -> do
      ivar <- newIVar
      writeIORef memoRef (MemoRun ivar)
      unHaxl (execMemoNow cont ivar) env st
    -- The memo has already been run, get (or wait for) for the result
    MemoRun ivar -> unHaxl (getIVar ivar) env st


execMemoNow :: GenHaxl u a -> IVar u a -> GenHaxl u a
execMemoNow cont ivar = GenHaxl $ \env st -> do
  r <- Exception.try $ unHaxl cont env st
  case r of
    Left e -> do
      rethrowAsyncExceptions e
      putIVar ivar (ThrowIO e) st
      throwIO e
    Right (Done a) -> do
      putIVar ivar (Ok a) st
      return (Done a)
    Right (Throw ex) -> do
      putIVar ivar (ThrowHaxl ex) st
      return (Throw ex)
    Right (Blocked ivar' cont) -> do
      addJob (toHaxl cont) ivar ivar'
      return (Blocked ivar (Cont (getIVar ivar)))

-- -----------------------------------------------------------------------------
-- 1-ary and 2-ary memo functions

newtype MemoVar1 u a b = MemoVar1 (IORef (MemoStatus1 u a b))
newtype MemoVar2 u a b c = MemoVar2 (IORef (MemoStatus2 u a b c))

data MemoStatus1 u a b
  = MemoEmpty1
  | MemoTbl1 (a -> GenHaxl u b) (HashMap.HashMap a (MemoVar u b))

data MemoStatus2 u a b c
  = MemoEmpty2
  | MemoTbl2
      (a -> b -> GenHaxl u c)
      (HashMap.HashMap a (HashMap.HashMap b (MemoVar u c)))

newMemo1 :: GenHaxl u (MemoVar1 u a b)
newMemo1 = unsafeLiftIO $ MemoVar1 <$> newIORef MemoEmpty1

newMemoWith1 :: (a -> GenHaxl u b) -> GenHaxl u (MemoVar1 u a b)
newMemoWith1 f = newMemo1 >>= \r -> prepareMemo1 r f >> return r

prepareMemo1 :: MemoVar1 u a b -> (a -> GenHaxl u b) -> GenHaxl u ()
prepareMemo1 (MemoVar1 r) f
  = unsafeLiftIO $ writeIORef r (MemoTbl1 f HashMap.empty)

runMemo1 :: (Eq a, Hashable a) => MemoVar1 u a b -> a -> GenHaxl u b
runMemo1 (MemoVar1 r) k = unsafeLiftIO (readIORef r) >>= \case
  MemoEmpty1 -> throw $ CriticalError "Attempting to run empty memo."
  MemoTbl1 f h -> case HashMap.lookup k h of
    Nothing -> do
      x <- newMemoWith (f k)
      unsafeLiftIO $ writeIORef r (MemoTbl1 f (HashMap.insert k x h))
      runMemo x
    Just v -> runMemo v

newMemo2 :: GenHaxl u (MemoVar2 u a b c)
newMemo2 = unsafeLiftIO $ MemoVar2 <$> newIORef MemoEmpty2

newMemoWith2 :: (a -> b -> GenHaxl u c) -> GenHaxl u (MemoVar2 u a b c)
newMemoWith2 f = newMemo2 >>= \r -> prepareMemo2 r f >> return r

prepareMemo2 :: MemoVar2 u a b c -> (a -> b -> GenHaxl u c) -> GenHaxl u ()
prepareMemo2 (MemoVar2 r) f
  = unsafeLiftIO $ writeIORef r (MemoTbl2 f HashMap.empty)

runMemo2 :: (Eq a, Hashable a, Eq b, Hashable b)
         => MemoVar2 u a b c
         -> a -> b -> GenHaxl u c
runMemo2 (MemoVar2 r) k1 k2 = unsafeLiftIO (readIORef r) >>= \case
  MemoEmpty2 -> throw $ CriticalError "Attempting to run empty memo."
  MemoTbl2 f h1 -> case HashMap.lookup k1 h1 of
    Nothing -> do
      v <- newMemoWith (f k1 k2)
      unsafeLiftIO $ writeIORef r
        (MemoTbl2 f (HashMap.insert k1 (HashMap.singleton k2 v) h1))
      runMemo v
    Just h2 -> case HashMap.lookup k2 h2 of
      Nothing -> do
        v <- newMemoWith (f k1 k2)
        unsafeLiftIO $ writeIORef r
          (MemoTbl2 f (HashMap.insert k1 (HashMap.insert k2 v h2) h1))
        runMemo v
      Just v -> runMemo v



-- -----------------------------------------------------------------------------
-- Parallel operations

-- Bind more tightly than .&&, .||
infixr 5 `pAnd`
infixr 4 `pOr`

-- | Parallel version of '(.||)'.  Both arguments are evaluated in
-- parallel, and if either returns 'True' then the other is
-- not evaluated any further.
--
-- WARNING: exceptions may be unpredictable when using 'pOr'.  If one
-- argument returns 'True' before the other completes, then 'pOr'
-- returns 'True' immediately, ignoring a possible exception that
-- the other argument may have produced if it had been allowed to
-- complete.
pOr :: GenHaxl u Bool -> GenHaxl u Bool -> GenHaxl u Bool
GenHaxl a `pOr` GenHaxl b = GenHaxl $ \env ref -> do
  ra <- a env ref
  case ra of
    Done True -> return (Done True)
    Done False -> b env ref
    Throw _ -> return ra
    Blocked a' -> do
      rb <- b env ref
      case rb of
        Done True -> return (Blocked (Cont (return True)))
          -- Note [tricky pOr/pAnd]
        Done False -> return ra
        Throw e -> return (Blocked (Cont (throw e)))
        Blocked b' -> return (Blocked (Cont (toHaxl a' `pOr` toHaxl b')))

-- | Parallel version of '(.&&)'.  Both arguments are evaluated in
-- parallel, and if either returns 'False' then the other is
-- not evaluated any further.
--
-- WARNING: exceptions may be unpredictable when using 'pAnd'.  If one
-- argument returns 'False' before the other completes, then 'pAnd'
-- returns 'False' immediately, ignoring a possible exception that
-- the other argument may have produced if it had been allowed to
-- complete.
pAnd :: GenHaxl u Bool -> GenHaxl u Bool -> GenHaxl u Bool
GenHaxl a `pAnd` GenHaxl b = GenHaxl $ \env ref -> do
  ra <- a env ref
  case ra of
    Done False -> return (Done False)
    Done True -> b env ref
    Throw _ -> return ra
    Blocked a' -> do
      rb <- b env ref
      case rb of
        Done False -> return (Blocked (Cont (return False)))
          -- Note [tricky pOr/pAnd]
        Done True -> return ra
        Throw _ -> return rb
        Blocked b' -> return (Blocked (Cont (toHaxl a' `pAnd` toHaxl b')))

{-
Note [tricky pOr/pAnd]

If one branch returns (Done True) and the other returns (Blocked _),
even though we know the result will be True (in the case of pOr), we
must return Blocked.  This is because there are data fetches to
perform, and if we don't do this, the cache is left with an empty
ResultVar, and the next fetch for the same request will fail.

Alternatives:

 * Test for a non-empty RequestStore in runHaxl when we get Done, but
   that would penalise every runHaxl.

 * Try to abandon the fetches. This is hard: we've already stored the
   requests and a ResultVars in the cache, and we don't know how to
   find the right fetches to remove from the cache.  Furthermore, we
   might have partially computed some memoized computations.
-}
