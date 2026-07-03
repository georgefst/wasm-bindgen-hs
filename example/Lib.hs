{-# LANGUAGE CPP #-}

module Lib where

import Data.Function
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time (getCurrentTime)
import Data.Word
import Foreign.StablePtr
import Wasm.Export

#ifdef wasi_HOST_OS
import GHC.Wasm.Prim
#endif

-- IO with unit return
logMessage :: Text -> IO ()
logMessage = T.putStrLn
$(exportDeclJS Async 'logMessage)

-- Pure, multiple Text args
greetManyPure :: Text -> Text -> Text -> Text
greetManyPure name1 name2 name3 = "Hello, " <> name1 <> ", " <> name2 <> " and " <> name3 <> "!"
$(exportDeclJS Async 'greetManyPure)

-- Natively marshalable types, sync
addByte :: Word8 -> Word8 -> Word8
addByte = (+)
$(exportDeclJS Sync 'addByte)

-- Float/Double
multiplyDouble :: Double -> Double -> Double
multiplyDouble = (*)
$(exportDeclJS Sync 'multiplyDouble)

-- Bool
negateBool :: Bool -> Bool
negateBool = not
$(exportDeclJS Sync 'negateBool)

-- No args, pure
theAnswer :: Word64
theAnswer = 4815162342
$(exportDeclJS Sync 'theAnswer)

-- Sieve of Eratosthenes, returning a list
data InfList a = InfList a (InfList a)
primesUpTo :: Int -> [Int]
primesUpTo n = take n $ toListInf primes
  where
    primes = sieve $ enumFromInf (2 :: Int)
    sieve (InfList p ps) = InfList p $ sieve $ filterInf ((/= 0) . (`mod` p)) ps
    enumFromInf x = InfList x $ enumFromInf (x + 1)
    toListInf (InfList x xs) = x : toListInf xs
    filterInf f (InfList x xs) = applyWhen (f x) (InfList x) $ filterInf f xs
$(exportDeclJS Sync 'primesUpTo)

-- Opaque Haskell value, passed to JS as a StablePtr
-- a `free_Counter` export is generated automatically
data Counter = Counter Text (IORef Int)
newCounter :: Text -> IO (StablePtr Counter)
newCounter name = newStablePtr . Counter name =<< newIORef 0
$(exportDeclJS Async 'newCounter)
incrementCounter :: StablePtr Counter -> IO Int
incrementCounter ptr = do
    Counter _ ref <- deRefStablePtr ptr
    modifyIORef' ref (+ 1)
    readIORef ref
$(exportDeclJS Async 'incrementCounter)
describeCounter :: StablePtr Counter -> IO Text
describeCounter ptr = do
    Counter name ref <- deRefStablePtr ptr
    count <- readIORef ref
    pure $ name <> ": " <> T.show count
$(exportDeclJS Async 'describeCounter)

-- Lists of converted types, and nested lists
chunkWords :: Int -> Text -> [[Text]]
chunkWords n = go . T.words
  where
    go [] = []
    go ws = let (xs, rest) = splitAt n ws in xs : go rest
$(exportDeclJS Sync 'chunkWords)

-- Anonymous
$(exportJS Sync "addInt" [||(+) @Int||])
$(exportJS Async "replicateText" [||T.replicate||])
$(exportJS Sync "getCurrentTimeText" [||T.show <$> getCurrentTime||])
$(exportJS
    Async
    "greet"
    [||
    \name -> do
        t <- getCurrentTime
        pure $ "Hello, " <> name <> "! The time is: " <> T.show t
    ||]
 )
