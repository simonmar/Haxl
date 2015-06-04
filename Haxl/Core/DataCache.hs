-- Copyright (c) 2014, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file. An additional grant of patent rights can
-- be found in the PATENTS file.

{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | A cache mapping data requests to their results.
module Haxl.Core.DataCache
  ( DataCache
  , empty
  , insert
  , lookup
--  , showCache
  ) where

import Data.HashMap.Strict (HashMap)
import Data.Hashable
import Prelude hiding (lookup)
import Unsafe.Coerce
import qualified Data.HashMap.Strict as HashMap
import Data.Typeable.Internal
import Data.Maybe
import Control.Applicative hiding (empty)
import Control.Exception

import Haxl.Core.Types
import {-# SOURCE #-} Haxl.Core.Monad

-- | The 'DataCache' maps things of type @f a@ to @'ResultVar' a@, for
-- any @f@ and @a@ provided @f a@ is an instance of 'Typeable'. In
-- practice @f a@ will be a request type parameterised by its result.
--
-- See the definition of 'ResultVar' for more details.

newtype DataCache u = DataCache (HashMap TypeRep (SubCache u))

-- | The implementation is a two-level map: the outer level maps the
-- types of requests to 'SubCache', which maps actual requests to their
-- results.  So each 'SubCache' contains requests of the same type.
-- This works well because we only have to store the dictionaries for
-- 'Hashable' and 'Eq' once per request type.
data SubCache u =
  forall req a . (Hashable (req a), Eq (req a), Show (req a), Show a) =>
       SubCache ! (HashMap (req a) (IVar u a))
       -- NB. the inner HashMap is strict, to avoid building up
       -- a chain of thunks during repeated insertions.

-- | A new, empty 'DataCache'.
empty :: DataCache u
empty = DataCache HashMap.empty

-- | Inserts a request-result pair into the 'DataCache'.
insert
  :: (Hashable (r a), Typeable (r a), Eq (r a), Show (r a), Show a)
  => r a
  -- ^ Request
  -> IVar u a
  -- ^ Result
  -> DataCache u
  -> DataCache u

insert req result (DataCache m) =
      DataCache $
        HashMap.insertWith fn (typeOf req)
                              (SubCache (HashMap.singleton req result)) m
  where
    fn (SubCache new) (SubCache old) =
        SubCache (unsafeCoerce new `HashMap.union` old)

-- | Looks up the cached result of a request.
lookup
  :: Typeable (r a)
  => r a
  -- ^ Request
  -> DataCache u
  -> Maybe (IVar u a)

lookup req (DataCache m) =
      case HashMap.lookup (typeOf req) m of
        Nothing -> Nothing
        Just (SubCache sc) ->
           unsafeCoerce (HashMap.lookup (unsafeCoerce req) sc)

{-
-- | Dumps the contents of the cache, with requests and responses
-- converted to 'String's using 'show'.  The entries are grouped by
-- 'TypeRep'.
--
showCache
  :: DataCache u
  -> IO [(TypeRep, [(String, Either SomeException String)])]

showCache (DataCache cache) = mapM goSubCache (HashMap.toList cache)
 where
  goSubCache
    :: (TypeRep,SubCache u)
    -> IO (TypeRep,[(String, Either SomeException String)])
  goSubCache (ty, SubCache hmap) = do
    elems <- catMaybes <$> mapM go (HashMap.toList hmap)
    return (ty, elems)

  go :: (Show (req a), Show a)
     => (req a, IVar u a)
     -> IO (Maybe (String, Either SomeException String))
  go (req, rvar) = do
    maybe_r <- tryReadResult rvar
    case maybe_r of
      Nothing -> return Nothing
      Just (Left e) -> return (Just (show req, Left e))
      Just (Right result) -> return (Just (show req, Right (show result)))
-}
