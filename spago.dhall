{ name = "my-project"
, dependencies =
  [ "aff"
  , "arrays"
  , "console"
  , "control"
  , "debug"
  , "debugged"
  , "effect"
  , "either"
  , "foldable-traversable"
  , "identity"
  , "lists"
  , "maybe"
  , "newtype"
  , "node-readline"
  , "parsing"
  , "partial"
  , "prelude"
  , "profunctor-lenses"
  , "psci-support"
  , "run"
  , "run-supply"
  , "strings"
  , "tuples"
  , "typelevel-prelude"
  , "undefined"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs", "test/**/*.purs" ]
}
