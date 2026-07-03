module TS.Serialize (serializeType, serializeDecl, serializeOpaqueClassDecl) where

import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Text qualified as T
import TS.AST qualified as TS

serializeType :: TS.Type -> Text
serializeType = \case
    TS.Number -> "number"
    TS.BigInt -> "bigint"
    TS.Boolean -> "boolean"
    TS.String -> "string"
    TS.Void -> "void"
    TS.Unknown -> "unknown"
    TS.Promise t -> "Promise<" <> serializeType t <> ">"
    TS.Array t -> serializeType t <> "[]"
    TS.Ref n -> n

serializeDecl :: TS.Decl -> Text
serializeDecl TS.Decl{..} =
    "export function "
        <> name
        <> "("
        <> T.intercalate ", " (params <&> \(n, t) -> n <> ": " <> serializeType t)
        <> "): "
        <> serializeType result
        <> ";"

-- | Declaration for the class generated for an opaque Haskell type. The
-- constructor is declared private, since instances can only meaningfully be
-- created by the generated bindings.
serializeOpaqueClassDecl :: Text -> Text
serializeOpaqueClassDecl name =
    T.unlines
        [ "/** An opaque reference to a Haskell `" <> name <> "` value. */"
        , "export class " <> name <> " {"
        , "  private constructor();"
        , "  /** Release the underlying Haskell value. Idempotent. Also happens automatically when this object is garbage-collected. */"
        , "  free(): void;"
        , "}"
        ]
