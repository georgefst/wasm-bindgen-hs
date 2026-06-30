{-# LANGUAGE CPP #-}

module Main (main) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time (getCurrentTime)
import Data.Word
import Lib

#ifdef wasi_HOST_OS
import GHC.Wasm.Prim
#endif

main :: IO ()
main = pure ()

-- IO with unit return
logMessage :: Text -> IO ()
logMessage = T.putStrLn
$(exportJS Async 'logMessage)

-- IO with Text return
greet :: Text -> IO Text
greet name = do
    t <- getCurrentTime
    pure $ "Hello, " <> name <> "! The time is: " <> T.show t
$(exportJS Async 'greet)

-- Pure, multiple Text args
greetManyPure :: Text -> Text -> Text -> Text
greetManyPure name1 name2 name3 = "Hello, " <> name1 <> ", " <> name2  <> " and " <> name3 <> "!"
$(exportJS Async 'greetManyPure)

-- Natively marshalable types, sync
addByte :: Word8 -> Word8 -> Word8
addByte = (+)
$(exportJS Sync 'addByte)

-- Float/Double
multiplyDouble :: Double -> Double -> Double
multiplyDouble = (*)
$(exportJS Sync 'multiplyDouble)

-- Bool
negateBool :: Bool -> Bool
negateBool = not
$(exportJS Sync 'negateBool)

-- No args, pure
theAnswer :: Word64
theAnswer = 4815162342
$(exportJS Sync 'theAnswer)
