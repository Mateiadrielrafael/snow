module Snow.Context where

import Prelude

import Data.Array (any, snoc, takeWhile)
import Data.Debug (class Debug, constructor, genericDebug)
import Data.Foldable (findMap)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.TraversableWithIndex (traverseWithIndex)
import Data.Tuple.Nested ((/\), type (/\))
import Run (Run)
import Run.Except (EXCEPT, throw)
import Run.Supply (SUPPLY, generate)
import Snow.Run.Logger (LOGGER, LogLevel(..))
import Snow.Run.Logger as Logger
import Snow.Stinrg (indent)
import Snow.Type (Existential, SnowType(..), everywhereOnType)
import Type.Row (type (+))

data ContextElement
  = CUniversal String SnowType
  | CExistential Existential SnowType (Maybe SnowType)
  | CMarker Existential

type Context = Array ContextElement

data CheckLogDetails
  = Checking SnowType SnowType
  | Inferring SnowType
  | Inferred SnowType SnowType
  | InferringCall SnowType SnowType
  | InferredCall SnowType SnowType SnowType
  | Instantiating InstantiationRule Existential SnowType
  | Subtyping SnowType SnowType
  | Solved Existential SnowType

type CheckLog = Context /\ CheckLogDetails

type CheckM r = Run (LOGGER CheckLog + SUPPLY Int + EXCEPT String r)

--------- Instantiation
newtype InstantiationRule = InstantiationRule Boolean

less :: InstantiationRule
less = InstantiationRule false

more :: InstantiationRule
more = InstantiationRule true

--------- Helpers
printContext :: Context -> String
printContext = joinWith "\n" <<< map show

isWellFormed :: Context -> SnowType -> Boolean
isWellFormed ctx (Pi name domain codomain) = isWellFormed ctx domain
  && isWellFormed (snoc ctx $ CUniversal name domain) codomain
isWellFormed ctx (Forall name domain codomain) = isWellFormed ctx domain
  && isWellFormed (snoc ctx (CUniversal name domain)) codomain
isWellFormed ctx (Exists name domain codomain) = isWellFormed ctx domain
  && isWellFormed (snoc ctx (CUniversal name domain)) codomain
isWellFormed ctx (Universal target) = ctx # any case _ of
  CUniversal name _ -> name == target
  _ -> false
isWellFormed ctx (Unsolved { id }) = ctx # any case _ of
  CExistential current _ _ | current.id == id -> true
  _ -> false
isWellFormed ctx (Application left right) = isWellFormed ctx left && isWellFormed ctx right
isWellFormed ctx (Annotation expr annotation) = isWellFormed ctx expr && isWellFormed ctx annotation
isWellFormed ctx (Effectful effect ty) = isWellFormed ctx effect && isWellFormed ctx ty
isWellFormed ctx (Lambda argument body) = isWellFormed (snoc ctx (CUniversal argument {- TODO: ensure this never gets used -} Unit)) body
isWellFormed ctx (Star _) = true
isWellFormed ctx Unit = true
isWellFormed ctx ExprUnit = true

getVariableType :: String -> Context -> Maybe SnowType
getVariableType target = findMap case _ of
  CUniversal name ty | name == target -> Just ty
  _ -> Nothing

getExistentialType :: Int -> Context -> Maybe SnowType
getExistentialType target = findMap case _ of
  CExistential { id } ty _ | id == target -> Just ty
  _ -> Nothing

ensureWellFormed :: forall r. Context -> SnowType -> Run (EXCEPT String r) Unit
ensureWellFormed context type_ = do
  unless (isWellFormed context type_) do
    throw $ joinWith "\n"
      [ "A type variable probably escaped it's scope. Type"
      , indent 4 $ show type_
      , "is not well formed in context"
      , indent 4 $ printContext context
      ]

solve :: forall r. Existential -> SnowType -> Context -> Run (EXCEPT String + LOGGER CheckLog r) Context
solve target solution ctx = ctx # traverseWithIndex case _, _ of
  index, element@(CExistential existential domain Nothing)
    | existential.id == target.id -> do
        ensureWellFormed (beforeElement element ctx) solution
        Logger.log Debug (ctx /\ Solved existential solution)
        pure $ CExistential existential domain $ Just solution
  _, e -> pure e

-- | Get the solution for an existential
getSolution :: Context -> Existential -> Maybe SnowType
getSolution ctx e = join $ findMap go ctx
  where
  go (CExistential e' domain solution) | e == e' = Just (solution)
  go _ = Nothing

-- | Replace all existentials in a type with their solutions
applyContext :: Context -> SnowType -> SnowType
applyContext ctx = everywhereOnType case _ of
  Unsolved e -> case getSolution ctx e of
    Just solution -> applyContext ctx solution
    Nothing -> Unsolved e
  ty -> ty

-- | Returns true if the second param was bound before the first
boundBefore :: Existential -> Existential -> Context -> Boolean
boundBefore first second = fromMaybe false <<< findMap case _ of
  CExistential e domain _
    | e == first -> Just false
    | e == second -> Just true
  _ -> Nothing

-- | Take all the elements of a context which appear before an arbitrary universal.
beforeUniversal :: String -> Context -> Context
beforeUniversal target = takeWhile case _ of
  CUniversal name _ -> name == target
  _ -> false

beforeMarker :: Existential -> Context -> Context
beforeMarker target = takeWhile \a -> a /= CMarker target

beforeElement :: ContextElement -> Context -> Context
beforeElement target = takeWhile \a -> a /= target

-- | Make an existential with an unique id
makeExistential :: forall r. String -> CheckM r Existential
makeExistential name = generate <#> { name, id: _ }

---------- Typeclass instances
derive instance Eq InstantiationRule
derive instance Generic InstantiationRule _
instance Debug InstantiationRule where
  debug rule = if rule == less then constructor "Less" [] else constructor "More" []

derive instance Eq ContextElement
derive instance Generic ContextElement _
instance Debug ContextElement where
  debug = genericDebug
instance Show ContextElement where
  show (CExistential { name } domain ty) = case ty of
    Nothing -> "?" <> (name <> " :: " <> show ty)
    Just ty -> "?" <> ("(" <> name <> " :: " <> show ty <> ")") <> " = " <> show ty
  show (CUniversal uni ty) = uni <> " :: " <> show ty
  show (CMarker { name }) = ">>> " <> name

derive instance Generic CheckLogDetails _
instance Debug CheckLogDetails where
  debug = genericDebug
instance Show CheckLogDetails where
  show (Checking expr ty) = joinWith "\n"
    [ "Checking that expression"
    , indent 4 $ show expr
    , "has type"
    , indent 4 $ show ty
    ]
  show (Inferring expr) = joinWith "\n"
    [ "Inferring the type of expression"
    , indent 4 $ show expr
    ]
  show (Inferred expr type_) = joinWith "\n"
    [ "Inferred the expression"
    , indent 4 $ show expr
    , "to have type"
    , indent 4 $ show type_
    ]
  show (InferringCall expr ty) = joinWith "\n"
    [ "Inferring the result of applying a function of type"
    , indent 4 $ show ty
    , "to the argument"
    , indent 4 $ show expr
    ]
  show (InferredCall expr ty to) = joinWith "\n"
    [ "The result of applying a function of type"
    , indent 4 $ show ty
    , "to the argument"
    , indent 4 $ show expr
    , "has type"
    , indent 4 $ show to
    ]
  show (Subtyping left right) = joinWith "\n"
    [ "Checking that type"
    , indent 4 $ show left
    , "is less general than type"
    , indent 4 $ show right
    ]
  show (Instantiating rule { name } right) = joinWith "\n"
    [ "Instantiating existential"
    , indent 4 name
    , "so it is " <> (if rule == more then "more" else "less") <> " general than type"
    , indent 4 $ show right
    ]
  show (Solved { name } to) = joinWith "\n"
    [ "Solving existential"
    , indent 4 $ "?" <> name
    , "to type"
    , indent 4 $ show to
    ]