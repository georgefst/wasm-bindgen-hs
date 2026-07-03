{-# LANGUAGE DeriveAnyClass #-}

-- should be its own library, but currently very WIP
module TS.AST where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

data Type
    = Number
    | BigInt
    | Boolean
    | String
    | Void
    | Unknown
    | Promise Type
    | Array Type
    | -- | A reference to a named type, e.g. a generated class for an opaque Haskell type.
      Ref Text
    deriving stock (Eq, Ord, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

data Decl = Decl
    { name :: Text
    , params :: [(Text, Type)]
    , result :: Type
    }
    deriving stock (Eq, Ord, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)
