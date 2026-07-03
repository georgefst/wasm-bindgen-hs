module TS.Serialize (serializeDecl) where

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
    TS.Promise t -> "Promise<" <> serializeType t <> ">"

serializeDecl :: TS.Decl -> Text
serializeDecl TS.Decl{..} =
    "export function "
        <> name
        <> "("
        <> T.intercalate ", " (params <&> \(n, t) -> n <> ": " <> serializeType t)
        <> "): "
        <> serializeType result
        <> ";"
