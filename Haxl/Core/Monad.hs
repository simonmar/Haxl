-- Copyright (c) 2014, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file. An additional grant of patent rights can
-- be found in the PATENTS file.

{- TODO

- even with submit/wait async data sources, we could do some computation
  as soon as we have results, possibly getting more concurrency
- try out the build system with this
- write different scheduling policies
- write benchmarks to compare this with Haxl 1.0
- implement cachedComputation etc.

-}

{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

-- | The implementation of the 'Haxl' monad.
module Haxl.Core.Monad (
    -- * The monad
    GenHaxl (..), runHaxl,
    env,

    IVar(..), IVarContents(..),

    -- * Exceptions
    throw, catch, catchIf, try, tryToHaxlException,

    -- * Data fetching and caching
    dataFetch, {- uncachedRequest, -}
    cacheRequest, {- cacheResult, -} cachedComputation,
    {- dumpCacheAsHaskell, -}

    -- * Unsafe operations
    unsafeLiftIO, unsafeToHaxlException,
  ) where

import Haxl.Core.Types
import Haxl.Core.Fetch
import Haxl.Core.Env
import Haxl.Core.Exception
import Haxl.Core.RequestStore as RequestStore
import Haxl.Core.Util
import Haxl.Core.DataCache as DataCache

import Data.Maybe
import qualified Data.Text as Text
import Control.Exception (Exception(..), SomeException, throwIO)
import qualified Control.Exception
import Control.Applicative hiding (Const)
import GHC.Exts (IsString(..))
#if __GLASGOW_HASKELL__ < 706
import Prelude hiding (catch)
#endif
import Data.IORef
import Data.Monoid
import Text.Printf
import Text.PrettyPrint hiding ((<>))
import Control.Arrow (left)
import Control.Concurrent.STM
import Control.Monad

-- -----------------------------------------------------------------------------
-- | The Haxl monad, which does several things:
--
--  * It is a reader monad for 'Env' and 'IORef' 'RequestStore', The
--    latter is the current batch of unsubmitted data fetch requests.
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
  { reqStoreRef :: !(IORef (RequestStore u))
       -- ^ The set of requests that we have not submitted to data sources yet.
       -- Owned by the scheduler.
  , runQueue    :: !(IORef [GenHaxl u ()])
       -- ^ Computations waiting to run.
       -- Owned by the scheduler.
  , numRequests :: !(IORef Int)
       -- ^ Number of requests that we have submitted to data sources but
       -- that have not yet completed.
       -- Owned by the scheduler.
  , completions :: !(TVar [CompleteReq u])
       -- ^ Requests that have completed.
       -- Modified by data sources (via putResult) and the scheduler.
  }

-- | A list of 'GenHaxl' computations waiting for a value.  When we
-- block on a resource, a 'ContVar' is created to track the blocked
-- computations.  If another computation becomes blocked on the same
-- resource, it will be added to the list in this 'IORef'.
type ContVar u a = IORef [GenHaxl u ()] -- Owned by the scheduler

-- | A synchronisation point.  It either contains the value, or a list
-- of computations waiting for the value.
newtype IVar u a = IVar (IORef (IVarContents u a))

data IVarContents u a
  = IVarFull a
  | IVarEmpty !(ContVar u a)

-- | A completed request from a data source, containing the result,
-- and the 'IVar' representing the blocked computations.  The job of a
-- data source is just to add these to a queue (completions) using
-- putResult; the scheduler collects them from the queue and unblocks
-- the relevant computations.
data CompleteReq u =
  forall a . CompleteReq (Either SomeException a)
                         (IVar u (Either SomeException a))

-- | The result of a computation is either 'Done' with a value, 'Throw'
-- with an exception, or 'Blocked' on the result of a data fetch with
-- a continuation.
data Result u a
  = Done a
  | Throw SomeException
  | forall b . Blocked
      !(ContVar u b)      -- ^ What we are blocked on
      (GenHaxl u a)  -- ^ The continuation.  This might be
                          -- wrapped further if we're nested inside
                          -- multiple '>>=', before finally being
                          -- added to the 'ContVar'.

instance (Show a) => Show (Result u a) where
  show (Done a) = printf "Done(%s)" $ show a
  show (Throw e) = printf "Throw(%s)" $ show e
  show Blocked{} = "Blocked"

instance Monad (GenHaxl u) where
  return a = GenHaxl $ \_env _ref -> return (Done a)
  GenHaxl m >>= k = GenHaxl $ \env ref -> do
    e <- m env ref
    case e of
      Done a       -> unHaxl (k a) env ref
      Throw e      -> return (Throw e)
      Blocked cont f -> return (Blocked cont (f >>= k))

instance Functor (GenHaxl u) where
  fmap f (GenHaxl m) = GenHaxl $ \env ref -> do
    r <- m env ref
    case r of
     Done a -> return (Done (f a))
     Throw e -> return (Throw e)
     Blocked cvar cont ->
       return (Blocked cvar (do a <- cont; return (f a)))

instance Applicative (GenHaxl u) where
  pure = return
  GenHaxl f <*> GenHaxl a = GenHaxl $ \env ref -> do
    r <- f env ref
    case r of
      Throw e -> return (Throw e)
      Done f' -> do
        ra <- a env ref
        case ra of
          Done a'    -> return (Done (f' a'))
          Throw e    -> return (Throw e)
          Blocked cont fa -> return (Blocked cont (f' <$> fa))
      Blocked cvar1 ff -> do
        ra <- a env ref  -- left is blocked, explore the right
        case ra of
          Done a' ->
            return (Blocked cvar1 (do f <- ff; return (f a')))
          Throw e ->
            return (Blocked cvar1 (ff <*> throw e))
          Blocked cvar2 fa -> do        -- Note [Blocked/Blocked]
            i <- newIVar
            modifyIORef' cvar1 $ \cs -> (ff >>= putIVar i) : cs
            let cont =  do a <- fa; f <- getIVar i; return (f a)
            return (Blocked cvar2 cont)




-- Note [Blocked/Blocked]
--
-- This is the tricky case: we're blocked on both sides of the <*>.
-- We need to divide the computation into two pieces that may continue
-- independently when the resources they are blocked on become
-- available.  Moreover, the computation as a whole depends on the two
-- pieces.  It works like this:
--
--   f <*> a
--
-- becomes
--
--   (do ff <- f; getIVar i; return (ff a)) <*> (a >>= putIVar i)
--
-- where the IVar i is a new synchronisation point.  If the left side
-- gets to the `getIVar` first, it will block until the right side has
-- called 'putIVar'.


getIVar :: IVar u a -> GenHaxl u a
getIVar (IVar !ref) = GenHaxl $ \_ _ -> do
  e <- readIORef ref
  case e of
    IVarFull a -> return (Done a)
    IVarEmpty cref -> return (Blocked cref (getIVar (IVar ref)))

putIVar :: IVar u a -> a -> GenHaxl u ()
putIVar (IVar !ref) a = GenHaxl $ \_ SchedState{..} -> do
  e <- readIORef ref
  case e of
    IVarFull a -> error "putIVar: multiple put"
    IVarEmpty cref -> do
      writeIORef ref (IVarFull a)
      haxls <- readIORef cref
      modifyIORef' runQueue (haxls ++)
      return (Done ())

newIVar :: IO (IVar u a)
newIVar = do
  cref <- newIORef []
  ref <- newIORef (IVarEmpty cref)
  return (IVar ref)


data SchedPolicy
  = SubmitImmediately
  | WaitAtLeast Int{-ms-}
  | WaitForAllPendingRequests

-- | Runs a 'Haxl' computation in an 'Env'.
runHaxl :: forall u a. Env u -> GenHaxl u a -> IO a
runHaxl env haxl = do
  q <- newIORef []                   -- run queue
  resultRef <- newIORef Nothing      -- where to put the final result
  rs <- newIORef noRequests          -- RequestStore
  nr <- newIORef 0                   -- numRequests
  comps <- newTVarIO []              -- completion queue
  let st = SchedState
             { reqStoreRef = rs
             , runQueue = q
             , numRequests = nr
             , completions = comps }
  schedule st (haxl >>= unsafeLiftIO . writeIORef resultRef . Just)
  r <- readIORef resultRef
  case r of
    Nothing -> throwIO (CriticalError "runHaxl: missing result")
    Just a  -> return a
 where
  schedule :: SchedState u -> GenHaxl u () -> IO ()
  schedule q (GenHaxl run) = do
    r <- run env q
    case r of
      Done _ -> reschedule q
      Throw e -> throwIO e
      Blocked cref fn -> do
        modifyIORef' cref (fn:)
        reschedule q

  reschedule :: SchedState u -> IO ()
  reschedule q@SchedState{..} = do
--    printf "reschedule\n"
    haxls <- readIORef runQueue
    case haxls of
      [] -> emptyRunQueue q
      h:hs -> do
--       printf "run queue: %d\n" (length (h:hs))
       writeIORef runQueue hs
       schedule q h

  -- Here we have a choice:
  --   - for latency: submit requests as soon as we have them
  --   - for batching: wait until all outstanding requests have finished
  --     before submitting the next batch.  We can still begin running
  --     as soon as we have results.
  --   - compromise: wait at least Nms for an outstanding result
  --     before giving up and submitting new requests.
  emptyRunQueue :: SchedState u -> IO ()
  emptyRunQueue q@SchedState{..} = do
--    printf "emptyRunQueue\n"
    any_done <- checkCompletions q
    if any_done
      then reschedule q
      else do
        reqStore <- readIORef reqStoreRef
        if RequestStore.isEmpty reqStore
          then waitCompletions q
          else do
            writeIORef reqStoreRef noRequests
            performFetches env reqStore -- latency optimised
            emptyRunQueue q

  checkCompletions :: SchedState u -> IO Bool
  checkCompletions q@SchedState{..} = do
--    printf "checkCompletions\n"
    comps <- atomically $ do
      c <- readTVar completions
      writeTVar completions []
      return c
    case comps of
      [] -> return False
      _ -> do
--        printf "%d complete\n" (length comps)
        let getComplete (CompleteReq a (IVar cr)) = do
              r <- readIORef cr
              case r of
                IVarFull _ -> do
--                  printf "existing result\n"
                  return []
                  -- this happens if a data source reports a result,
                  -- and then throws an exception.  We call putResult
                  -- a second time for the exception, which comes
                  -- ahead of the original request (because it is
                  -- pushed on the front of the completions list) and
                  -- therefore overrides it.
                IVarEmpty cv -> do
                  writeIORef cr (IVarFull a)
                  modifyIORef' numRequests (subtract 1)
                  readIORef cv
        jobs <- mapM getComplete comps
        modifyIORef' runQueue (concat jobs ++)
        return True

  waitCompletions :: SchedState u -> IO ()
  waitCompletions q@SchedState{..} = do
    n <- readIORef numRequests
    if n == 0
       then return ()
       else do
         atomically $ do
           c <- readTVar completions
           when (null c) retry
         emptyRunQueue q


-- | Extracts data from the 'Env'.
env :: (Env u -> a) -> GenHaxl u a
env f = GenHaxl $ \env _ref -> return (Done (f env))


-- -----------------------------------------------------------------------------
-- Cache management

-- | Possible responses when checking the cache.
data CacheResult u a
  -- | The request hadn't been seen until now.
  = Uncached (ResultVar a) !(ContVar u (Either SomeException a)) !(IVar u (Either SomeException a))

  -- | The request has been seen before, but its result has not yet been
  -- fetched.
  | CachedNotFetched !(ContVar u (Either SomeException a)) !(IVar u (Either SomeException a))

  -- | The request has been seen before, and its result has already been
  -- fetched.
  | Cached (Either SomeException a)


-- | Checks the data cache for the result of a request.
cached :: (Request r a) => Env u -> SchedState u -> r a
       -> IO (CacheResult u a)
cached env st = checkCache (flags env) st (cacheRef env)

-- | Checks the memo cache for the result of a computation.
memoized :: (Request r a) => Env u -> SchedState u -> r a
         -> IO (CacheResult u a)
memoized env st = checkCache (flags env) st (memoRef env)

-- | Common guts of 'cached' and 'memoized'.
checkCache
  :: (Request r a)
  => Flags
  -> SchedState u
  -> IORef (DataCache u)
  -> r a
  -> IO (CacheResult u a)

checkCache flags SchedState{..} ref req = do
  cache <- readIORef ref
  let
    do_fetch = do
      cvar <- newContVar
      cr <- IVar <$> newIORef (IVarEmpty cvar)
      let done r = atomically $ do
            cs <- readTVar completions
            writeTVar completions (CompleteReq r cr : cs)
      rvar <- newEmptyResult done
      writeIORef ref $! DataCache.insert req cr cache
      modifyIORef' numRequests (+1)
      return (Uncached rvar cvar cr)
  case DataCache.lookup req cache of
    Nothing -> do_fetch
    Just (IVar cr) -> do
      e <- readIORef cr
      case e of
        IVarEmpty cvar -> return (CachedNotFetched cvar (IVar cr))
        IVarFull r -> do
          ifTrace flags 3 $ putStrLn $ case r of
            Left _ -> "Cached error: " ++ show req
            Right _ -> "Cached request: " ++ show req
          return (Cached r)

newContVar :: IO (ContVar u a)
newContVar = newIORef []

-- -----------------------------------------------------------------------------
-- Exceptions

-- | Throw an exception in the Haxl monad
throw :: (Exception e) => e -> GenHaxl u a
throw e = GenHaxl $ \_env _ref -> raise e

raise :: (Exception e) => e -> IO (Result u a)
raise = return . Throw . toException

-- | Catch an exception in the Haxl monad
catch :: Exception e => GenHaxl u a -> (e -> GenHaxl u a) -> GenHaxl u a
catch (GenHaxl m) h = GenHaxl $ \env ref -> do
   r <- m env ref
   case r of
     Done a    -> return (Done a)
     Throw e | Just e' <- fromException e -> unHaxl (h e') env ref
             | otherwise -> return (Throw e)
     Blocked cont k -> return (Blocked cont (catch k h))

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
  r <- m env ref `Control.Exception.catch` \e -> return (Throw e)
  case r of
    Blocked cont c -> return (Blocked cont (unsafeToHaxlException c))
    other -> return other

-- | Like 'try', but lifts all exceptions into the 'HaxlException'
-- hierarchy.  Uses 'unsafeToHaxlException' internally.  Typically
-- this is used at the top level of a Haxl computation, to ensure that
-- all exceptions are caught.
tryToHaxlException :: GenHaxl u a -> GenHaxl u (Either HaxlException a)
tryToHaxlException h = left asHaxlException <$> try (unsafeToHaxlException h)

-- -----------------------------------------------------------------------------
-- Data fetching and caching

-- | Performs actual fetching of data for a 'Request' from a 'DataSource'.
dataFetch :: (DataSource u r, Request r a) => r a -> GenHaxl u a
dataFetch req = GenHaxl $ \env st@SchedState{..} -> do
  -- First, check the cache
  res <- cached env st req
  case res of
    -- Not seen before: add the request to the RequestStore, so it
    -- will be fetched in the next round.
    Uncached rvar cvar ivar -> do
      modifyIORef' reqStoreRef $ \bs -> addRequest (BlockedFetch req rvar) bs
      return $ Blocked cvar (getIVar ivar >>= doneH)

    -- Seen before but not fetched yet.  We're blocked, but we don't have
    -- to add the request to the RequestStore.
    CachedNotFetched cvar ivar -> return $ Blocked cvar (getIVar ivar >>= doneH)

    -- Cached: either a result, or an exception
    Cached r -> done r


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
uncachedRequest :: (DataSource u r, Request r a) => r a -> GenHaxl u a
uncachedRequest req = GenHaxl $ \_env SchedState{..} -> do
  cvar <- newContVar
  cr <- IVar <$> newIORef (IVarEmpty cvar)
  let done r = atomically $ do
        cs <- readTVar completions
        writeTVar completions (CompleteReq r cr : cs)
  rvar <- newEmptyResult done
  modifyIORef' numRequests (+1)
  return $ Blocked cvar (getIVar cr >>= doneH)

-- | Transparently provides caching. Useful for datasources that can
-- return immediately, but also caches values.
cacheResult :: (Request r a)  => r a -> IO a -> GenHaxl u a
cacheResult req val = GenHaxl $ \env st -> do
  cachedResult <- cached env st req
  case cachedResult of
    Uncached rvar cvar _ivar -> do
      result <- Control.Exception.try val
      putResult rvar result
      done result
    Cached result -> done result
    CachedNotFetched _ _ -> corruptCache
  where
    corruptCache = raise . DataSourceError $ Text.concat
      [ textShow req
      , " has a corrupted cache value: these requests are meant to"
      , " return immediately without an intermediate value. Either"
      , " the cache was updated incorrectly, or you're calling"
      , " cacheResult on a query that involves a blocking fetch."
      ]

-- | Inserts a request/result pair into the cache. Throws an exception
-- if the request has already been issued, either via 'dataFetch' or
-- 'cacheRequest'.
--
-- This can be used to pre-populate the cache when running tests, to
-- avoid going to the actual data source and ensure that results are
-- deterministic.
--
cacheRequest
  :: (Request req a) => req a -> Either SomeException a -> GenHaxl u ()
cacheRequest request result = GenHaxl $ \env _st -> do
  cache <- readIORef (cacheRef env)
  case DataCache.lookup request cache of
    Nothing -> do
      cr <- IVar <$> newIORef (IVarFull result)
      writeIORef (cacheRef env) $! DataCache.insert request cr cache
      return (Done ())

    -- It is an error if the request is already in the cache.  We can't test
    -- whether the cached result is the same without adding an Eq constraint,
    -- and we don't necessarily have Eq for all results.
    _other -> raise $
      DataSourceError "cacheRequest: request is already in the cache"

instance IsString a => IsString (GenHaxl u a) where
  fromString s = return (fromString s)

-- | 'cachedComputation' memoizes a Haxl computation.  The key is a
-- request.
--
-- /Note:/ These cached computations will /not/ be included in the output
-- of 'dumpCacheAsHaskell'.
--
cachedComputation
   :: forall req u a. (Request req a)
   => req a -> GenHaxl u a -> GenHaxl u a
cachedComputation req haxl = GenHaxl $ \env ref -> do
  res <- memoized env ref req
  case res of
    -- Uncached: we must compute the result and store it in the ResultVar.
    Uncached rvar cvar _ivar -> do
      let
          with_result :: Either SomeException a -> GenHaxl u a
          with_result r = GenHaxl $ \_ _ -> do putResult rvar r; done r

      unHaxl (try haxl >>= with_result) env ref

    -- CachedNotFetched: this request is already being computed, we just
    -- have to block until the result is available.  Note that we might
    -- have to block repeatedly, because the Haxl computation might block
    -- multiple times before it has a result.
    CachedNotFetched cvar ivar -> return $ Blocked cvar (getIVar ivar >>= doneH)
    Cached r -> done r

-- | Lifts an 'Either' into either 'Throw' or 'Done'.
done :: Either SomeException a -> IO (Result u a)
done = return . either Throw Done

-- | Lifts an 'Either' into either 'Throw' or 'Done'.
doneH :: Either SomeException a -> GenHaxl u a
doneH a = GenHaxl $ \_ _ -> done a

{-
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
dumpCacheAsHaskell = do
  ref <- env cacheRef  -- NB. cacheRef, not memoRef.  We ignore memoized
                       -- results when dumping the cache.
  entries <- unsafeLiftIO $ readIORef ref >>= showCache
  let
    mk_cr (req, res) =
      text "cacheRequest" <+> parens (text req) <+> parens (result res)
    result (Left e) = text "except" <+> parens (text (show e))
    result (Right s) = text "Right" <+> parens (text s)

  return $ show $
    text "loadCache :: GenHaxl u ()" $$
    text "loadCache = do" $$
      nest 2 (vcat (map mk_cr (concatMap snd entries))) $$
    text "" -- final newline


-}
