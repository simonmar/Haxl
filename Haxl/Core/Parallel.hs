-- Copyright (c) 2014-present, Facebook, Inc.
-- All rights reserved.
--
-- This source code is distributed under the terms of a BSD license,
-- found in the LICENSE file.

{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Psuedo-parallel operations.  Most users should import "Haxl.Core"
-- instead.
--
module Haxl.Core.Parallel
  ( -- * Parallel operations
    pAnd
  , pOr
  ) where

import Haxl.Core.Monad

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
pOr :: GenHaxl u w Bool -> GenHaxl u w Bool -> GenHaxl u w Bool
pOr = (<||>)


-- | Parallel version of '(.&&)'.  Both arguments are evaluated in
-- parallel, and if either returns 'False' then the other is
-- not evaluated any further.
--
-- WARNING: exceptions may be unpredictable when using 'pAnd'.  If one
-- argument returns 'False' before the other completes, then 'pAnd'
-- returns 'False' immediately, ignoring a possible exception that
-- the other argument may have produced if it had been allowed to
-- complete.
pAnd :: GenHaxl u w Bool -> GenHaxl u w Bool -> GenHaxl u w Bool
pAnd = (<&&>)
