{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Wasm.Export (
    exportJS,
    exportDeclJS,
    Synchronicity (..),
) where

import Control.Monad (when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.Char (isSpace)
import Data.Function (applyWhen)
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Kind (FUN)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Word (Word16, Word32, Word64, Word8)
import Language.Haskell.TH
import System.Directory (createDirectoryIfMissing, doesFileExist)
import TH.Utilities (typeRepToType)
import TS.AST qualified as TS
import TS.Serialize (serializeDecl)
import Type.Reflection (SomeTypeRep (..), Typeable, typeRep)

#ifdef wasi_HOST_OS
import GHC.Wasm.JS.String (
    fromShortByteString,
    fromStrictByteString,
    fromStrictText,
    toShortByteString,
    toStrictByteString,
    toStrictText,
 )
import GHC.Wasm.Prim (JSString)
#else
-- for HLS
toStrictText :: ()
toStrictText = ()
fromStrictByteString :: ()
fromStrictByteString = ()
fromShortByteString :: ()
fromShortByteString = ()
fromStrictText :: ()
fromStrictText = ()
toStrictByteString :: ()
toStrictByteString = ()
toShortByteString :: ()
toShortByteString = ()
type JSString = ()
#endif

data Synchronicity = Sync | Async
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Generate a JS FFI export for the given named expression.
exportJS :: forall a. (Typeable a) => Synchronicity -> String -> Code Q a -> DecsQ
exportJS sync name code = do
    ty <- typeRepToType $ SomeTypeRep $ typeRep @a
    expr <- unType <$> examineCode code
    mkExport sync name expr ty

-- | Generate a JS FFI export for a top-level definition, using its existing name.
exportDeclJS :: Synchronicity -> Name -> DecsQ
exportDeclJS sync declName = do
    info <- reify declName
    ty <- case info of
        VarI _ t _ -> pure t
        _ -> fail $ show declName <> " is not a term variable"
    mkExport sync (nameBase declName) (VarE declName) ty

-- | Marker file naming the directory where TS declaration fragments are
-- written during compilation. Looked up relative to the compilation working
-- directory. When absent, no fragments are written. Created (and cleaned up)
-- automatically by the @cabal-npm@ tool.
--
-- A file is used rather than an environment variable because this TH code
-- runs inside GHC's Wasm external interpreter, which does not inherit the
-- host environment (though it can access the host filesystem).
tsOutDirFile :: FilePath
tsOutDirFile = ".wasm-bindgen-hs-ts-out-dir"

mkExport :: Synchronicity -> String -> Exp -> Type -> DecsQ
mkExport sync exportName bodyExpr ty = do
    let (argTys, resTy0) = splitFunTy ty
        (isIO, resTy) = case resTy0 of
            AppT (ConT io) t | io == ''IO -> (True, t)
            t -> (False, t)
    args <-
        traverse
            (\t -> maybe (fail $ "No known conversion from JS for type: " <> pprint t) pure $ argInfo t)
            argTys
    res <-
        maybe
            (fail $ "No known conversion to JS for type: " <> pprint resTy)
            pure
            $ resInfo resTy
    tsArgTypes <-
        traverse
            (\t -> maybe (fail $ "No known TS type for: " <> pprint t) pure $ tsType t)
            argTys
    tsResType <-
        maybe
            (fail $ "No known TS type for: " <> pprint resTy)
            pure
            $ tsType resTy
    let tsParams = zipWith (\t n -> ("x" <> T.show @Int n, t)) tsArgTypes [0 ..]
        tsReturn = case sync of
            Async -> TS.Promise tsResType
            Sync -> tsResType
        tsDecl = TS.Decl{name = T.pack exportName, params = tsParams, result = tsReturn}
    runIO do
        hasOutDir <- doesFileExist tsOutDirFile
        when hasOutDir do
            dir <- dropWhileEnd isSpace <$> readFile tsOutDirFile
            createDirectoryIfMissing True dir
            T.writeFile (dir <> "/" <> exportName <> ".d.ts") $ serializeDecl tsDecl <> "\n"
    -- Build Haskell FFI export
    wrapperName <- newName $ "js_export_" <> exportName
    let namedArgs = zipWith (\TypeInfo{..} n -> NamedArgInfo{var = mkName ("x" <> show @Int n), ..}) args [0 ..]
        tyJS = joinFunTy (map (.jsType) args) $ applyWhen isIO (AppT (ConT ''IO)) res.jsType
        exportStr =
            exportName <> case sync of
                Async -> ""
                Sync -> " sync"
        exportDecl = ForeignD $ ExportF JavaScript exportStr wrapperName tyJS
        sigDecl = SigD wrapperName tyJS
        wrapperDecl =
            FunD
                wrapperName
                [ Clause
                    (map (VarP . (.var)) namedArgs)
                    ( NormalB
                        ( VarE (if isIO then 'fmap else 'id)
                            `AppE` VarE res.converter
                            `AppE` foldl
                                AppE
                                bodyExpr
                                (map (\arg -> VarE arg.converter `AppE` VarE arg.var) namedArgs)
                        )
                    )
                    []
                ]
    pure [exportDecl, sigDecl, wrapperDecl]

data NamedArgInfo = NamedArgInfo
    { jsType :: Type
    , converter :: Name
    , var :: Name
    }

data TypeInfo = TypeInfo
    { jsType :: Type
    , converter :: Name
    }

argInfo :: Type -> Maybe TypeInfo
argInfo = \case
    ConT n
        | n == ''Text -> Just TypeInfo{jsType = ConT ''JSString, converter = 'toStrictText}
        | n == ''ByteString -> Just TypeInfo{jsType = ConT ''JSString, converter = 'toStrictByteString}
        | n == ''ShortByteString -> Just TypeInfo{jsType = ConT ''JSString, converter = 'toShortByteString}
    t | isSimpleFFIType t -> Just TypeInfo{jsType = t, converter = 'id}
    _ -> Nothing

resInfo :: Type -> Maybe TypeInfo
resInfo = \case
    ConT n
        | n == ''Text -> Just TypeInfo{jsType = ConT ''JSString, converter = 'fromStrictText}
        | n == ''ByteString -> Just TypeInfo{jsType = ConT ''JSString, converter = 'fromStrictByteString}
        | n == ''ShortByteString -> Just TypeInfo{jsType = ConT ''JSString, converter = 'fromShortByteString}
    t | isSimpleFFIType t -> Just TypeInfo{jsType = t, converter = 'id}
    _ -> Nothing

-- Types that are natively marshalable by the FFI and thus need no conversion
isSimpleFFIType :: Type -> Bool
isSimpleFFIType = \case
    TupleT 0 -> True
    ConT n
        | n == ''Bool -> True
        | n == ''Char -> True
        | n == ''Int -> True
        | n == ''Word -> True
        | n == ''Int8 -> True
        | n == ''Int16 -> True
        | n == ''Int32 -> True
        | n == ''Int64 -> True
        | n == ''Word8 -> True
        | n == ''Word16 -> True
        | n == ''Word32 -> True
        | n == ''Word64 -> True
        | n == ''Float -> True
        | n == ''Double -> True
    _ -> False

-- | Map a Haskell type to its TypeScript equivalent.
tsType :: Type -> Maybe TS.Type
tsType = \case
    TupleT 0 -> Just TS.Void
    ConT n
        | n == ''Bool -> Just TS.Boolean
        | n == ''Char -> Just TS.String
        | n == ''Text -> Just TS.String
        | n == ''ByteString -> Just TS.String
        | n == ''ShortByteString -> Just TS.String
        | n == ''Int -> Just TS.Number
        | n == ''Word -> Just TS.Number
        | n == ''Int8 -> Just TS.Number
        | n == ''Int16 -> Just TS.Number
        | n == ''Int32 -> Just TS.Number
        | n == ''Word8 -> Just TS.Number
        | n == ''Word16 -> Just TS.Number
        | n == ''Word32 -> Just TS.Number
        | n == ''Float -> Just TS.Number
        | n == ''Double -> Just TS.Number
        | n == ''Int64 -> Just TS.BigInt
        | n == ''Word64 -> Just TS.BigInt
    _ -> Nothing

splitFunTy :: Type -> ([Type], Type)
splitFunTy = go
  where
    go = \case
        AppT (AppT ArrowT arg) rest -> first (arg :) $ go rest
        AppT (AppT (ConT fun) arg) rest | fun == ''FUN -> first (arg :) $ go rest
        t -> ([], t)
joinFunTy :: [Type] -> Type -> Type
joinFunTy = flip $ foldr (\a r -> ArrowT `AppT` a `AppT` r)
