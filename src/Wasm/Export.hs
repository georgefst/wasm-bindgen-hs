{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Wasm.Export (
    exportJS,
    exportDeclJS,
    Synchronicity (..),
) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.Function (applyWhen)
import Data.Int (Int16, Int32, Int64, Int8)
import Data.Kind (FUN)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Traversable (for)
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.StablePtr (StablePtr, freeStablePtr)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (getQ, putQ)
import TH.Utilities (typeRepToType)
import Type.Reflection (SomeTypeRep (..), Typeable, typeRep)

#ifdef wasi_HOST_OS
import Data.Vector qualified as V
import GHC.Wasm.JS.Array (JSArray (..), fromJSVals, toJSVals)
import GHC.Wasm.JS.String (
    fromShortByteString,
    fromStrictByteString,
    fromStrictText,
    toShortByteString,
    toStrictByteString,
    toStrictText,
 )
import GHC.Wasm.Prim (JSString (..), JSVal, fromJSString, toJSString)

-- Runtime helpers referenced by generated code.

listToJS :: (a -> JSVal) -> [a] -> JSVal
listToJS f xs = case fromJSVals $ V.fromList $ map f xs of JSArray v -> v

listFromJS :: (JSVal -> a) -> JSVal -> [a]
listFromJS f = map f . V.toList . toJSVals . JSArray

-- Boxing conversions for element types of JS arrays.
foreign import javascript unsafe "$1" jsValFromJSString :: JSString -> JSVal
foreign import javascript unsafe "$1" jsValToJSString :: JSVal -> JSString
foreign import javascript unsafe "$1" jsValFromBool :: Bool -> JSVal
foreign import javascript unsafe "$1" jsValToBool :: JSVal -> Bool
foreign import javascript unsafe "$1" jsValFromInt :: Int -> JSVal
foreign import javascript unsafe "$1" jsValToInt :: JSVal -> Int
foreign import javascript unsafe "$1" jsValFromWord :: Word -> JSVal
foreign import javascript unsafe "$1" jsValToWord :: JSVal -> Word
foreign import javascript unsafe "$1" jsValFromInt8 :: Int8 -> JSVal
foreign import javascript unsafe "$1" jsValToInt8 :: JSVal -> Int8
foreign import javascript unsafe "$1" jsValFromInt16 :: Int16 -> JSVal
foreign import javascript unsafe "$1" jsValToInt16 :: JSVal -> Int16
foreign import javascript unsafe "$1" jsValFromInt32 :: Int32 -> JSVal
foreign import javascript unsafe "$1" jsValToInt32 :: JSVal -> Int32
foreign import javascript unsafe "$1" jsValFromInt64 :: Int64 -> JSVal
foreign import javascript unsafe "$1" jsValToInt64 :: JSVal -> Int64
foreign import javascript unsafe "$1" jsValFromWord8 :: Word8 -> JSVal
foreign import javascript unsafe "$1" jsValToWord8 :: JSVal -> Word8
foreign import javascript unsafe "$1" jsValFromWord16 :: Word16 -> JSVal
foreign import javascript unsafe "$1" jsValToWord16 :: JSVal -> Word16
foreign import javascript unsafe "$1" jsValFromWord32 :: Word32 -> JSVal
foreign import javascript unsafe "$1" jsValToWord32 :: JSVal -> Word32
foreign import javascript unsafe "$1" jsValFromWord64 :: Word64 -> JSVal
foreign import javascript unsafe "$1" jsValToWord64 :: JSVal -> Word64
foreign import javascript unsafe "$1" jsValFromFloat :: Float -> JSVal
foreign import javascript unsafe "$1" jsValToFloat :: JSVal -> Float
foreign import javascript unsafe "$1" jsValFromDouble :: Double -> JSVal
foreign import javascript unsafe "$1" jsValToDouble :: JSVal -> Double
foreign import javascript unsafe "$1" jsValFromStablePtr :: StablePtr a -> JSVal
foreign import javascript unsafe "$1" jsValToStablePtr :: JSVal -> StablePtr a
#else
-- for HLS
type JSString = ()
type JSVal = ()
toStrictText
    , fromStrictText
    , toStrictByteString
    , fromStrictByteString
    , toShortByteString
    , fromShortByteString
    , toJSString
    , fromJSString
    , listToJS
    , listFromJS
    , jsValFromJSString
    , jsValToJSString
    , jsValFromBool
    , jsValToBool
    , jsValFromInt
    , jsValToInt
    , jsValFromWord
    , jsValToWord
    , jsValFromInt8
    , jsValToInt8
    , jsValFromInt16
    , jsValToInt16
    , jsValFromInt32
    , jsValToInt32
    , jsValFromInt64
    , jsValToInt64
    , jsValFromWord8
    , jsValToWord8
    , jsValFromWord16
    , jsValToWord16
    , jsValFromWord32
    , jsValToWord32
    , jsValFromWord64
    , jsValToWord64
    , jsValFromFloat
    , jsValToFloat
    , jsValFromDouble
    , jsValToDouble
    , jsValFromStablePtr
    , jsValToStablePtr ::
        ()
toStrictText = ()
fromStrictText = ()
toStrictByteString = ()
fromStrictByteString = ()
toShortByteString = ()
fromShortByteString = ()
toJSString = ()
fromJSString = ()
listToJS = ()
listFromJS = ()
jsValFromJSString = ()
jsValToJSString = ()
jsValFromBool = ()
jsValToBool = ()
jsValFromInt = ()
jsValToInt = ()
jsValFromWord = ()
jsValToWord = ()
jsValFromInt8 = ()
jsValToInt8 = ()
jsValFromInt16 = ()
jsValToInt16 = ()
jsValFromInt32 = ()
jsValToInt32 = ()
jsValFromInt64 = ()
jsValToInt64 = ()
jsValFromWord8 = ()
jsValToWord8 = ()
jsValFromWord16 = ()
jsValToWord16 = ()
jsValFromWord32 = ()
jsValToWord32 = ()
jsValFromWord64 = ()
jsValToWord64 = ()
jsValFromFloat = ()
jsValToFloat = ()
jsValFromDouble = ()
jsValToDouble = ()
jsValFromStablePtr = ()
jsValToStablePtr = ()
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
                            `AppE` res.converter
                            `AppE` foldl
                                AppE
                                bodyExpr
                                (map (\arg -> arg.converter `AppE` VarE arg.var) namedArgs)
                        )
                    )
                    []
                ]
    freeDecls <- concat <$> for (stablePtrPayloads $ argTys <> [resTy]) mkFreeExport
    pure $ [exportDecl, sigDecl, wrapperDecl] <> freeDecls

-- | The types @t@ appearing as @'StablePtr' t@ anywhere in any of the given types.
stablePtrPayloads :: [Type] -> [Name]
stablePtrPayloads = concatMap go
  where
    go = \case
        AppT (ConT sp) (ConT n) | sp == ''StablePtr -> [n]
        AppT t0 t1 -> go t0 <> go t1
        _ -> []

-- | Names of types for which a `freeStablePtr` export has already been generated in this module.
newtype FreedStablePtrTypes = FreedStablePtrTypes [Name]

{- | Generate a @free_\<Type\>@ export for the given type, unless one has already been generated
in this module.
-}
mkFreeExport :: Name -> DecsQ
mkFreeExport tyName = do
    FreedStablePtrTypes seen <- fromMaybe (FreedStablePtrTypes []) <$> getQ
    if tyName `elem` seen
        then pure []
        else do
            case filter (\n -> nameBase n == nameBase tyName) seen of
                clash : _ ->
                    fail
                        $ "StablePtr types with the same base name would generate clashing exports: "
                        <> show clash
                        <> " and "
                        <> show tyName
                [] -> pure ()
            putQ $ FreedStablePtrTypes $ tyName : seen
            mkExport
                Sync
                ("free_" <> nameBase tyName)
                (VarE 'freeStablePtr)
                ( ArrowT
                    `AppT` (ConT ''StablePtr `AppT` ConT tyName)
                    `AppT` (ConT ''IO `AppT` TupleT 0)
                )

data NamedArgInfo = NamedArgInfo
    { jsType :: Type
    , converter :: Exp
    , var :: Name
    }

data TypeInfo = TypeInfo
    { jsType :: Type
    , converter :: Exp
    }

argInfo :: Type -> Maybe TypeInfo
argInfo = \case
    ConT n
        | n == ''Text -> jsStringInfo 'toStrictText
        | n == ''ByteString -> jsStringInfo 'toStrictByteString
        | n == ''ShortByteString -> jsStringInfo 'toShortByteString
    AppT ListT t
        -- Haskell strings are converted whole, rather than as lists of characters
        | t == ConT ''Char -> jsStringInfo 'fromJSString
        | otherwise -> do
            elemInfo <- argInfo t
            unbox <- unboxJSVal elemInfo.jsType
            pure
                TypeInfo
                    { jsType = ConT ''JSVal
                    , converter = VarE 'listFromJS `AppE` compose elemInfo.converter unbox
                    }
    t | isSimpleFFIType t -> Just TypeInfo{jsType = t, converter = VarE 'id}
    _ -> Nothing

resInfo :: Type -> Maybe TypeInfo
resInfo = \case
    ConT n
        | n == ''Text -> jsStringInfo 'fromStrictText
        | n == ''ByteString -> jsStringInfo 'fromStrictByteString
        | n == ''ShortByteString -> jsStringInfo 'fromShortByteString
    AppT ListT t
        -- Haskell strings are converted whole, rather than as lists of characters
        | t == ConT ''Char -> jsStringInfo 'toJSString
        | otherwise -> do
            elemInfo <- resInfo t
            box <- boxJSVal elemInfo.jsType
            pure
                TypeInfo
                    { jsType = ConT ''JSVal
                    , converter = VarE 'listToJS `AppE` compose box elemInfo.converter
                    }
    t | isSimpleFFIType t -> Just TypeInfo{jsType = t, converter = VarE 'id}
    _ -> Nothing

jsStringInfo :: Name -> Maybe TypeInfo
jsStringInfo converter = Just TypeInfo{jsType = ConT ''JSString, converter = VarE converter}

compose :: Exp -> Exp -> Exp
compose f g = InfixE (Just f) (VarE '(.)) (Just g)

-- | An expression converting the given FFI-legal type to a 'JSVal', e.g. for use in a JS array.
boxJSVal :: Type -> Maybe Exp
boxJSVal = \case
    AppT (ConT n) _ | n == ''StablePtr -> Just $ VarE 'jsValFromStablePtr
    ConT n
        | n == ''JSVal -> Just $ VarE 'id
        | n == ''JSString -> Just $ VarE 'jsValFromJSString
        | n == ''Bool -> Just $ VarE 'jsValFromBool
        | n == ''Int -> Just $ VarE 'jsValFromInt
        | n == ''Word -> Just $ VarE 'jsValFromWord
        | n == ''Int8 -> Just $ VarE 'jsValFromInt8
        | n == ''Int16 -> Just $ VarE 'jsValFromInt16
        | n == ''Int32 -> Just $ VarE 'jsValFromInt32
        | n == ''Int64 -> Just $ VarE 'jsValFromInt64
        | n == ''Word8 -> Just $ VarE 'jsValFromWord8
        | n == ''Word16 -> Just $ VarE 'jsValFromWord16
        | n == ''Word32 -> Just $ VarE 'jsValFromWord32
        | n == ''Word64 -> Just $ VarE 'jsValFromWord64
        | n == ''Float -> Just $ VarE 'jsValFromFloat
        | n == ''Double -> Just $ VarE 'jsValFromDouble
    _ -> Nothing

-- | An expression converting a 'JSVal' to the given FFI-legal type, e.g. for use in a JS array.
unboxJSVal :: Type -> Maybe Exp
unboxJSVal = \case
    AppT (ConT n) _ | n == ''StablePtr -> Just $ VarE 'jsValToStablePtr
    ConT n
        | n == ''JSVal -> Just $ VarE 'id
        | n == ''JSString -> Just $ VarE 'jsValToJSString
        | n == ''Bool -> Just $ VarE 'jsValToBool
        | n == ''Int -> Just $ VarE 'jsValToInt
        | n == ''Word -> Just $ VarE 'jsValToWord
        | n == ''Int8 -> Just $ VarE 'jsValToInt8
        | n == ''Int16 -> Just $ VarE 'jsValToInt16
        | n == ''Int32 -> Just $ VarE 'jsValToInt32
        | n == ''Int64 -> Just $ VarE 'jsValToInt64
        | n == ''Word8 -> Just $ VarE 'jsValToWord8
        | n == ''Word16 -> Just $ VarE 'jsValToWord16
        | n == ''Word32 -> Just $ VarE 'jsValToWord32
        | n == ''Word64 -> Just $ VarE 'jsValToWord64
        | n == ''Float -> Just $ VarE 'jsValToFloat
        | n == ''Double -> Just $ VarE 'jsValToDouble
    _ -> Nothing

-- Types that are natively marshalable by the FFI and thus need no conversion
isSimpleFFIType :: Type -> Bool
isSimpleFFIType = \case
    TupleT 0 -> True
    -- opaque Haskell heap objects, handled by JS as plain (pointer) numbers
    -- the payload must be a plain type constructor, so that we can name the freeing export
    AppT (ConT n) (ConT _) | n == ''StablePtr -> True
    ConT n
        | n == ''JSVal -> True
        | n == ''JSString -> True
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
        AppT (AppT (ConT fun) arg) rest | fun == ''FUN -> first (arg :) $ go rest
        t -> ([], t)
joinFunTy :: [Type] -> Type -> Type
joinFunTy = flip $ foldr (\a r -> ArrowT `AppT` a `AppT` r)
