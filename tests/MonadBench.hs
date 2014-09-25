module MonadBench (main) where

import System.Environment
import Data.Time.Clock
import Control.Monad
import Text.Printf

import Haxl.Prelude as Haxl
import Prelude()

import Haxl.Core

import ExampleDataSource

testEnv :: IO (Env ())
testEnv = do
  exstate <- ExampleDataSource.initGlobalState
  let st = stateSet exstate stateEmpty
  initEnv st ()

main = do
  [test,n_] <- getArgs
  let n = read n_
  env <- testEnv
  t0 <- getCurrentTime
  case test of
    "par1" -> runHaxl env $ Haxl.sequence_ (replicate n (listWombats 3))
    "par2" -> runHaxl env $ Haxl.sequence_ (map listWombats [1..fromIntegral n])
    "seq1" -> runHaxl env $ replicateM_ n (listWombats 3)
    "seq2" -> runHaxl env $ foldl (>>)  (return []) (map listWombats [1.. fromIntegral n]) >> return ()
    "tree" -> runHaxl env $ tree n >> return ()
  t1 <- getCurrentTime
  printf "%d reqs: %.2fs\n" n (realToFrac (t1 `diffUTCTime` t0) :: Double)

tree :: Int -> GenHaxl () [Id]
tree 0 = listWombats 0
tree n = concat <$> Haxl.sequence [tree (n-1), listWombats (fromIntegral n), tree (n-1)]

