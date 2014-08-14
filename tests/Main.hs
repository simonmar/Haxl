{-# LANGUAGE RebindableSyntax, OverloadedStrings #-}
module Main where

import TestExampleDataSource
import BatchTests
import CoreTests
import DataCacheTest
import FullyAsyncTest

import Data.String
import Test.HUnit

import Haxl.Prelude

main :: IO Counts
main = runTestTT $ TestList
  [ TestLabel "ExampleDataSource" TestExampleDataSource.tests
  , TestLabel "BatchTests" $ BatchTests.tests True
  , TestLabel "BatchTests" $ BatchTests.tests False
  , TestLabel "CoreTests" CoreTests.tests
  , TestLabel "DataCacheTests" DataCacheTest.tests
  , TestLabel "FullyAsyncTest" FullyAsyncTest.tests
  ]
