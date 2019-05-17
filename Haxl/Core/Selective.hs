-- |
-- Selective functors.
-- See: https://github.com/snowleopard/selective
--
module Haxl.Core.Selective
  (
    -- * Selective functors
    Selective (..)
  , branch
  , race
  , ifS
  , selectA
  , selectM
  , (<||>)
  , (<&&>)
  ) where

import Data.Bool
import Data.Void

-- -----------------------------------------------------------------------------
-- Selective applicative functors

-- | Selective applicative functors.
-- See https://www.staff.ncl.ac.uk/andrey.mokhov/selective-functors.pdf.
class Applicative f => Selective f where
    biselect :: f (Either a b) -> f (Either a c) -> f (Either a (b, c))

(?*?) :: Selective f => f (Either a b) -> f (Either a c) -> f (Either a (b, c))
(?*?) = biselect

select :: Selective f => f (Either a b) -> f (a -> b) -> f b
select x y = either id (\(a, f) -> f a) <$> (fmap swapEither x ?*? fmap Right y)

-- | Swap @Left@ and @Right@.
swapEither :: Either a b -> Either b a
swapEither = either Right Left

-- | Pick one of the values according to the semantics of the Selective
-- instance. This is a semigroup due to the associativity of 'biselect'.
race :: Selective f => f a -> f a -> f a
race x y = either id (absurd . fst) <$> (fmap Left x ?*? fmap Left y)

-- | An operator alias for 'select', which is sometimes convenient. It tries to
-- follow the notational convention for 'Applicative' operators. The angle
-- bracket pointing to the left means we always use the corresponding value.
-- The value on the right, however, may be skipped, hence the question mark.
(<*?) :: Selective f => f (Either a b) -> f (a -> b) -> f b
(<*?) = select

infixl 4 <*?

-- | We can write a function with the type signature of 'select' using the
-- 'Applicative' type class, but it will always execute the effects associated
-- with the second argument, hence being potentially less efficient.
selectA :: Applicative f => f (Either a b) -> f (a -> b) -> f b
selectA x f = (\e f -> either f id e) <$> x <*> f

-- | One can easily implement a monadic 'selectM' that satisfies the laws,
-- hence any 'Monad' is 'Selective'.
selectM :: Monad f => f (Either a b) -> f (a -> b) -> f b
selectM mx mf = do
    x <- mx
    case x of
        Left  a -> fmap ($a) mf
        Right b -> pure b

-- | The 'branch' function is a natural generalisation of 'select': instead of
-- skipping an unnecessary effect, it chooses which of the two given effectful
-- functions to apply to a given argument; the other effect is unnecessary. It
-- is possible to implement 'branch' in terms of 'select', which is a good
-- puzzle (give it a try!).
branch :: Selective f => f (Either a b) -> f (a -> c) -> f (b -> c) -> f c
branch x l r = fmap (fmap Left) x <*? fmap (fmap Right) l <*? r

-- | Branch on a Boolean value, skipping unnecessary effects.
ifS :: Selective f => f Bool -> f a -> f a -> f a
ifS i t e = branch (boolToEither <$> i) (const <$> t) (const <$> e)
  where
    boolToEither = bool (Right ()) (Left ())

-- | A lifted version of lazy Boolean OR.
(<||>) :: Selective f => f Bool -> f Bool -> f Bool
(<||>) x y = either (const True) (const False) <$>
    biselect (boolToEither <$> x) (boolToEither <$> y)
  where
    boolToEither = bool (Right ()) (Left ())

-- | A lifted version of lazy Boolean AND.
(<&&>) :: Selective f => f Bool -> f Bool -> f Bool
(<&&>) x y = either (const False) (const True) <$>
    biselect (boolToEither <$> x) (boolToEither <$> y)
  where
    boolToEither = bool (Left ()) (Right ())
