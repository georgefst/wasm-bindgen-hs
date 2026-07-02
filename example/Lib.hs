{-# LANGUAGE CPP #-}

module Lib where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time (getCurrentTime)
import Data.Word
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
