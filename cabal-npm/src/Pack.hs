{-# LANGUAGE MultilineStrings #-}

module Pack (
    PackConfig (..),
    pack,
) where

import Control.Exception (bracket_)
import Control.Monad (when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isDigit)
import Data.List (isPrefixOf, isSuffixOf, sort, tails)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import System.Directory (copyFile, createDirectoryIfMissing, findExecutable, listDirectory, removeFile)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (dropExtension, (</>))
import Runtime (runtimeMjs)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), callProcess, proc, readCreateProcess, readProcess, waitForProcess, withCreateProcess)

data PackConfig = PackConfig
    { cabalTarget :: Text
    -- ^ Cabal executable component name, e.g. "example"
    , packageName :: Text
    -- ^ NPM package name, e.g. "wasm-bindgen-hs-example"
    , packageVersion :: Text
    -- ^ NPM package version, e.g. "0.1.0"
    , outDir :: FilePath
    -- ^ Output directory for the assembled NPM package
    , wasiShimVersion :: Text
    -- ^ Version constraint for @bjorn3/browser_wasi_shim, e.g. "^0.4.2"
    }

-- | Marker file read by the TH splices in @Wasm.Export@, naming the directory
-- where they write @.d.ts@ fragments. A file rather than an environment
-- variable, since GHC's Wasm external interpreter (where TH runs) does not
-- inherit the host environment.
tsOutDirFile :: FilePath
tsOutDirFile = ".wasm-bindgen-hs-ts-out-dir"

pack :: PackConfig -> IO ()
pack PackConfig{..} = withSystemTempDirectory "cabal-npm" \tmpDir -> do
    let -- A fresh build directory guarantees a clean build, so TH always
        -- reruns and the .d.ts fragments can never be stale. Using our own
        -- build directory also keeps ordinary dev builds' caches intact.
        buildDirFlag = T.pack $ "--builddir=" <> (tmpDir </> "dist")
        tsOutDir = tmpDir </> "ts"
    createDirectoryIfMissing True tsOutDir
    wasmCabal <- getWasmCabal

    -- Build the wasm binary, with TH writing .d.ts fragments to tsOutDir
    T.putStrLn $ "Building " <> cabalTarget <> "..."
    bracket_
        (writeFile tsOutDirFile tsOutDir)
        (removeFile tsOutDirFile)
        (callWasmCabal wasmCabal ["build", cabalTarget, buildDirFlag])

    -- Locate the built wasm binary
    wasmBin <- T.unpack <$> readWasmCabal wasmCabal ["list-bin", cabalTarget, buildDirFlag]

    -- Locate GHC libdir for post-link.mjs
    ghcLibdir <- T.unpack <$> runRead "wasm32-unknown-wasi-ghc" ["--print-libdir"]
    let postLink = ghcLibdir </> "post-link.mjs"

    -- Create output directory
    createDirectoryIfMissing True outDir

    -- Run post-link to generate the JS FFI shim
    let jsffiOut = outDir </> "ghc_wasm_jsffi.js"
    T.putStrLn "Running post-link..."
    run postLink ["--input", T.pack wasmBin, "--output", T.pack jsffiOut]

    -- Copy the wasm binary
    let wasmOut = outDir </> T.unpack cabalTarget <> ".wasm"
    putStrLn $ "Copying " <> wasmBin <> " -> " <> wasmOut
    copyFile wasmBin wasmOut

    -- Write out the generic runtime (for now identical for every package;
    -- we may generate it per-target eventually)
    T.writeFile (outDir </> "runtime.mjs") runtimeMjs

    -- Read export names from the generated .d.ts fragment filenames
    exportNames <- getExportNames tsOutDir
    when (null exportNames) $
        fail $
            "no .d.ts fragments were generated; does " <> T.unpack cabalTarget <> " have any Wasm.Export splices?"

    -- Assemble type declarations from the TH-generated fragments
    declarations <- assembleDeclarations tsOutDir exportNames
    T.writeFile (outDir </> "index.d.ts") declarations
    T.writeFile (outDir </> "index.d.mts") declarations

    -- Generate index.mjs with re-exports
    T.writeFile (outDir </> "index.mjs") $ generateIndexMjs cabalTarget exportNames

    -- Generate package.json
    LBS.writeFile (outDir </> "package.json") $ Aeson.encodePretty packageJson <> "\n"

    putStrLn $ "NPM package assembled in " <> outDir <> "/"
  where
    packageJson =
        Aeson.object
            [ "name" .= packageName
            , "version" .= packageVersion
            , "type" .= ("module" :: Text)
            , "main" .= ("index.mjs" :: Text)
            , "types" .= ("index.d.ts" :: Text)
            , "files"
                .= ( [ "index.mjs" :: Text
                     , "index.d.ts"
                     , "index.d.mts"
                     , "runtime.mjs"
                     , cabalTarget <> ".wasm"
                     , "ghc_wasm_jsffi.js"
                     ]
                   )
            , "dependencies"
                .= Aeson.object
                    [ "@bjorn3/browser_wasi_shim" .= wasiShimVersion
                    ]
            , "devDependencies"
                .= Aeson.object
                    [ "typescript" .= ("^6" :: Text)
                    , "@types/node" .= ("^26" :: Text)
                    ]
            ]

getExportNames :: FilePath -> IO [Text]
getExportNames dir = do
    files <- listDirectory dir
    pure $ sort [T.pack $ dropExtension $ dropExtension f | f <- files, ".d.ts" `isSuffixOf` f]

assembleDeclarations :: FilePath -> [Text] -> IO Text
assembleDeclarations srcDir names = do
    decls <- traverse (\n -> T.readFile $ srcDir </> T.unpack n <> ".d.ts") names
    pure $ "export function init(): Promise<void>;\n" <> mconcat decls

generateIndexMjs :: Text -> [Text] -> Text
generateIndexMjs wasmFile names =
    -- NB. multiline strings can't express the trailing blank line
    T.replace "WASM_FILE" wasmFile template <> "\n" <> T.unlines (map mkExport names)
  where
    template =
        """
        import { init as _init } from "./runtime.mjs";

        let _exports;

        export async function init() {
          _exports = await _init("WASM_FILE.wasm");
        }

        function _call(name, args) {
          if (!_exports) throw new Error(`call "await init()" before using "${name}"`);
          return _exports[name](...args);
        }

        """
    mkExport name = "export const " <> name <> " = (...args) => _call(\"" <> name <> "\", args);"

-- | How to invoke cabal for cross-compiling to Wasm.
data WasmCabal = WasmCabal
    { exe :: FilePath
    , globalFlags :: [Text]
    , processEnv :: [(String, String)]
    }

-- | Configure a cabal invocation for the wasm32-wasi cross toolchain. Uses
-- the cabal that invoked us where possible ($CABAL_EXTERNAL_CABAL_PATH is set
-- when we're run as `cabal npm` via cabal's external command system), and
-- passes the toolchain flags itself, mirroring haskell.nix's
-- @wasm32-unknown-wasi-cabal@ wrapper.
getWasmCabal :: IO WasmCabal
getWasmCabal = do
    exe <- fromMaybe "cabal" <$> lookupEnv "CABAL_EXTERNAL_CABAL_PATH"
    pkgConfig <- findExecutable "wasm32-unknown-wasi-pkg-config"
    processEnv <- map fixNixLdflags <$> getEnvironment
    pure
        WasmCabal
            { exe
            , globalFlags =
                [ "--with-ghc=wasm32-unknown-wasi-ghc"
                , "--with-compiler=wasm32-unknown-wasi-ghc"
                , "--with-ghc-pkg=wasm32-unknown-wasi-ghc-pkg"
                , "--with-hsc2hs=wasm32-unknown-wasi-hsc2hs"
                ]
                    <> ["--with-pkg-config=wasm32-unknown-wasi-pkg-config" | isJust pkgConfig]
            , processEnv
            }
  where
    -- Keep the Wasm toolchain's libffi out of native builds (e.g. of Setup.hs)
    -- by stripping it from NIX_LDFLAGS_FOR_TARGET, mirroring the wasm-cabal
    -- wrapper in flake.nix. A no-op outside the Nix dev shell.
    fixNixLdflags = \case
        ("NIX_LDFLAGS_FOR_TARGET", v) ->
            ("NIX_LDFLAGS_FOR_TARGET", unwords $ filter (not . mentionsLibffi) $ words v)
        kv -> kv
    libffiPrefix = "libffi-" :: String
    mentionsLibffi w =
        any
            (\s -> libffiPrefix `isPrefixOf` s && maybe False isDigit (listToMaybe $ drop (length libffiPrefix) s))
            (tails w)

wasmCabalProc :: WasmCabal -> [Text] -> CreateProcess
wasmCabalProc cabal args =
    (proc cabal.exe (map T.unpack $ cabal.globalFlags <> args)){env = Just cabal.processEnv}

-- | Run wasm cabal, inheriting stdout/stderr, throwing on nonzero exit.
callWasmCabal :: WasmCabal -> [Text] -> IO ()
callWasmCabal cabal args = do
    exitCode <-
        withCreateProcess (wasmCabalProc cabal args){delegate_ctlc = True} \_ _ _ -> waitForProcess
    case exitCode of
        ExitSuccess -> pure ()
        ExitFailure code ->
            fail $ unwords (cabal.exe : map T.unpack args) <> " failed with exit code " <> show code

-- | Run wasm cabal, capturing (whitespace-trimmed) stdout, throwing on nonzero exit.
readWasmCabal :: WasmCabal -> [Text] -> IO Text
readWasmCabal cabal args = T.strip . T.pack <$> readCreateProcess (wasmCabalProc cabal args) ""

-- | Run a process, inheriting stdout/stderr, throwing on nonzero exit.
run :: FilePath -> [Text] -> IO ()
run cmd = callProcess cmd . map T.unpack

-- | Run a process, capturing (whitespace-trimmed) stdout, throwing on nonzero exit.
runRead :: FilePath -> [Text] -> IO Text
runRead cmd args = T.strip . T.pack <$> readProcess cmd (map T.unpack args) ""
