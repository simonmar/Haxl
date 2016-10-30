module FullyAsyncTest where

import Haxl.Prelude as Haxl
import Prelude()

import SleepDataSource

import Haxl.Core
import Test.HUnit
import Data.IORef
import Haxl.Core.Monad (unsafeLiftIO)

tests :: Test
tests = sleepTest

testEnv = do
  st <- SleepDataSource.initGlobalState
  initEnv (stateSet st stateEmpty) ()

sleepTest :: Test
sleepTest = TestCase $ do
  env <- testEnv

  ref <- newIORef ([] :: [Int])
  let tick n = unsafeLiftIO (modifyIORef ref (n:))

  -- simulate running a selection of data fetches that complete at
  -- different times, overlapping them as much as possible.
  x <- runHaxl env $
    sequence
       [ sequence_ [sleep 100, sleep 400] `andThen` tick 5     -- A
       , sleep 100 `andThen` tick 2 `andThen` sleep 200 `andThen` tick 4    -- B
       , sleep 50 `andThen` tick 1 `andThen` sleep 150 `andThen` tick 3     -- C
       ]

  ys <- readIORef ref
  assertEqual "FullyAsyncTest: ordering" [1,2,3,4,5] (reverse ys)

andThen :: GenHaxl u a -> GenHaxl u b -> GenHaxl u b
andThen a b = a >>= \_ -> b

{-
           A         B         C
50          |        |       tick 1
100         |     tick 2       |
150         |        |         |
200         |        |       tick 3
250         |        |
300         |     tick 4
350         |
400         |
450         |
500      tick 5
-}

