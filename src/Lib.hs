{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib (
    exportJS,
    Synchronicity (..),
) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.Function (applyWhen)
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Text (Text)
import Data.Word (Word16, Word32, Word64, Word8)
import Language.Haskell.TH

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

exportJS :: Synchronicity -> Name -> DecsQ
exportJS sync declName = do
    let declNameStr = nameBase declName
    info <- reify declName
    ty <- case info of
        VarI _ t _ -> pure t
        _ -> fail $ show declName <> " is not a term variable"
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
    wrapperName <- newName $ "js_export_" <> declNameStr
    let namedArgs = zipWith (\TypeInfo{..} n -> NamedArgInfo{var = mkName ("x" <> show @Int n), ..}) args [0 ..]
        tyJS = joinFunTy (map (.jsType) args) $ applyWhen isIO (AppT (ConT ''IO)) res.jsType
        exportStr =
            declNameStr <> case sync of
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
                                (VarE declName)
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

splitFunTy :: Type -> ([Type], Type)
splitFunTy = go
  where
    go = \case
        AppT (AppT ArrowT arg) rest -> first (arg :) $ go rest
        t -> ([], t)
joinFunTy :: [Type] -> Type -> Type
joinFunTy = flip $ foldr (\a r -> ArrowT `AppT` a `AppT` r)
