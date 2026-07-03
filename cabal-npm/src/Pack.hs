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
import Data.List (isPrefixOf, isSuffixOf, nub, partition, sort, sortOn, tails)
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Runtime (runtimeMjs)
import System.Directory (copyFile, createDirectoryIfMissing, findExecutable, listDirectory, removeFile)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), callProcess, proc, readCreateProcess, readProcess, waitForProcess, withCreateProcess)
import TS.AST qualified as TS
import TS.Serialize (serializeDecl, serializeOpaqueClassDecl)

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
    , wasmCabal :: Maybe Text
    -- ^ A cabal command already configured for the Wasm toolchain, e.g.
    -- ghc-wasm-meta's @wasm32-wasi-cabal@. When absent, the invoking cabal is
    -- reused with @--with-ghc@ flags for the toolchain programs on PATH.
    }

-- | Marker file read by the TH splices in @Wasm.Export@, naming the directory
-- where they write declaration fragments. A file rather than an environment
-- variable, since GHC's Wasm external interpreter (where TH runs) does not
-- inherit the host environment.
tsOutDirFile :: FilePath
tsOutDirFile = ".wasm-bindgen-hs-ts-out-dir"

pack :: PackConfig -> IO ()
pack PackConfig{..} = withSystemTempDirectory "cabal-npm" \tmpDir -> do
    let -- A fresh build directory guarantees a clean build, so TH always
        -- reruns and the declaration fragments can never be stale. Using our
        -- own build directory also keeps ordinary dev builds' caches intact.
        buildDirFlag = T.pack $ "--builddir=" <> (tmpDir </> "dist")
        tsOutDir = tmpDir </> "ts"
    createDirectoryIfMissing True tsOutDir
    cabal <- getWasmCabal wasmCabal

    -- Build the wasm binary, with TH writing declaration fragments to tsOutDir
    T.putStrLn $ "Building " <> cabalTarget <> "..."
    bracket_
        (writeFile tsOutDirFile tsOutDir)
        (removeFile tsOutDirFile)
        (callWasmCabal cabal ["build", cabalTarget, buildDirFlag])

    -- Locate the built wasm binary. The path is the last line of the output:
    -- cabal (or git subprocesses it spawns, e.g. when syncing
    -- source-repository-packages) may print progress messages first.
    wasmBin <-
        T.unpack . snd . T.breakOnEnd "\n"
            <$> readWasmCabal cabal ["list-bin", cabalTarget, buildDirFlag]

    -- Locate GHC libdir for post-link.mjs
    wasmGhc <- getWasmGhc
    ghcLibdir <- T.unpack <$> runRead wasmGhc ["--print-libdir"]
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

    -- Write out the runtime
    T.writeFile (outDir </> "runtime.mjs") $ runtimeMjs $ cabalTarget <> ".wasm"

    -- Read export declarations from the TH-generated fragments
    decls <- readDecls tsOutDir
    when (null decls) $
        fail $
            "no declaration fragments were generated; does " <> T.unpack cabalTarget <> " have any Wasm.Export splices?"
    let bindings = analyseBindings decls

    -- Assemble type declarations
    T.writeFile (outDir </> "index.d.ts") $ generateDeclarations bindings
    T.writeFile (outDir </> "index.d.mts") $ generateDeclarations bindings

    -- Generate index.mjs
    T.writeFile (outDir </> "index.mjs") $ generateIndexMjs bindings

    -- Generate package.json
    LBS.writeFile (outDir </> "package.json") $ Aeson.encodePretty' packageJsonFormat packageJson <> "\n"

    putStrLn $ "NPM package assembled in " <> outDir <> "/"
  where
    -- Order matters in "exports": conditions are tried in object order, so
    -- "types" must precede "default". The other keys are just conventional.
    packageJsonFormat =
        Aeson.defConfig
            { Aeson.confCompare =
                Aeson.keyOrder
                    [ "name"
                    , "version"
                    , "type"
                    , "main"
                    , "types"
                    , "exports"
                    , "files"
                    , "dependencies"
                    , "devDependencies"
                    , "default"
                    ]
                    <> compare
            }
    packageJson =
        Aeson.object
            [ "name" .= packageName
            , "version" .= packageVersion
            , "type" .= ("module" :: Text)
            , "main" .= ("index.mjs" :: Text)
            , "types" .= ("index.d.ts" :: Text)
            , "exports"
                .= Aeson.object
                    [ "."
                        .= Aeson.object
                            [ "types" .= ("./index.d.mts" :: Text)
                            , "default" .= ("./index.mjs" :: Text)
                            ]
                    ]
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

readDecls :: FilePath -> IO [TS.Decl]
readDecls dir = do
    files <- listDirectory dir
    decls <-
        traverse
            (\f -> either (fail . ((f <> ": ") <>)) pure =<< Aeson.eitherDecodeFileStrict (dir </> f))
            (sort [f | f <- files, ".json" `isSuffixOf` f])
    pure $ sortOn (.name) decls

-- | The full set of bindings to generate for a package.
data Bindings = Bindings
    { functions :: [TS.Decl]
    -- ^ Publicly exported functions
    , opaqueTypes :: [Text]
    -- ^ Names of opaque Haskell types, each wrapped in a generated class. The
    -- corresponding auto-generated @free_T@ exports are consumed by the
    -- classes rather than exported.
    }

analyseBindings :: [TS.Decl] -> Bindings
analyseBindings decls = Bindings{functions, opaqueTypes}
  where
    opaqueTypes = nub $ concatMap declRefs decls
    declRefs d = concatMap (typeRefs . snd) d.params <> typeRefs d.result
    typeRefs = \case
        TS.Ref n -> [n]
        TS.Promise t -> typeRefs t
        TS.Array t -> typeRefs t
        _ -> []
    (_free, functions) = partition (\d -> d.name `elem` map ("free_" <>) opaqueTypes) decls

generateDeclarations :: Bindings -> Text
generateDeclarations Bindings{..} =
    T.unlines $
        ["export function init(): Promise<void>;"]
            <> map serializeOpaqueClassDecl opaqueTypes
            <> map serializeDecl functions

generateIndexMjs :: Bindings -> Text
generateIndexMjs Bindings{..} =
    template
        <> "\n"
        <> T.unlines (map opaqueClass opaqueTypes <> map export functions)
  where
    template =
        """
        import { init as _init } from "./runtime.mjs";

        let _exports;

        export async function init() {
          _exports = await _init();
        }

        function _call(name, args) {
          if (!_exports) throw new Error(`call "await init()" before using "${name}"`);
          return _exports[name](...args);
        }

        const _construct = Symbol();

        """
    opaqueClass name =
        T.replace "NAME" name
            """
            const _finalizers_NAME = new FinalizationRegistry((ptr) => _call("free_NAME", [ptr]));
            export class NAME {
              #ptr;
              constructor(ptr, token) {
                if (token !== _construct) throw new Error("NAME cannot be constructed directly");
                this.#ptr = ptr;
                _finalizers_NAME.register(this, ptr, this);
              }
              static _wrap(ptr) {
                return new NAME(ptr, _construct);
              }
              _unwrap() {
                if (this.#ptr === undefined) throw new Error("attempt to use a freed NAME");
                return this.#ptr;
              }
              free() {
                if (this.#ptr === undefined) return;
                _finalizers_NAME.unregister(this);
                _call("free_NAME", [this.#ptr]);
                this.#ptr = undefined;
              }
            }
            """
    export decl =
        "export const "
            <> decl.name
            <> " = "
            <> (if isAsync then "async " else "")
            <> "("
            <> T.intercalate ", " (map fst decl.params)
            <> ") => "
            <> maybe callExpr' (\c -> c $ "(" <> callExpr' <> ")") (resultConversion resType)
            <> ";"
      where
        (isAsync, resType) = case decl.result of
            TS.Promise t -> (True, t)
            t -> (False, t)
        callExpr' = (if isAsync then "await " else "") <> callExpr
        callExpr =
            "_call(\""
                <> decl.name
                <> "\", ["
                <> T.intercalate ", " (map (\(n, t) -> maybe n ($ n) (argConversion t)) decl.params)
                <> "])"

-- | JS expression transformer converting a public API value to its raw FFI
-- representation, where they differ.
argConversion :: TS.Type -> Maybe (Text -> Text)
argConversion = \case
    TS.Ref _ -> Just \e -> e <> "._unwrap()"
    TS.Array t -> mapConversion <$> argConversion t
    -- the FFI marshals Bool as 0/1
    TS.Boolean -> Just \e -> "Number(" <> e <> ")"
    _ -> Nothing

-- | JS expression transformer converting a raw FFI value to its public API
-- representation, where they differ.
resultConversion :: TS.Type -> Maybe (Text -> Text)
resultConversion = \case
    TS.Ref n -> Just \e -> n <> "._wrap(" <> e <> ")"
    TS.Array t -> mapConversion <$> resultConversion t
    -- the FFI marshals Bool as 0/1
    TS.Boolean -> Just \e -> "Boolean(" <> e <> ")"
    _ -> Nothing

mapConversion :: (Text -> Text) -> Text -> Text
mapConversion c e = e <> ".map((x) => " <> c "x" <> ")"

-- | How to invoke cabal for cross-compiling to Wasm.
data WasmCabal = WasmCabal
    { exe :: FilePath
    , globalFlags :: [Text]
    , processEnv :: [(String, String)]
    }

-- | Configure a cabal invocation for the wasm32-wasi cross toolchain. When no
-- pre-configured command is given, uses the cabal that invoked us where
-- possible ($CABAL_EXTERNAL_CABAL_PATH is set when we're run as `cabal npm`
-- via cabal's external command system), and passes the toolchain flags
-- itself, mirroring haskell.nix's @wasm32-unknown-wasi-cabal@ wrapper.
getWasmCabal :: Maybe Text -> IO WasmCabal
getWasmCabal override = do
    processEnv <- map fixNixLdflags <$> getEnvironment
    case override of
        Just cmd -> pure WasmCabal{exe = T.unpack cmd, globalFlags = [], processEnv}
        Nothing -> do
            exe <- fromMaybe "cabal" <$> lookupEnv "CABAL_EXTERNAL_CABAL_PATH"
            ghc <- getWasmGhc
            pkgConfig <- findExecutable $ toolchainProgram ghc "pkg-config"
            pure
                WasmCabal
                    { exe
                    , globalFlags =
                        [ "--with-ghc=" <> T.pack ghc
                        , "--with-compiler=" <> T.pack ghc
                        , "--with-ghc-pkg=" <> T.pack (toolchainProgram ghc "ghc-pkg")
                        , "--with-hsc2hs=" <> T.pack (toolchainProgram ghc "hsc2hs")
                        ]
                            <> ["--with-pkg-config=" <> T.pack (toolchainProgram ghc "pkg-config") | isJust pkgConfig]
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

-- | The name of the Wasm-targeting GHC on PATH; different toolchain
-- distributions use different target prefixes (e.g. haskell.nix's
-- @wasm32-unknown-wasi-ghc@ vs ghc-wasm-meta's @wasm32-wasi-ghc@).
getWasmGhc :: IO FilePath
getWasmGhc = do
    let candidates = ["wasm32-unknown-wasi-ghc", "wasm32-wasi-ghc"]
    found <- mapMaybe id <$> traverse (\c -> fmap (const c) <$> findExecutable c) candidates
    case found of
        ghc : _ -> pure ghc
        [] -> fail $ "no Wasm-targeting GHC found on PATH (tried: " <> unwords candidates <> ")"

-- | Derive a sibling toolchain program name from the GHC name, e.g.
-- @wasm32-wasi-ghc@ -> @wasm32-wasi-ghc-pkg@, @wasm32-wasi-hsc2hs@.
toolchainProgram :: FilePath -> String -> FilePath
toolchainProgram ghc prog = case prog of
    'g' : 'h' : 'c' : _ -> ghc <> drop 3 prog
    _ -> reverse (drop 3 (reverse ghc)) <> prog

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
