{-# LANGUAGE TypeFamilies, FlexibleInstances #-}
-- | Wrapper around Data.IntMap that guarantees elements are evaluated when
-- the Map is. containers-0.5 provides this out of the box, but alas ghc 7.4
-- is built against containers-0.4.
{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}
module IdeSession.Strict.IntMap (
    fromList
  , toList
  , (!)
  , empty
  , adjust
  , insertWith
  , map
  ) where

import Prelude hiding (map)
import qualified Data.IntMap as IntMap

import IdeSession.Strict.Container

(!) :: Strict IntMap v -> Int -> v
(!) = (IntMap.!) . toLazyIntMap

fromList :: [(Int, v)] -> Strict IntMap v
fromList = force . IntMap.fromList

toList :: Strict IntMap v -> [(Int, v)]
toList = IntMap.toList . toLazyIntMap

empty :: Strict IntMap v
empty = StrictIntMap $ IntMap.empty

-- We use alter because it gives us something to anchor a seq to
adjust :: forall v. (v -> v) -> Int -> Strict IntMap v -> Strict IntMap v
adjust f i = StrictIntMap . IntMap.alter aux i . toLazyIntMap
  where
    aux :: Maybe v -> Maybe v
    aux Nothing  = Nothing
    aux (Just v) = let v' = f v in v' `seq` Just v'

insertWith :: (v -> v -> v) -> Int -> v -> Strict IntMap v -> Strict IntMap v
insertWith f i v = StrictIntMap . IntMap.insertWith' f i v . toLazyIntMap

map :: (a -> b) -> Strict IntMap a -> Strict IntMap b
map f = force . IntMap.map f . toLazyIntMap