{-# LANGUAGE RebindableSyntax, OverloadedStrings #-}
module BatchTests (tests) where

import TestTypes
import MockTAO

import Control.Applicative
import Data.IORef
import Data.Aeson
import Test.HUnit
import qualified Data.HashMap.Strict as HashMap

import Haxl.Core

import Prelude()
import Haxl.Prelude

-- -----------------------------------------------------------------------------

testinput :: Object
testinput = HashMap.fromList [
  "A" .= (1 :: Int),
  "B" .= (2 :: Int),
  "C" .= (3 :: Int),
  "D" .= (4 :: Int) ]

makeTestEnv :: Bool -> IO (Env UserEnv)
makeTestEnv future = do
  tao <- MockTAO.initGlobalState future
  let st = stateSet tao stateEmpty
  initEnv st testinput

expectRoundsWithEnv
  :: (Eq a, Show a) => Int -> a -> Haxl a -> Env UserEnv -> Assertion
expectRoundsWithEnv n result haxl env = do
  a <- runHaxl env haxl
  assertEqual "result" result a
  stats <- readIORef (statsRef env)
  assertEqual "rounds" n (numRounds stats)

expectRounds :: (Eq a, Show a) => Int -> a -> Haxl a -> Bool -> Assertion
expectRounds n result haxl future = do
  env <- makeTestEnv future
  expectRoundsWithEnv n result haxl env

expectFetches :: (Eq a, Show a) => Int -> Haxl a -> Bool -> Assertion
expectFetches n haxl future = do
  env <- makeTestEnv future
  _ <- runHaxl env haxl
  stats <- readIORef (statsRef env)
  assertEqual "fetches" n (numFetches stats)

friendsOf :: Id -> Haxl [Id]
friendsOf = assocRangeId2s friendsAssoc

id1 :: Haxl Id
id1 = lookupInput "A"

id2 :: Haxl Id
id2 = lookupInput "B"

id3 :: Haxl Id
id3 = lookupInput "C"

--
-- Test batching over multiple arguments in liftA2
--
batching1 = expectRounds 1 12 batching1_

batching1_ = do
  a <- id1
  b <- id2
  length <$> liftA2 (++) (friendsOf a) (friendsOf b)

--
-- Test batching in mapM (which is really traverse)
--
batching2 = expectRounds 1 12 batching2_

batching2_ = do
  a <- id1
  b <- id2
  fs <- mapM friendsOf [a,b]
  return (sum (map length fs))

--
-- Test batching when we have a monadic bind in each branch
--
batching3 = expectRounds 1 12 batching3_

batching3_ = do
  let a = id1 >>= friendsOf
      b = id2 >>= friendsOf
  length <$> a .++ b

--
-- Test batching over both arguments of (+)
--
batching4 = expectRounds 1 12 batching4_

batching4_ = do
  let a = length <$> (id1 >>= friendsOf)
      b = length <$> (id2 >>= friendsOf)
  a + b

--
-- Test batching over both arguments of (+)
--
batching5 = expectRounds 1 2 batching5_

batching5_ :: Haxl Int
batching5_ = if a .> b then 1 else 2
 where
  a = length <$> (id1 >>= friendsOf)
  b = length <$> (id2 >>= friendsOf)

--
-- Test batching when we perform all batching tests together with sequence
--
batching6 = expectRounds 1 [12,12,12,12,2] batching6_

batching6_ = sequence [batching1_,batching2_,batching3_,batching4_,batching5_]

--
-- Ensure if/then/else and bool operators break batching
--
batching7 = expectRounds 2 12 batching7_

batching7_ :: Haxl Int
batching7_ = if a .> 0 then a+b else 0
 where
  a = length <$> (id1 >>= friendsOf)
  b = length <$> (id2 >>= friendsOf)

-- We expect 3 rounds here due to boolean operators
batching8 = expectRounds 3 12 batching8_

batching8_ :: Haxl Int
batching8_ = if (c .== 0) .|| (a .> 0 .&& b .> 0) then a+b else 0
 where
  a = length <$> (id1 >>= friendsOf)
  b = length <$> (id2 >>= friendsOf)
  c = length <$> (id3 >>= friendsOf)

--
-- Test data caching, numFetches
--

-- simple (one cache hit)
caching1 = expectFetches 3 caching1_
caching1_ = nf id1 + nf id2 + nf id3 + nf id3
 where
  nf id = length <$> (id >>= friendsOf)

-- simple, in rounds (no cache hits)
caching2 = expectFetches 3 caching2_
caching2_ = if nf id1 .> 0 then nf id2 + nf id3 else 0
 where
  nf id = length <$> (id >>= friendsOf)

-- rounds (one cache hit)
caching3 = expectFetches 3 caching3_
caching3_ = if nf id1 .> 0 then nf id1 + nf id2 + nf id3 else 0
 where
  nf id = length <$> (id >>= friendsOf)

--
-- Basic sanity check on data-cache re-use
--
cacheReuse future = do
  env <- makeTestEnv future
  expectRoundsWithEnv 2 12 batching7_ env

  -- make a new env
  tao <- MockTAO.initGlobalState future
  let st = stateSet tao stateEmpty
  env2 <- initEnvWithData st testinput (caches env)

  -- ensure no more data fetching rounds needed
  expectRoundsWithEnv 0 12 batching7_ env2

tests :: Bool -> Test
tests future = TestList
  [ TestLabel "batching1" $ TestCase (batching1 future)
  , TestLabel "batching2" $ TestCase (batching2 future)
  , TestLabel "batching3" $ TestCase (batching3 future)
  , TestLabel "batching4" $ TestCase (batching4 future)
  , TestLabel "batching5" $ TestCase (batching5 future)
  , TestLabel "batching6" $ TestCase (batching6 future)
  , TestLabel "batching7" $ TestCase (batching7 future)
  , TestLabel "batching8" $ TestCase (batching8 future)
  , TestLabel "caching1" $ TestCase (caching1 future)
  , TestLabel "caching2" $ TestCase (caching2 future)
  , TestLabel "caching3" $ TestCase (caching3 future)
  , TestLabel "CacheReuse" $ TestCase (cacheReuse future)
  , TestLabel "exceptionTest1" $ TestCase (exceptionTest1 future)
  , TestLabel "exceptionTest2" $ TestCase (exceptionTest2 future)
  , TestLabel "deterministicExceptions" $
      TestCase (deterministicExceptions future)
  ]

exceptionTest1 = expectRounds 1 []
  $ withDefault [] $ friendsOf 101

exceptionTest2 = expectRounds 1 [7..12] $ liftA2 (++)
  (withDefault [] (friendsOf 101))
  (withDefault [] (friendsOf 2))

deterministicExceptions future = do
  env <- makeTestEnv future
  let haxl =
        sequence [ do _ <- friendsOf =<< id1; throw (NotFound "xxx")
                 , throw (NotFound "yyy")
                 ]
  -- the first time, friendsOf should block, but we should still get the
  -- "xxx" exception.
  r <- runHaxl env $ try haxl
  assertBool "exceptionTest3" $
    case r of
     Left (NotFound "xxx") -> True
     _ -> False
  -- the second time, friendsOf will be cached, and we should get the "xxx"
  -- exception as before.
  r <- runHaxl env $ try haxl
  assertBool "exceptionTest3" $
    case r of
     Left (NotFound "xxx") -> True
     _ -> False
