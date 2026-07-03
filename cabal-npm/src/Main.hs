{-# LANGUAGE ApplicativeDo #-}

module Main (main) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
import Pack (PackConfig (..), pack)
import System.Environment (getArgs)

main :: IO ()
main = do
    args <- dropCommandName <$> getArgs
    pack =<< handleParseResult (execParserPure defaultPrefs parserInfo args)
  where
    -- cabal's external command system passes the command name as the first
    -- argument in some contexts, e.g. `cabal help npm` invokes
    -- `cabal-npm npm --help`
    dropCommandName = \case
        "npm" : args -> args
        args -> args

parserInfo :: ParserInfo PackConfig
parserInfo =
    info
        (helper <*> packConfig)
        ( fullDesc
            <> progDesc "Package a GHC Wasm executable as an NPM package"
        )

packConfig :: Parser PackConfig
packConfig = do
    cabalTarget <-
        argument str $
            metavar "TARGET"
                <> help "Cabal executable component to build"
    packageName <-
        optional . strOption @Text $
            long "package-name"
                <> metavar "NAME"
                <> help "NPM package name (default: TARGET)"
    packageVersion <-
        strOption $
            long "package-version"
                <> metavar "VERSION"
                <> value "0.1.0"
                <> showDefaultWith T.unpack
                <> help "NPM package version"
    outDir <-
        optional . strOption @FilePath $
            long "out-dir"
                <> metavar "DIR"
                <> help "Output directory for the assembled NPM package (default: TARGET-npm)"
    wasiShimVersion <-
        strOption $
            long "wasi-shim-version"
                <> metavar "RANGE"
                <> value "^0.4.2"
                <> showDefaultWith T.unpack
                <> help "Version constraint for @bjorn3/browser_wasi_shim"
    wasmCabal <-
        optional . strOption @Text $
            long "wasm-cabal"
                <> metavar "CMD"
                <> help
                    "A cabal command already configured for the Wasm toolchain, \
                    \e.g. ghc-wasm-meta's wasm32-wasi-cabal (default: the invoking \
                    \cabal, pointed at the toolchain programs found on PATH)"
    pure
        PackConfig
            { packageName = fromMaybe cabalTarget packageName
            , outDir = fromMaybe (T.unpack cabalTarget <> "-npm") outDir
            , ..
            }
