-- Necessary:
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RebindableSyntax #-}

-- Incidental:
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Main where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif
import Haxl.Prelude
import Control.Monad (replicateM, unless)
import Data.Bool
import Data.Hashable
import Data.List
import Data.Text (Text)
import Data.Traversable (for)
import Data.Typeable
import Haxl.Core
import Haxl.Core.DataSource
import Haxl.Core.Monad
import System.Random

import qualified Data.Text as Text

main :: IO ()
main = do
  let stateStore = stateSet UserState{} stateEmpty
  env0 <- initEnv stateStore ()
  print    =<< runHaxl env0 getSomeUserIfS
--   putStrLn =<< runHaxl env0 dumpCacheAsHaskell

-- Data source API.

getAllUsernames :: Haxl [Name]
getAllUsernames = do
  userIds <- getAllUserIds
  for userIds $ \userId -> do
    getUsernameById userId

getAllUserIds :: Haxl [Id]
getAllUserIds = dataFetch GetAllIds

getUsernameById :: Id -> Haxl Name
getUsernameById userId = dataFetch (GetNameById userId)

sendMessage :: Id -> Message -> Haxl ()
sendMessage userId msg = dataFetch (SendMessage userId msg)

--------------------------------------------------------------------------------
get :: Int -> Haxl Name
get = noisyGet

quietGet :: Int -> Haxl Name
quietGet k = do
    userIds <- getAllUserIds
    getUsernameById (userIds !! k)

noisyGet :: Int -> Haxl Name
noisyGet k = do
    userIds <- getAllUserIds
    name <- getUsernameById (userIds !! k)
    sendMessage k ("Hello " <> name)
    return name

getSomeUser :: Haxl Name
getSomeUser = do
    name <- get 0
    if name > "Jim50" then get 1 else get 2

getSomeUserHaxlIf :: Haxl Name
getSomeUserHaxlIf = if get 0 .> "Jim50" then get 1 else get 2

getSomeUserIfS :: Haxl Name
getSomeUserIfS = ifS (get 0 .> "Jim50") (get 1) (get 2)

getSomeUserIfA :: Haxl Name
getSomeUserIfA = ifA (get 0 .> "Jim50") (get 1) (get 2)

ifA :: Applicative f => f Bool -> f a -> f a -> f a
ifA fx ft ff = ifThenElse <$> fx <*> ft <*> ff
--------------------------------------------------------------------------------

-- Aliases.

type Haxl = GenHaxl () ()
type Id = Int
type Name = Text
type Message = Text

-- Data source implementation.

data UserReq a where
  GetAllIds   :: UserReq [Id]
  GetNameById :: Id -> UserReq Name
  SendMessage :: Id -> Message -> UserReq ()
  deriving (Typeable)

deriving instance Eq (UserReq a)
instance Hashable (UserReq a) where
   hashWithSalt s GetAllIds         = hashWithSalt s (0::Int)
   hashWithSalt s (GetNameById a)   = hashWithSalt s (1::Int, a)
   hashWithSalt s (SendMessage a b) = hashWithSalt s (2::Int, a, b)

deriving instance Show (UserReq a)
instance ShowP UserReq where showp = show

instance StateKey UserReq where
  data State UserReq = UserState {}

instance DataSourceName UserReq where
  dataSourceName _ = "UserDataSource"

instance DataSource u UserReq where
  fetch _state _flags _userEnv = SyncFetch $ \blockedFetches -> do
    let
      allIdVars :: [ResultVar [Id]]
      allIdVars = [r | BlockedFetch _necessary GetAllIds r <- blockedFetches]

      idStrings :: [String]
      idStrings = map show ids

      ids :: [Id]
      vars :: [ResultVar Name]
      (ids, vars) = unzip
        [(userId, r) | BlockedFetch _necessary (GetNameById userId) r <- blockedFetches]

      allMsgs :: [(Id, Message, Necessary)]
      msgVars :: [ResultVar ()]
      (allMsgs, msgVars) = unzip
        [((userId, msg, necessary), r)
        | BlockedFetch necessary (SendMessage userId msg) r <- blockedFetches ]
      retries :: [BlockedFetch UserReq]
      retries = [ BlockedFetch Speculative (SendMessage userId msg) r
                | BlockedFetch Speculative (SendMessage userId msg) r <- blockedFetches ]

    unless (null allIdVars) $ do
      allIds <- sql "select id from ids"
      mapM_ (\r -> putSuccess r allIds) allIdVars

    unless (null ids) $ do
      names <- sql $ unwords
        [ "select name from names where"
        , intercalate " or " $ map ("id = " ++) idStrings
        , "order by find_in_set(id, '" ++ intercalate "," idStrings ++ "')"
        ]
      mapM_ (uncurry putSuccess) (zip vars names)

    unless (null allMsgs) $ do
      forM_ allMsgs $ \(id, msg, necessary) -> do
        let s | necessary == Necessary = " necessary "
              | otherwise              = " speculative "
        putStrLn $ "Sending" ++ s ++ "'" ++ Text.unpack msg ++ "' to user " ++ show id
      mapM_ (\v -> putSuccess v ()) msgVars

    -- return retries

-- Mock SQL API.

class SQLResult a where
  mockResult :: IO a

instance SQLResult a => SQLResult [a] where
  mockResult = replicateM 10 mockResult

instance SQLResult Name where
  -- An infinite number of employees, all named Jim.
  mockResult = ("Jim" `Text.append`) . Text.pack . show <$> randomRIO (1::Int, 100)

instance SQLResult Id where
  mockResult = randomRIO (1, 100)

sql :: SQLResult a => String -> IO a
sql query = print query >> mockResult
