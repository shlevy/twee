-- | Assignment of unique IDs to values.
-- Inspired by the 'intern' package.

{-# LANGUAGE RecordWildCards, ScopedTypeVariables, BangPatterns #-}
module Twee.Label(Label, unsafeMkLabel, labelNum, label, find) where

import Data.IORef
import System.IO.Unsafe
import qualified Data.Map.Strict as Map
import Data.Map.Strict(Map)
import qualified Data.IntMap.Strict as IntMap
import Data.IntMap.Strict(IntMap)
import Data.Typeable
import GHC.Exts
import Unsafe.Coerce
import Data.Int

newtype Label a = Label { labelNum :: Int32 }
  deriving (Eq, Ord, Show)
unsafeMkLabel :: Int32 -> Label a
unsafeMkLabel = Label

type Cache a = Map a Int32

data Caches =
  Caches {
    caches_nextId :: {-# UNPACK #-} !Int32,
    caches_from   :: !(Map TypeRep (Cache Any)),
    caches_to     :: !(IntMap Any) }

{-# NOINLINE cachesRef #-}
cachesRef :: IORef Caches
cachesRef = unsafePerformIO (newIORef (Caches 0 Map.empty IntMap.empty))

atomicModifyCaches :: (Caches -> (Caches, a)) -> IO a
atomicModifyCaches f = do
  -- N.B. atomicModifyIORef' ref f evaluates f ref *after* doing the
  -- compare-and-swap. This causes bad things to happen when 'label'
  -- is used reentrantly (i.e. the Ord instance itself calls label).
  -- This function only lets the swap happen if caches_nextId didn't
  -- change (i.e., no new values were inserted).
  !caches <- readIORef cachesRef
  -- First compute the update.
  let !(!caches', !x) = f caches
  -- Now see if anyone else updated the cache in between
  -- (can happen if f called 'label', or in a concurrent setting).
  ok <- atomicModifyIORef' cachesRef $ \cachesNow ->
    if caches_nextId caches == caches_nextId cachesNow
    then (caches', True)
    else (cachesNow, False)
  if ok then return x else atomicModifyCaches f

toAnyCache :: Cache a -> Cache Any
toAnyCache = unsafeCoerce

fromAnyCache :: Cache Any -> Cache a
fromAnyCache = unsafeCoerce

toAny :: a -> Any
toAny = unsafeCoerce

fromAny :: Any -> a
fromAny = unsafeCoerce

{-# NOINLINE label #-}
label :: forall a. (Typeable a, Ord a) => a -> Label a
label x =
  unsafeDupablePerformIO $ do
    -- Common case: label is already there.
    caches <- readIORef cachesRef
    case tryFind caches of
      Just l -> return l
      Nothing -> do
        -- Rare case: label was not there.
        x <- atomicModifyCaches $ \caches ->
          case tryFind caches of
            Just l -> (caches, l)
            Nothing ->
              insert caches
        return x

  where
    ty = typeOf x

    tryFind :: Caches -> Maybe (Label a)
    tryFind Caches{..} =
      Label <$> (Map.lookup ty caches_from >>= Map.lookup x . fromAnyCache)

    insert :: Caches -> (Caches, Label a)
    insert caches@Caches{..} =
      if n < 0 then error "label overflow" else
      (caches {
         caches_nextId = n+1,
         caches_from = Map.insert ty (toAnyCache (Map.insert x n cache)) caches_from,
         caches_to = IntMap.insert (fromIntegral n) (toAny x) caches_to },
       Label n)
      where
        n = caches_nextId
        cache =
          fromAnyCache $
          Map.findWithDefault Map.empty ty caches_from

find :: Label a -> a
-- N.B. must force n before calling readIORef, otherwise a call of
-- the form
--   find (label x)
-- doesn't work.
find (Label !n) = unsafeDupablePerformIO $ do
  Caches{..} <- readIORef cachesRef
  x <- return $! fromAny (IntMap.findWithDefault undefined (fromIntegral n) caches_to)
  return x
