-- should be its own library, but currently very WIP
module TS.AST where

import Data.Text (Text)

data Type
    = Number
    | BigInt
    | Boolean
    | String
    | Void
    | Promise Type
    deriving stock (Eq, Ord, Show)

data Decl = Decl
    { name :: Text
    , params :: [(Text, Type)]
    , result :: Type
    }
    deriving stock (Eq, Ord, Show)
