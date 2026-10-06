//// Typed configuration contracts for Gleam applications.
////
//// Declare every environment variable and file your app reads with typed
//// builders, then combine them with `use`, the way `gleam/dynamic/decode`
//// builds decoders:
////
//// ```gleam
//// pub type Config {
////   Config(port: Int, database_url: String, timeout: Duration)
//// }
////
//// pub fn spec() -> docuconf.Spec(Config) {
////   use port <- docuconf.env(
////     docuconf.int("PORT", "HTTP listen port")
////     |> docuconf.min_int(1)
////     |> docuconf.max_int(65_535)
////     |> docuconf.default(8080),
////   )
////   use database_url <- docuconf.env(
////     docuconf.url("DATABASE_URL", "Primary Postgres connection string")
////     |> docuconf.schemes(["postgres"])
////     |> docuconf.secret
////     |> docuconf.required,
////   )
////   use timeout <- docuconf.env(
////     docuconf.duration("REQUEST_TIMEOUT", "Upstream request timeout")
////     |> docuconf.default(duration.seconds(30)),
////   )
////   docuconf.succeed(Config(port:, database_url:, timeout:))
//// }
//// ```
////
//// `load(spec())` reads the process environment (through `envoy`) and the
//// declared files, and returns the typed value or every problem found.
//// `contract(spec(), name: "orders")` renders the `contract.cue` the
//// platform validates before deploying.

import docuconf/duration.{type Duration}
import docuconf/internal/cue
import docuconf/internal/meta.{
  type FileMeta, type Meta, type VarMeta, FileInput, FileMeta, VarInput, VarMeta,
}
import docuconf/internal/re2
import docuconf/json.{type Json}
import envoy
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

// ---- errors -----------------------------------------------------------------

/// The stable error codes of SPEC §11.2 item 5.
pub type Code {
  MissingRequired
  InvalidType
  OutOfRange
  PatternMismatch
  NotInEnum
  InvalidScheme
  TooFewItems
  TooManyItems
  FileMissing
  FileUnreadable
  FileTooLarge
  FileMalformed
  SchemaMismatch
  CertificateInvalid
  CertificateExpiring
  CertificateNameMismatch
  KeyMismatch
  KeystoreUnreadable
}

pub fn code_to_string(code: Code) -> String {
  case code {
    MissingRequired -> "missing_required"
    InvalidType -> "invalid_type"
    OutOfRange -> "out_of_range"
    PatternMismatch -> "pattern_mismatch"
    NotInEnum -> "not_in_enum"
    InvalidScheme -> "invalid_scheme"
    TooFewItems -> "too_few_items"
    TooManyItems -> "too_many_items"
    FileMissing -> "file_missing"
    FileUnreadable -> "file_unreadable"
    FileTooLarge -> "file_too_large"
    FileMalformed -> "file_malformed"
    SchemaMismatch -> "schema_mismatch"
    CertificateInvalid -> "certificate_invalid"
    CertificateExpiring -> "certificate_expiring"
    CertificateNameMismatch -> "certificate_name_mismatch"
    KeyMismatch -> "key_mismatch"
    KeystoreUnreadable -> "keystore_unreadable"
  }
}

fn code_from_string(s: String) -> Code {
  case s {
    "key_mismatch" -> KeyMismatch
    "certificate_expiring" -> CertificateExpiring
    "certificate_name_mismatch" -> CertificateNameMismatch
    _ -> CertificateInvalid
  }
}

pub type InputKind {
  VarKind
  FileKind
}

/// One problem found at boot. `message` never contains a secret value.
pub type Violation {
  Violation(input: String, kind: InputKind, code: Code, message: String)
}

pub type Error {
  /// The declaration itself is invalid (SPEC §11.2 item 2).
  InvalidDeclaration(problems: List(String))
  /// The environment or a file input is invalid; every problem is listed.
  InvalidConfig(violations: List(Violation))
}

/// Formats an error for logs: one line per problem.
pub fn describe(error: Error) -> String {
  case error {
    InvalidDeclaration(problems) ->
      "docuconf: invalid declaration:\n"
      <> string.join(list.map(problems, fn(p) { "  - " <> p }), "\n")
    InvalidConfig(vs) -> {
      let n = list.length(vs)
      "docuconf: "
      <> int.to_string(n)
      <> " configuration problem"
      <> case n {
        1 -> ""
        _ -> "s"
      }
      <> ":\n"
      <> string.join(
        list.map(vs, fn(v) {
          "  - "
          <> v.input
          <> " ["
          <> code_to_string(v.code)
          <> "]: "
          <> v.message
        }),
        "\n",
      )
    }
  }
}

type Problem =
  #(Code, String)

// ---- variables ------------------------------------------------------------

/// A variable being declared. Finish it with `required`, `optional` or
/// `default`.
pub opaque type VarBuilder(a) {
  VarBuilder(
    meta: VarMeta,
    parse: fn(String) -> Result(a, Problem),
    check: fn(a) -> Result(Nil, Problem),
    encode: fn(a) -> Json,
    zero: a,
  )
}

/// A declared variable, ready for `env`.
pub opaque type Var(a) {
  Var(meta: VarMeta, read: fn(Option(String)) -> Result(a, Problem), zero: a)
}

fn builder(
  name: String,
  type_: String,
  description: String,
  parse: fn(String) -> Result(a, Problem),
  encode: fn(a) -> Json,
  zero: a,
) -> VarBuilder(a) {
  VarBuilder(
    meta: VarMeta(
      name:,
      type_:,
      description:,
      required: False,
      secret: False,
      group: None,
      examples: [],
      config_key: None,
      deprecated: None,
      fields: [],
      default: None,
      flag_warning: True,
      problems: [],
    ),
    parse:,
    check: fn(_) { Ok(Nil) },
    encode:,
    zero:,
  )
}

/// A string. An empty value is present (and fails `min_length` if set).
pub fn string(name: String, description: String) -> VarBuilder(String) {
  builder(name, "string", description, Ok, json.String, "")
}

/// A 64-bit integer, base 10.
///
/// On the JavaScript target an `Int` is a number, exact only within
/// ±(2^53 − 1). There the variable always exports `min` and `max` within
/// that range (SPEC §5), so the platform never accepts a value the app
/// cannot hold: `-9007199254740991` and `9007199254740991` unless
/// `min_int`/`max_int` narrow them, and wider bounds are declaration errors.
pub fn int(name: String, description: String) -> VarBuilder(Int) {
  let b = builder(name, "int", description, parse_int, json.Int, 0)
  case int_limits() {
    Error(Nil) -> b
    Ok(#(lo, hi)) ->
      b
      |> set_field("min", json.Int(lo))
      |> set_field("max", json.Int(hi))
      |> add_check(fn(v) { bound(v < lo || v > hi, outside_safe_range) })
  }
}

const outside_safe_range = "is outside ±9007199254740991, the integers the JavaScript target holds exactly"

// The integer range the target holds exactly: Error(Nil) on Erlang (any
// 64-bit integer), ±(2^53 - 1) on JavaScript.
@external(erlang, "docuconf_ffi", "int_limits")
@external(javascript, "./docuconf_ffi.mjs", "int_limits")
fn int_limits() -> Result(#(Int, Int), Nil)

fn within_limits(b: VarBuilder(a), n: Int, what: String) -> VarBuilder(a) {
  case int_limits() {
    Ok(#(lo, hi)) if n < lo || n > hi ->
      add_problem(
        b,
        what <> " " <> int.to_string(n) <> " " <> outside_safe_range,
      )
    _ -> b
  }
}

/// A finite decimal number; NaN and infinities are rejected.
pub fn float(name: String, description: String) -> VarBuilder(Float) {
  builder(name, "float", description, parse_float, json.Float, 0.0)
}

/// `true` or `false`, case-insensitive.
pub fn bool(name: String, description: String) -> VarBuilder(Bool) {
  builder(
    name,
    "bool",
    description,
    fn(s) {
      case string.lowercase(s) {
        "true" -> Ok(True)
        "false" -> Ok(False)
        _ -> Error(#(InvalidType, "is not true or false"))
      }
    },
    json.Bool,
    False,
  )
}

/// A Go-syntax duration such as `1m30s` (the `go` encoding).
pub fn duration(name: String, description: String) -> VarBuilder(Duration) {
  let b =
    builder(
      name,
      "duration",
      description,
      fn(s) {
        case duration.parse(s) {
          Ok(d) -> Ok(d)
          Error(Nil) ->
            Error(#(InvalidType, "is not a Go duration such as 1m30s"))
        }
      },
      fn(d) { json.String(duration.to_string(d)) },
      duration.nanoseconds(0),
    )
  set_field(b, "encoding", json.String("go"))
}

/// A URL with a `scheme://`.
pub fn url(name: String, description: String) -> VarBuilder(String) {
  builder(
    name,
    "url",
    description,
    fn(s) {
      case is_url(s) {
        True -> Ok(s)
        False -> Error(#(InvalidType, "is not a URL with a scheme://"))
      }
    },
    json.String,
    "",
  )
}

/// One of a fixed set of strings, each mapped to a value of your own type:
/// `enum("LOG_LEVEL", "Log level", [#("debug", Debug), #("info", Info)])`.
/// `values` must not be empty.
pub fn enum(
  name: String,
  description: String,
  values: List(#(String, a)),
) -> VarBuilder(a) {
  let zero = case values {
    [#(_, first), ..] -> first
    [] -> panic as "docuconf.enum: values must not be empty"
  }
  let strings = list.map(values, fn(v) { v.0 })
  builder(
    name,
    "enum",
    description,
    fn(s) {
      case list.key_find(values, s) {
        Ok(v) -> Ok(v)
        Error(Nil) ->
          Error(#(NotInEnum, "is not one of " <> string.join(strings, ", ")))
      }
    },
    fn(v) {
      case list.find(values, fn(pair) { pair.1 == v }) {
        Ok(#(s, _)) -> json.String(s)
        Error(Nil) -> json.Null
      }
    },
    zero,
  )
  |> set_field("values", json.array(strings, json.String))
}

/// A list of strings in the `csv` encoding, joined by `separator`
/// (usually `","`). Items are not trimmed.
pub fn string_list(
  name: String,
  description: String,
  separator separator: String,
) -> VarBuilder(List(String)) {
  list_builder(name, description, separator, "string", Ok, json.String)
}

/// A list of 64-bit integers in the `csv` encoding, joined by `separator`.
/// Bound each item with `item_min` and `item_max`.
///
/// On the JavaScript target the list always exports `itemMin` and `itemMax`
/// within ±(2^53 − 1), as `int` does for `min` and `max` (SPEC §5).
pub fn int_list(
  name: String,
  description: String,
  separator separator: String,
) -> VarBuilder(List(Int)) {
  let b = list_builder(name, description, separator, "int", parse_int, json.Int)
  case int_limits() {
    Error(Nil) -> b
    Ok(#(lo, hi)) ->
      b
      |> set_field("itemMin", json.Int(lo))
      |> set_field("itemMax", json.Int(hi))
      |> add_check(fn(l) {
        each_item(l, fn(v) { bound(v < lo || v > hi, outside_safe_range) })
      })
  }
}

fn list_builder(
  name: String,
  description: String,
  separator: String,
  items: String,
  parse_item: fn(String) -> Result(a, Problem),
  encode_item: fn(a) -> Json,
) -> VarBuilder(List(a)) {
  let b =
    builder(
      name,
      "list",
      description,
      fn(s) {
        string.split(s, separator)
        |> list.index_map(fn(item, i) { #(item, i) })
        |> list.try_map(fn(pair) {
          case parse_item(pair.0) {
            Ok(v) -> Ok(v)
            Error(#(code, msg)) ->
              Error(#(code, "item " <> int.to_string(pair.1 + 1) <> " " <> msg))
          }
        })
      },
      fn(l) { json.array(l, encode_item) },
      [],
    )
    |> set_field("items", json.String(items))
    |> set_field("encoding", json.String("csv"))
    |> set_field("separator", json.String(separator))
  case separator {
    "" -> add_problem(b, "separator must not be empty")
    _ -> b
  }
}

/// A JSON value decoded into your own type. `placeholder` is any value of
/// that type; docuconf passes it along when it walks the declaration to
/// export it or to collect every error. Attach the JSON Schema of the type
/// with `schema`, so the platform checks the same shape.
pub fn json(
  name: String,
  description: String,
  decoder: Decoder(a),
  placeholder: a,
  encode: fn(a) -> Json,
) -> VarBuilder(a) {
  builder(
    name,
    "json",
    description,
    fn(s) {
      case json_decode(s) {
        Error(_) -> Error(#(InvalidType, "is not valid JSON"))
        Ok(dyn) ->
          case decode.run(dyn, decoder) {
            Ok(v) -> Ok(v)
            Error(errors) ->
              Error(#(
                SchemaMismatch,
                "does not match its schema: " <> decode_errors(errors),
              ))
          }
      }
    },
    encode,
    placeholder,
  )
}

/// The JSON Schema of a `json` variable, exported in the contract.
pub fn schema(b: VarBuilder(a), schema: Json) -> VarBuilder(a) {
  case b.meta.type_ {
    "json" -> set_field(b, "schema", schema)
    _ -> add_problem(b, "schema only applies to json variables")
  }
}

fn decode_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(e) {
    "$"
    <> string.concat(list.map(e.path, fn(p) { "." <> p }))
    <> ": expected "
    <> e.expected
  })
  |> string.join("; ")
}

// ---- constraints ------------------------------------------------------------

fn set_field(b: VarBuilder(a), key: String, value: Json) -> VarBuilder(a) {
  let fields = case list.key_find(b.meta.fields, key) {
    Ok(_) -> list.key_set(b.meta.fields, key, value)
    Error(Nil) -> list.append(b.meta.fields, [#(key, value)])
  }
  VarBuilder(..b, meta: VarMeta(..b.meta, fields:))
}

fn add_problem(b: VarBuilder(a), problem: String) -> VarBuilder(a) {
  VarBuilder(
    ..b,
    meta: VarMeta(..b.meta, problems: list.append(b.meta.problems, [problem])),
  )
}

fn add_check(
  b: VarBuilder(a),
  check: fn(a) -> Result(Nil, Problem),
) -> VarBuilder(a) {
  let previous = b.check
  VarBuilder(..b, check: fn(v) {
    case previous(v) {
      Ok(Nil) -> check(v)
      e -> e
    }
  })
}

fn only(b: VarBuilder(a), types: List(String), what: String) -> VarBuilder(a) {
  case list.contains(types, b.meta.type_) {
    True -> b
    False ->
      add_problem(
        b,
        what <> " does not apply to a " <> b.meta.type_ <> " variable",
      )
  }
}

/// Minimum length in characters (string variables).
pub fn min_length(b: VarBuilder(String), n: Int) -> VarBuilder(String) {
  only(b, ["string"], "min_length")
  |> set_field("minLength", json.Int(n))
  |> add_check(fn(s) {
    let len = string.length(s)
    case len < n {
      True ->
        Error(#(
          OutOfRange,
          "is "
            <> int.to_string(len)
            <> " characters, shorter than minLength "
            <> int.to_string(n),
        ))
      False -> Ok(Nil)
    }
  })
}

/// Maximum length in characters (string variables).
pub fn max_length(b: VarBuilder(String), n: Int) -> VarBuilder(String) {
  only(b, ["string"], "max_length")
  |> set_field("maxLength", json.Int(n))
  |> add_check(fn(s) {
    let len = string.length(s)
    case len > n {
      True ->
        Error(#(
          OutOfRange,
          "is "
            <> int.to_string(len)
            <> " characters, longer than maxLength "
            <> int.to_string(n),
        ))
      False -> Ok(Nil)
    }
  })
}

/// An RE2 pattern the value must match somewhere; anchor it with `^`/`$`.
pub fn pattern(b: VarBuilder(String), pattern: String) -> VarBuilder(String) {
  let b =
    only(b, ["string"], "pattern")
    |> set_field("pattern", json.String(pattern))
  case re2.check(pattern) {
    Error(msg) ->
      add_problem(b, "pattern " <> json.quote(pattern) <> " " <> msg)
    Ok(Nil) ->
      add_check(b, fn(s) {
        case re2.matches(pattern, s) {
          True -> Ok(Nil)
          False ->
            Error(#(
              PatternMismatch,
              "does not match pattern " <> json.quote(pattern),
            ))
        }
      })
  }
}

pub fn min_int(b: VarBuilder(Int), n: Int) -> VarBuilder(Int) {
  set_field(b, "min", json.Int(n))
  |> within_limits(n, "min_int")
  |> add_check(fn(v) { bound(v < n, "below min " <> int.to_string(n)) })
}

pub fn max_int(b: VarBuilder(Int), n: Int) -> VarBuilder(Int) {
  set_field(b, "max", json.Int(n))
  |> within_limits(n, "max_int")
  |> add_check(fn(v) { bound(v > n, "above max " <> int.to_string(n)) })
}

/// The smallest item an int list may hold, exported as `itemMin`. An item
/// below it is `out_of_range`.
pub fn item_min(b: VarBuilder(List(Int)), n: Int) -> VarBuilder(List(Int)) {
  set_field(b, "itemMin", json.Int(n))
  |> within_limits(n, "item_min")
  |> add_check(fn(l) {
    each_item(l, fn(v) { bound(v < n, "below itemMin " <> int.to_string(n)) })
  })
}

/// The largest item an int list may hold, exported as `itemMax`. An item
/// above it is `out_of_range`.
pub fn item_max(b: VarBuilder(List(Int)), n: Int) -> VarBuilder(List(Int)) {
  set_field(b, "itemMax", json.Int(n))
  |> within_limits(n, "item_max")
  |> add_check(fn(l) {
    each_item(l, fn(v) { bound(v > n, "above itemMax " <> int.to_string(n)) })
  })
}

// Checks every item, naming the first that fails (counting from 1).
fn each_item(
  items: List(a),
  check: fn(a) -> Result(Nil, Problem),
) -> Result(Nil, Problem) {
  items
  |> list.index_map(fn(item, i) { #(item, i) })
  |> list.try_each(fn(pair) {
    case check(pair.0) {
      Ok(Nil) -> Ok(Nil)
      Error(#(code, msg)) ->
        Error(#(code, "item " <> int.to_string(pair.1 + 1) <> " " <> msg))
    }
  })
}

pub fn min_float(b: VarBuilder(Float), n: Float) -> VarBuilder(Float) {
  set_field(b, "min", json.Float(n))
  |> add_check(fn(v) { bound(v <. n, "below min " <> float.to_string(n)) })
}

pub fn max_float(b: VarBuilder(Float), n: Float) -> VarBuilder(Float) {
  set_field(b, "max", json.Float(n))
  |> add_check(fn(v) { bound(v >. n, "above max " <> float.to_string(n)) })
}

/// Minimum duration, in Go syntax (`"1s"`).
pub fn min_duration(
  b: VarBuilder(Duration),
  min: String,
) -> VarBuilder(Duration) {
  case duration.parse(min) {
    Error(Nil) ->
      add_problem(b, "min " <> json.quote(min) <> " is not a Go duration")
    Ok(d) ->
      set_field(b, "min", json.String(duration.to_string(d)))
      |> add_check(fn(v) {
        bound(
          duration.compare(v, d) == order.Lt,
          "below min " <> duration.to_string(d),
        )
      })
  }
}

/// Maximum duration, in Go syntax (`"5m"`).
pub fn max_duration(
  b: VarBuilder(Duration),
  max: String,
) -> VarBuilder(Duration) {
  case duration.parse(max) {
    Error(Nil) ->
      add_problem(b, "max " <> json.quote(max) <> " is not a Go duration")
    Ok(d) ->
      set_field(b, "max", json.String(duration.to_string(d)))
      |> add_check(fn(v) {
        bound(
          duration.compare(v, d) == order.Gt,
          "above max " <> duration.to_string(d),
        )
      })
  }
}

fn bound(bad: Bool, msg: String) -> Result(Nil, Problem) {
  case bad {
    True -> Error(#(OutOfRange, "is " <> msg))
    False -> Ok(Nil)
  }
}

/// The URL schemes allowed (url variables).
pub fn schemes(
  b: VarBuilder(String),
  schemes: List(String),
) -> VarBuilder(String) {
  let b = case schemes {
    [] -> add_problem(b, "schemes must not be empty")
    _ -> b
  }
  only(b, ["url"], "schemes")
  |> set_field("schemes", json.array(schemes, json.String))
  |> add_check(fn(s) {
    let scheme = case string.split_once(s, "://") {
      Ok(#(scheme, _)) -> scheme
      Error(Nil) -> ""
    }
    case list.contains(schemes, scheme) {
      True -> Ok(Nil)
      False ->
        Error(#(
          InvalidScheme,
          "scheme is not one of " <> string.join(schemes, ", "),
        ))
    }
  })
}

pub fn min_items(b: VarBuilder(List(a)), n: Int) -> VarBuilder(List(a)) {
  set_field(b, "minItems", json.Int(n))
  |> add_check(fn(l) {
    let len = list.length(l)
    case len < n {
      True ->
        Error(#(
          TooFewItems,
          "has "
            <> int.to_string(len)
            <> " items, fewer than minItems "
            <> int.to_string(n),
        ))
      False -> Ok(Nil)
    }
  })
}

pub fn max_items(b: VarBuilder(List(a)), n: Int) -> VarBuilder(List(a)) {
  set_field(b, "maxItems", json.Int(n))
  |> add_check(fn(l) {
    let len = list.length(l)
    case len > n {
      True ->
        Error(#(
          TooManyItems,
          "has "
            <> int.to_string(len)
            <> " items, more than maxItems "
            <> int.to_string(n),
        ))
      False -> Ok(Nil)
    }
  })
}

/// The value must come from a secret reference; it is never printed.
pub fn secret(b: VarBuilder(a)) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, secret: True))
}

pub fn group(b: VarBuilder(a), group: String) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, group: Some(group)))
}

pub fn examples(b: VarBuilder(a), examples: List(String)) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, examples:))
}

/// The app's own name for the setting, where it differs, for docs.
pub fn config_key(b: VarBuilder(a), key: String) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, config_key: Some(key)))
}

/// Marks the variable deprecated; a warning is printed when it is set.
pub fn deprecated(b: VarBuilder(a), message: String) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, deprecated: Some(message)))
}

/// Silences the feature-flag naming warning (SPEC §10) for a deliberate
/// deploy-time switch.
pub fn deploy_time_switch(b: VarBuilder(a)) -> VarBuilder(a) {
  VarBuilder(..b, meta: VarMeta(..b.meta, flag_warning: False))
}

// ---- finishing variables ----------------------------------------------------

fn parse_and_check(b: VarBuilder(a), raw: String) -> Result(a, Problem) {
  case b.parse(raw) {
    Ok(v) ->
      case b.check(v) {
        Ok(Nil) -> Ok(v)
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}

/// The platform must set the variable.
pub fn required(b: VarBuilder(a)) -> Var(a) {
  Var(
    meta: VarMeta(..b.meta, required: True),
    read: fn(raw) {
      case raw {
        None -> Error(#(MissingRequired, "required, but not set"))
        Some(s) -> parse_and_check(b, s)
      }
    },
    zero: b.zero,
  )
}

/// The variable may be unset; it is then `None`.
pub fn optional(b: VarBuilder(a)) -> Var(Option(a)) {
  Var(
    meta: b.meta,
    read: fn(raw) {
      case raw {
        None -> Ok(None)
        Some(s) ->
          case parse_and_check(b, s) {
            Ok(v) -> Ok(Some(v))
            Error(e) -> Error(e)
          }
      }
    },
    zero: None,
  )
}

/// The value used when the variable is unset. It must satisfy the
/// variable's own constraints, and a secret cannot have one.
pub fn default(b: VarBuilder(a), value: a) -> Var(a) {
  let problems = case b.meta.secret, b.check(value) {
    True, _ -> ["a secret must not have a default"]
    False, Ok(Nil) -> []
    False, Error(#(code, msg)) -> [
      "default does not satisfy the variable's constraints ("
      <> code_to_string(code)
      <> ": "
      <> msg
      <> ")",
    ]
  }
  Var(
    meta: VarMeta(
      ..b.meta,
      default: Some(b.encode(value)),
      problems: list.append(b.meta.problems, problems),
    ),
    read: fn(raw) {
      case raw {
        None -> Ok(value)
        Some(s) -> parse_and_check(b, s)
      }
    },
    zero: value,
  )
}

// ---- parsing ----------------------------------------------------------------

const digits = "0123456789"

fn all_digits(s: String) -> Bool {
  s != "" && list.all(string.to_graphemes(s), string.contains(digits, _))
}

fn parse_int(s: String) -> Result(Int, Problem) {
  let body = case s {
    "-" <> r | "+" <> r -> r
    r -> r
  }
  case all_digits(body) {
    False -> Error(#(InvalidType, "is not an integer"))
    True ->
      case fits_int64(s, body) {
        False -> Error(#(InvalidType, "is outside the 64-bit integer range"))
        True -> {
          let assert Ok(n) = int.parse(string.replace(s, "+", ""))
          case int_limits() {
            // Beyond 2^53 the parsed number is rounded, but still outside.
            Ok(#(lo, hi)) if n < lo || n > hi ->
              Error(#(OutOfRange, outside_safe_range))
            _ -> Ok(n)
          }
        }
      }
  }
}

// Compares digit strings, so the check is exact on JavaScript too (where
// integers beyond 2^53 lose precision).
fn fits_int64(s: String, digits: String) -> Bool {
  let digits = case trim_zeros(digits) {
    "" -> "0"
    d -> d
  }
  let limit = case s {
    "-" <> _ -> "9223372036854775808"
    _ -> "9223372036854775807"
  }
  case int.compare(string.length(digits), 19) {
    order.Lt -> True
    order.Gt -> False
    order.Eq -> string.compare(digits, limit) != order.Gt
  }
}

fn trim_zeros(s: String) -> String {
  case s {
    "0" <> rest -> trim_zeros(rest)
    _ -> s
  }
}

fn parse_float(s: String) -> Result(Float, Problem) {
  let bad = Error(#(InvalidType, "is not a finite decimal number"))
  let #(sign, body) = case s {
    "-" <> r -> #("-", r)
    "+" <> r -> #("", r)
    r -> #("", r)
  }
  let #(mantissa, exponent) = case
    string.split_once(string.lowercase(body), "e")
  {
    Ok(#(m, e)) -> #(m, Some(e))
    Error(Nil) -> #(body, None)
  }
  let #(whole, frac) = case string.split_once(mantissa, ".") {
    Ok(#(w, f)) -> #(w, f)
    Error(Nil) -> #(mantissa, "")
  }
  let exp_ok = case exponent {
    None -> True
    Some("-" <> e) | Some("+" <> e) | Some(e) -> all_digits(e)
  }
  let digits_ok =
    { whole == "" || all_digits(whole) }
    && { frac == "" || all_digits(frac) }
    && { whole != "" || frac != "" }
  case digits_ok && exp_ok {
    False -> bad
    True -> {
      let normal =
        sign
        <> zero_if_empty(whole)
        <> "."
        <> zero_if_empty(frac)
        <> case exponent {
          Some(e) -> "e" <> e
          None -> ""
        }
      case parse_float_ffi(normal) {
        Ok(f) -> Ok(f)
        Error(Nil) -> bad
      }
    }
  }
}

fn zero_if_empty(s: String) -> String {
  case s {
    "" -> "0"
    _ -> s
  }
}

fn parse_float_ffi(s: String) -> Result(Float, Nil) {
  // float.parse handles "1.0e5"; values too large to represent fail.
  case float.parse(s) {
    Ok(f) -> Ok(f)
    Error(Nil) -> Error(Nil)
  }
}

fn is_url(s: String) -> Bool {
  case string.split_once(s, "://") {
    Ok(#(scheme, rest)) ->
      case string.to_graphemes(scheme) {
        [first, ..others] ->
          string.contains(letters, first)
          && list.all(others, string.contains(letters <> digits <> "+.-", _))
          && rest != ""
          && !list.any(string.to_graphemes(rest), is_space)
        [] -> False
      }
    Error(Nil) -> False
  }
}

fn is_space(c: String) -> Bool {
  c == " "
  || c == "\t"
  || c == "\n"
  || c == "\r"
  || c == "\u{000C}"
  || c == "\u{000B}"
}

const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

// ---- files ------------------------------------------------------------------

/// A TLS key pair directory in the kubernetes.io/tls layout.
pub type Tls {
  Tls(dir: String, cert_file: String, key_file: String, ca_file: Option(String))
}

/// A PEM CA bundle.
pub type CaBundle {
  CaBundle(path: String, certificates: Int)
}

pub type KeyAlgorithm {
  Rsa
  Ecdsa
  Ed25519
}

pub type KeystoreFormat {
  Pkcs12
  Jks
}

type FileOpts {
  FileOpts(
    pattern: Option(String),
    min_length: Option(Int),
    max_length: Option(Int),
    dns_names: List(String),
    key_algorithms: List(String),
    min_remaining: Option(Duration),
    require_ca: Bool,
    min_certificates: Int,
    password_var: Option(String),
    keystore_format: String,
  )
}

type Loaded(a) {
  Missing
  Failed(List(Problem))
  Loaded(a)
}

/// A file input being declared. Finish it with `file_required` or
/// `file_optional`.
pub opaque type FileBuilder(a) {
  FileBuilder(
    meta: FileMeta,
    opts: FileOpts,
    load: fn(String, FileOpts, Context) -> Loaded(a),
    zero: a,
  )
}

/// A declared file input, ready for `file`.
pub opaque type File(a) {
  File(
    meta: FileMeta,
    load: fn(String, Context) -> Result(a, List(Problem)),
    zero: a,
  )
}

fn file_builder(
  name: String,
  type_: String,
  description: String,
  path: String,
  load: fn(String, FileOpts, Context) -> Loaded(a),
  zero: a,
) -> FileBuilder(a) {
  FileBuilder(
    meta: FileMeta(
      name:,
      type_:,
      format: None,
      description:,
      required: False,
      secret: type_ == "tls" || type_ == "keystore",
      group: None,
      path:,
      path_env: None,
      max_size: None,
      fields: [],
      problems: [],
    ),
    opts: FileOpts(
      pattern: None,
      min_length: None,
      max_length: None,
      dns_names: [],
      key_algorithms: [],
      min_remaining: None,
      require_ca: False,
      min_certificates: 1,
      password_var: None,
      keystore_format: "pkcs12",
    ),
    load:,
    zero:,
  )
}

/// A JSON config file decoded into your own type. As with `json`,
/// `placeholder` is any value of the type. Attach the type's JSON Schema
/// with `file_schema`.
pub fn config_file(
  name: String,
  description: String,
  path path: String,
  decoder decoder: Decoder(a),
  placeholder placeholder: a,
) -> FileBuilder(a) {
  config_file_with(
    name,
    description,
    path,
    "json",
    json_decode,
    decoder,
    placeholder,
  )
}

/// A YAML or TOML config file, read with a parser you supply (Gleam has none
/// built in), which turns the text into `Dynamic` for `decoder`.
pub fn config_file_with(
  name: String,
  description: String,
  path: String,
  format: String,
  parse: fn(String) -> Result(Dynamic, String),
  decoder: Decoder(a),
  placeholder: a,
) -> FileBuilder(a) {
  let b =
    file_builder(
      name,
      "config",
      description,
      path,
      fn(path, _opts, _ctx) {
        use text <- read_text(path)
        case parse(strip_bom(text)) {
          Error(why) ->
            Failed([
              #(
                FileMalformed,
                path
                  <> " is not valid "
                  <> string.uppercase(format)
                  <> " ("
                  <> why
                  <> ")",
              ),
            ])
          Ok(dyn) ->
            case decode.run(dyn, decoder) {
              Ok(v) -> Loaded(v)
              Error(errors) ->
                Failed([
                  #(
                    SchemaMismatch,
                    path
                      <> " does not match its schema: "
                      <> decode_errors(errors),
                  ),
                ])
            }
        }
      },
      placeholder,
    )
  let b = FileBuilder(..b, meta: FileMeta(..b.meta, format: Some(format)))
  case list.contains(["json", "yaml", "toml"], format) {
    True -> b
    False -> file_problem(b, "format must be json, yaml or toml")
  }
}

/// The JSON Schema of a config file's type, exported in the contract.
pub fn file_schema(b: FileBuilder(a), schema: Json) -> FileBuilder(a) {
  file_field(b, "schema", schema)
}

/// A TLS key pair directory: `tls.crt`, `tls.key`, and `ca.crt` with
/// `require_ca`.
pub fn tls(
  name: String,
  description: String,
  path dir: String,
) -> FileBuilder(Tls) {
  file_builder(name, "tls", description, dir, load_tls, Tls(dir, "", "", None))
}

/// Names the certificate must cover (a wildcard covers one label).
pub fn dns_names(b: FileBuilder(Tls), names: List(String)) -> FileBuilder(Tls) {
  FileBuilder(..b, opts: FileOpts(..b.opts, dns_names: names))
  |> file_field("dnsNames", json.array(names, json.String))
}

pub fn key_algorithms(
  b: FileBuilder(Tls),
  algorithms: List(KeyAlgorithm),
) -> FileBuilder(Tls) {
  let names =
    list.map(algorithms, fn(a) {
      case a {
        Rsa -> "RSA"
        Ecdsa -> "ECDSA"
        Ed25519 -> "Ed25519"
      }
    })
  FileBuilder(..b, opts: FileOpts(..b.opts, key_algorithms: names))
  |> file_field("keyAlgorithms", json.array(names, json.String))
}

/// The least validity the certificate must have left, in Go syntax.
pub fn min_remaining(b: FileBuilder(Tls), min: String) -> FileBuilder(Tls) {
  case duration.parse(min) {
    Error(Nil) ->
      file_problem(
        b,
        "min_remaining " <> json.quote(min) <> " is not a Go duration",
      )
    Ok(d) ->
      FileBuilder(..b, opts: FileOpts(..b.opts, min_remaining: Some(d)))
      |> file_field("minRemaining", json.String(duration.to_string(d)))
  }
}

/// The directory must hold `ca.crt`, and `tls.crt` must chain to it.
pub fn require_ca(b: FileBuilder(Tls)) -> FileBuilder(Tls) {
  FileBuilder(..b, opts: FileOpts(..b.opts, require_ca: True))
  |> file_field("requireCA", json.Bool(True))
}

/// One or more PEM CA certificates.
pub fn ca_bundle(
  name: String,
  description: String,
  path path: String,
) -> FileBuilder(CaBundle) {
  file_builder(
    name,
    "caBundle",
    description,
    path,
    fn(path, opts, _ctx) {
      use text <- read_text(path)
      let #(total, good) = pem_count(text)
      case total, good {
        0, _ -> Failed([#(FileMalformed, path <> " holds no PEM certificate")])
        t, g if g < t ->
          Failed([
            #(
              FileMalformed,
              path
                <> ": "
                <> int.to_string(t - g)
                <> " certificate(s) cannot be parsed",
            ),
          ])
        _, g if g < opts.min_certificates ->
          Failed([
            #(
              FileMalformed,
              path
                <> " holds "
                <> int.to_string(g)
                <> " certificate(s), needs at least "
                <> int.to_string(opts.min_certificates),
            ),
          ])
        _, g -> Loaded(CaBundle(path, g))
      }
    },
    CaBundle("", 0),
  )
}

pub fn min_certificates(
  b: FileBuilder(CaBundle),
  n: Int,
) -> FileBuilder(CaBundle) {
  FileBuilder(..b, opts: FileOpts(..b.opts, min_certificates: n))
  |> file_field("minCertificates", json.Int(n))
}

/// A PKCS#12 or JKS (or JCEKS) keystore. `password_var` names a declared
/// secret variable; when it is `None` or unset, the password is empty.
///
/// At boot the keystore is opened with that password on both targets:
/// neither OTP nor Node.js reads PKCS#12 or JKS, so docuconf parses the
/// file and verifies its integrity MAC (PKCS#12 with SHA-1 or SHA-2 MACs,
/// RFC 7292) or integrity digest (JKS, JCEKS). A match proves the password
/// is right and the file is intact; the keys are not decrypted. PBMAC1
/// MACs and BER indefinite-length PKCS#12 files are reported as
/// `keystore_unreadable`.
pub fn keystore(
  name: String,
  description: String,
  path path: String,
  format format: KeystoreFormat,
  password_var password_var: Option(String),
) -> FileBuilder(String) {
  let fmt = case format {
    Pkcs12 -> "pkcs12"
    Jks -> "jks"
  }
  let b =
    file_builder(
      name,
      "keystore",
      description,
      path,
      fn(path, opts, ctx: Context) {
        case read_file(path) {
          Error(why) -> Failed([unreadable(path, why)])
          Ok(bits) -> {
            let password = case opts.password_var {
              Some(var) -> dict.get(ctx.env, var) |> result.unwrap("")
              None -> ""
            }
            case keystore_verify(opts.keystore_format, bits, password) {
              Ok(Nil) -> Loaded(path)
              Error(why) -> {
                let via = case opts.password_var {
                  Some(var) -> " with the password from " <> var
                  None -> ""
                }
                Failed([
                  #(
                    KeystoreUnreadable,
                    path
                      <> ": cannot open the "
                      <> opts.keystore_format
                      <> " keystore"
                      <> via
                      <> " ("
                      <> why
                      <> ")",
                  ),
                ])
              }
            }
          }
        }
      },
      "",
    )
  let b =
    FileBuilder(
      ..b,
      meta: FileMeta(..b.meta, format: Some(fmt)),
      opts: FileOpts(..b.opts, password_var:, keystore_format: fmt),
    )
  case password_var {
    Some(v) -> file_field(b, "passwordVar", json.String(v))
    None -> b
  }
}

/// A text file, such as a licence key. The value is its content.
pub fn text(
  name: String,
  description: String,
  path path: String,
) -> FileBuilder(String) {
  file_builder(
    name,
    "text",
    description,
    path,
    fn(path, opts, _ctx) {
      use content <- read_text(path)
      let len = string.length(content)
      let problems =
        list.flatten([
          case opts.min_length {
            Some(n) if len < n -> [
              #(
                OutOfRange,
                path
                  <> ": content is shorter than minLength "
                  <> int.to_string(n),
              ),
            ]
            _ -> []
          },
          case opts.max_length {
            Some(n) if len > n -> [
              #(
                OutOfRange,
                path
                  <> ": content is longer than maxLength "
                  <> int.to_string(n),
              ),
            ]
            _ -> []
          },
          case opts.pattern {
            Some(p) ->
              case re2.matches(p, content) {
                True -> []
                False -> [
                  #(
                    PatternMismatch,
                    path <> ": content does not match pattern " <> json.quote(p),
                  ),
                ]
              }
            None -> []
          },
        ])
      case problems {
        [] -> Loaded(content)
        _ -> Failed(problems)
      }
    },
    "",
  )
}

/// An RE2 pattern a text file's content must match.
pub fn text_pattern(
  b: FileBuilder(String),
  pattern: String,
) -> FileBuilder(String) {
  let b =
    FileBuilder(..b, opts: FileOpts(..b.opts, pattern: Some(pattern)))
    |> file_field("pattern", json.String(pattern))
    |> file_only(["text"], "text_pattern")
  case re2.check(pattern) {
    Ok(Nil) -> b
    Error(msg) ->
      file_problem(b, "pattern " <> json.quote(pattern) <> " " <> msg)
  }
}

pub fn text_min_length(b: FileBuilder(String), n: Int) -> FileBuilder(String) {
  FileBuilder(..b, opts: FileOpts(..b.opts, min_length: Some(n)))
  |> file_field("minLength", json.Int(n))
  |> file_only(["text"], "text_min_length")
}

pub fn text_max_length(b: FileBuilder(String), n: Int) -> FileBuilder(String) {
  FileBuilder(..b, opts: FileOpts(..b.opts, max_length: Some(n)))
  |> file_field("maxLength", json.Int(n))
  |> file_only(["text"], "text_max_length")
}

/// Opaque bytes; only existence, readability and size are checked. The
/// value is the path.
pub fn binary(
  name: String,
  description: String,
  path path: String,
) -> FileBuilder(String) {
  file_builder(
    name,
    "binary",
    description,
    path,
    fn(path, _opts, _ctx) {
      case read_file(path) {
        Ok(_) -> Loaded(path)
        Error(why) -> Failed([unreadable(path, why)])
      }
    },
    "",
  )
}

/// An environment variable the platform sets to the path.
pub fn path_env(b: FileBuilder(a), name: String) -> FileBuilder(a) {
  FileBuilder(..b, meta: FileMeta(..b.meta, path_env: Some(name)))
}

/// Upper bound in bytes.
pub fn max_size(b: FileBuilder(a), bytes: Int) -> FileBuilder(a) {
  FileBuilder(..b, meta: FileMeta(..b.meta, max_size: Some(bytes)))
}

pub fn file_group(b: FileBuilder(a), group: String) -> FileBuilder(a) {
  FileBuilder(..b, meta: FileMeta(..b.meta, group: Some(group)))
}

/// The content must come from a secret store (always true for TLS and
/// keystores).
pub fn secret_file(b: FileBuilder(a)) -> FileBuilder(a) {
  FileBuilder(..b, meta: FileMeta(..b.meta, secret: True))
}

fn file_field(b: FileBuilder(a), key: String, value: Json) -> FileBuilder(a) {
  let fields = case list.key_find(b.meta.fields, key) {
    Ok(_) -> list.key_set(b.meta.fields, key, value)
    Error(Nil) -> list.append(b.meta.fields, [#(key, value)])
  }
  FileBuilder(..b, meta: FileMeta(..b.meta, fields:))
}

fn file_problem(b: FileBuilder(a), problem: String) -> FileBuilder(a) {
  FileBuilder(
    ..b,
    meta: FileMeta(..b.meta, problems: list.append(b.meta.problems, [problem])),
  )
}

fn file_only(
  b: FileBuilder(a),
  types: List(String),
  what: String,
) -> FileBuilder(a) {
  case list.contains(types, b.meta.type_) {
    True -> b
    False ->
      file_problem(
        b,
        what <> " does not apply to a " <> b.meta.type_ <> " file",
      )
  }
}

/// The file must be present.
pub fn file_required(b: FileBuilder(a)) -> File(a) {
  File(
    meta: FileMeta(..b.meta, required: True),
    load: fn(path, ctx) {
      case check_file(b, path, ctx) {
        Missing -> Error([#(FileMissing, path <> " not found")])
        Failed(ps) -> Error(ps)
        Loaded(v) -> Ok(v)
      }
    },
    zero: b.zero,
  )
}

/// The file may be absent; it is then `None`.
pub fn file_optional(b: FileBuilder(a)) -> File(Option(a)) {
  File(
    meta: b.meta,
    load: fn(path, ctx) {
      case check_file(b, path, ctx) {
        Missing -> Ok(None)
        Failed(ps) -> Error(ps)
        Loaded(v) -> Ok(Some(v))
      }
    },
    zero: None,
  )
}

fn check_file(b: FileBuilder(a), path: String, ctx: Context) -> Loaded(a) {
  case file_info(path) {
    Error("enoent") -> Missing
    Error(why) -> Failed([unreadable(path, why)])
    Ok(#(kind, size)) ->
      case b.meta.type_, kind {
        "tls", "directory" -> b.load(path, b.opts, ctx)
        "tls", _ ->
          Failed([
            #(
              FileMalformed,
              path <> " must be a directory holding tls.crt and tls.key",
            ),
          ])
        _, "directory" ->
          Failed([#(FileMalformed, path <> " is a directory, expected a file")])
        _, _ ->
          case b.meta.max_size {
            Some(max) if size > max ->
              Failed([
                #(
                  FileTooLarge,
                  path
                    <> " is "
                    <> int.to_string(size)
                    <> " bytes, more than maxSize "
                    <> int.to_string(max),
                ),
              ])
            _ -> b.load(path, b.opts, ctx)
          }
      }
  }
}

fn unreadable(path: String, why: String) -> Problem {
  let hint = case why {
    "eacces" ->
      "; a non-root container needs the pod's fsGroup set to read 0400 secret volumes"
    _ -> ""
  }
  #(FileUnreadable, path <> " cannot be read (" <> why <> ")" <> hint)
}

fn read_text(path: String, next: fn(String) -> Loaded(a)) -> Loaded(a) {
  case read_file(path) {
    Error(why) -> Failed([unreadable(path, why)])
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Ok(text) -> next(text)
        Error(Nil) ->
          Failed([#(FileMalformed, path <> " is not valid UTF-8 text")])
      }
  }
}

fn strip_bom(s: String) -> String {
  case s {
    "\u{FEFF}" <> rest -> rest
    _ -> s
  }
}

fn load_tls(dir: String, opts: FileOpts, ctx: Context) -> Loaded(Tls) {
  let crt = dir <> "/tls.crt"
  let key = dir <> "/tls.key"
  let ca = dir <> "/ca.crt"
  let read = fn(path) {
    case read_file(path) {
      Ok(bits) ->
        case bit_array.to_string(bits) {
          Ok(text) -> Ok(text)
          Error(Nil) -> Error(#(CertificateInvalid, path <> " is not PEM text"))
        }
      Error("enoent") -> Error(#(FileMissing, path <> " not found"))
      Error(why) -> Error(unreadable(path, why))
    }
  }
  let crt_text = read(crt)
  let key_text = read(key)
  let ca_text = case opts.require_ca {
    True -> read(ca)
    False -> Ok("")
  }
  case crt_text, key_text, ca_text {
    Ok(c), Ok(k), Ok(a) -> {
      let min_s = case opts.min_remaining {
        Some(d) -> duration.to_seconds(d)
        None -> 0
      }
      case
        tls_check(c, k, a, opts.dns_names, opts.key_algorithms, min_s, ctx.now)
      {
        [] ->
          Loaded(
            Tls(dir, crt, key, case opts.require_ca {
              True -> Some(ca)
              False -> None
            }),
          )
        problems ->
          Failed(list.map(problems, fn(p) { #(code_from_string(p.0), p.1) }))
      }
    }
    _, _, _ ->
      Failed(
        list.filter_map([crt_text, key_text, ca_text], fn(r) {
          case r {
            Error(p) -> Ok(p)
            Ok(_) -> Error(Nil)
          }
        }),
      )
  }
}

// ---- specs ------------------------------------------------------------------

type Context {
  Context(
    env: Dict(String, String),
    file_root: Option(String),
    now: Int,
    collect_only: Bool,
  )
}

/// A whole declaration, producing a value of type `a`.
pub opaque type Spec(a) {
  Spec(run: fn(Context) -> #(a, List(Meta), List(Violation)))
}

/// Finishes a declaration with the value built from its inputs.
pub fn succeed(value: a) -> Spec(a) {
  Spec(run: fn(_) { #(value, [], []) })
}

/// Reads a variable and passes its typed value on: `use port <- env(...)`.
pub fn env(var: Var(a), next: fn(a) -> Spec(b)) -> Spec(b) {
  Spec(run: fn(ctx: Context) {
    let m = var.meta
    let raw = case dict.get(ctx.env, m.name) {
      // SPEC §5: empty means unset for every type but string.
      Ok("") if m.type_ != "string" -> None
      Ok(s) -> Some(s)
      Error(Nil) -> None
    }
    let #(value, problems) = case ctx.collect_only {
      True -> #(var.zero, [])
      False ->
        case read_var(var, raw) {
          Ok(v) -> #(v, [])
          Error(#(code, msg)) -> #(var.zero, [
            Violation(m.name, VarKind, code, shown(m, raw, msg)),
          ])
        }
    }
    let #(b, metas, violations) = { next(value) }.run(ctx)
    #(b, [VarInput(m), ..metas], list.append(problems, violations))
  })
}

fn read_var(var: Var(a), raw: Option(String)) -> Result(a, Problem) {
  case var.meta.secret, raw {
    True, Some(value) ->
      case injector_scheme(value) {
        Ok(scheme) ->
          Error(#(
            InvalidType,
            "holds an unresolved "
              <> scheme
              <> " reference; the injector that should resolve it did not run",
          ))
        Error(Nil) -> var.read(raw)
      }
    _, _ -> var.read(raw)
  }
}

// SPEC §4.5.1 and §11.2: platforms inject secrets (Bank-Vaults vault-env,
// `op run`, vals) before the process starts. A secret that still holds a
// reference means the injector did not run. The message names the scheme,
// never the value.
fn injector_scheme(value: String) -> Result(String, Nil) {
  list.find(["vault:", "op://", "ref+"], string.starts_with(value, _))
}

fn shown(m: VarMeta, raw: Option(String), msg: String) -> String {
  case m.secret, raw {
    False, Some(r) -> json.quote(r) <> " " <> msg
    _, _ -> msg
  }
}

/// Checks a file input and passes its typed value on.
pub fn file(input: File(a), next: fn(a) -> Spec(b)) -> Spec(b) {
  Spec(run: fn(ctx: Context) {
    let m = input.meta
    let #(value, problems) = case ctx.collect_only {
      True -> #(input.zero, [])
      False ->
        case input.load(resolve_path(m, ctx), ctx) {
          Ok(v) -> #(v, [])
          Error(ps) -> #(
            input.zero,
            list.map(ps, fn(p) { Violation(m.name, FileKind, p.0, p.1) }),
          )
        }
    }
    let #(b, metas, violations) = { next(value) }.run(ctx)
    #(b, [FileInput(m), ..metas], list.append(problems, violations))
  })
}

fn resolve_path(m: FileMeta, ctx: Context) -> String {
  let path = case m.path_env {
    Some(name) ->
      case dict.get(ctx.env, name) {
        Ok(p) if p != "" -> p
        _ -> m.path
      }
    None -> m.path
  }
  case ctx.file_root, path {
    Some(root), "/" <> _ if root != "" -> root <> path
    _, _ -> path
  }
}

// ---- loading ----------------------------------------------------------------

/// Options for `load_with`.
pub opaque type Options {
  Options(
    env: Option(Dict(String, String)),
    file_root: Option(String),
    now: Option(Int),
    termination_log: Option(String),
    write_termination_log: Bool,
  )
}

pub fn options() -> Options {
  Options(None, None, None, None, True)
}

/// Reads this map instead of the process environment (tests).
pub fn with_env(o: Options, env: Dict(String, String)) -> Options {
  Options(..o, env: Some(env))
}

/// Prefixed to every absolute file path (default `DOCUCONF_FILE_ROOT`).
pub fn with_file_root(o: Options, root: String) -> Options {
  Options(..o, file_root: Some(root))
}

/// The current time, in Unix seconds, for certificate checks (tests).
pub fn at_time(o: Options, unix_seconds: Int) -> Options {
  Options(..o, now: Some(unix_seconds))
}

/// Where to write violations (default `DOCUCONF_TERMINATION_LOG`, else
/// `/dev/termination-log` when it exists).
pub fn with_termination_log(o: Options, path: String) -> Options {
  Options(..o, termination_log: Some(path))
}

pub fn without_termination_log(o: Options) -> Options {
  Options(..o, write_termination_log: False)
}

/// Loads from the process environment and the declared files.
pub fn load(spec: Spec(a)) -> Result(a, Error) {
  load_with(spec, options())
}

/// Loads with options; see `options`.
pub fn load_with(spec: Spec(a), options: Options) -> Result(a, Error) {
  let #(_, metas, _) = spec.run(collect_context())
  case declaration_problems(metas) {
    [_, ..] as problems -> Error(InvalidDeclaration(problems))
    [] -> {
      let env = option.lazy_unwrap(options.env, envoy.all)
      let ctx =
        Context(
          env:,
          file_root: case options.file_root {
            Some(r) -> Some(r)
            None -> option.from_result(dict.get(env, "DOCUCONF_FILE_ROOT"))
          },
          now: option.lazy_unwrap(options.now, now_unix),
          collect_only: False,
        )
      list.each(warnings(metas, env), fn(w) {
        print_error("docuconf: warning: " <> w)
      })
      let #(value, _, violations) = spec.run(ctx)
      case violations {
        [] -> Ok(value)
        _ -> {
          let error = InvalidConfig(sort_violations(violations))
          write_log(describe(error), options)
          Error(error)
        }
      }
    }
  }
}

fn collect_context() -> Context {
  Context(env: dict.new(), file_root: None, now: 0, collect_only: True)
}

fn sort_violations(vs: List(Violation)) -> List(Violation) {
  list.sort(vs, fn(a, b) {
    case a.kind, b.kind {
      VarKind, FileKind -> order.Lt
      FileKind, VarKind -> order.Gt
      _, _ -> string.compare(a.input, b.input)
    }
  })
}

fn warnings(metas: List(Meta), env: Dict(String, String)) -> List(String) {
  list.flat_map(metas, fn(m) {
    case m {
      VarInput(v) ->
        list.flatten([
          case v.deprecated, dict.get(env, v.name) {
            Some(msg), Ok(_) -> [v.name <> " is deprecated: " <> msg]
            _, _ -> []
          },
          case v.secret, dict.get(env, v.name) {
            True, Ok(raw) ->
              case string.ends_with(raw, "\n") {
                True -> [
                  v.name
                  <> " ends with a newline; secrets created with --from-file often do (values are never trimmed)",
                ]
                False -> []
              }
            _, _ -> []
          },
        ])
      FileInput(_) -> []
    }
  })
}

fn write_log(message: String, options: Options) -> Nil {
  case options.write_termination_log {
    False -> Nil
    True -> {
      let target = case options.termination_log {
        Some(p) -> Some(p)
        None ->
          case envoy.get("DOCUCONF_TERMINATION_LOG") {
            Ok(p) if p != "" -> Some(p)
            _ ->
              case file_exists("/dev/termination-log") {
                True -> Some("/dev/termination-log")
                False -> None
              }
          }
      }
      case target {
        // Kubernetes reads at most 4096 bytes.
        Some(path) -> write_file(path, string.slice(message, 0, 4000))
        None -> Nil
      }
    }
  }
}

// ---- declaration checks -----------------------------------------------------

const reserved_dirs = [
  "/", "/app", "/bin", "/boot", "/dev", "/etc", "/etc/pki", "/etc/ssl",
  "/etc/ssl/certs", "/home", "/lib", "/lib64", "/opt", "/proc", "/root", "/run",
  "/sbin", "/srv", "/sys", "/tmp", "/usr", "/usr/lib", "/usr/local",
  "/usr/share", "/var", "/var/lib", "/var/run",
]

/// Problems with the declaration itself; empty when it is valid.
pub fn check_declaration(spec: Spec(a)) -> List(String) {
  let #(_, metas, _) = spec.run(collect_context())
  declaration_problems(metas)
}

fn declaration_problems(metas: List(Meta)) -> List(String) {
  let vars =
    list.filter_map(metas, fn(m) {
      case m {
        VarInput(v) -> Ok(v)
        _ -> Error(Nil)
      }
    })
  let files =
    list.filter_map(metas, fn(m) {
      case m {
        FileInput(f) -> Ok(f)
        _ -> Error(Nil)
      }
    })
  let var_names = list.map(vars, fn(v) { v.name })
  let var_problems =
    list.flat_map(vars, fn(v) {
      list.flatten([
        when(!env_name(v.name), "name must match ^[A-Z][A-Z0-9_]*$"),
        when(
          string.length(v.description) < 5,
          "description is required and must be at least 5 characters",
        ),
        when(v.secret && v.examples != [], "a secret must not have examples"),
        v.problems,
      ])
      |> list.map(fn(p) { "variable " <> v.name <> ": " <> p })
    })
  let file_problems =
    list.flat_map(files, fn(f) {
      list.flatten([
        when(
          !input_name(f.name),
          "input name must be a DNS label of at most 42 characters",
        ),
        when(
          string.length(f.description) < 5,
          "description is required and must be at least 5 characters",
        ),
        when(!abs_path(f.path), "path must be absolute and normalised"),
        case f.path_env {
          Some(e) ->
            list.flatten([
              when(!env_name(e), "path_env must match ^[A-Z][A-Z0-9_]*$"),
              when(
                list.contains(var_names, e),
                "path_env " <> e <> " must not also be declared as a variable",
              ),
            ])
          None -> []
        },
        when(
          abs_path(f.path) && list.contains(reserved_dirs, mount_dir(f)),
          "would be mounted at reserved directory " <> mount_dir(f),
        ),
        case f.type_, list.key_find(f.fields, "passwordVar") {
          "keystore", Ok(json.String(pw)) ->
            when(
              !list.any(vars, fn(v) { v.name == pw && v.secret }),
              "password_var " <> pw <> " must name a declared secret variable",
            )
          _, _ -> []
        },
        f.problems,
      ])
      |> list.map(fn(p) { "file " <> f.name <> ": " <> p })
    })
  let mounts =
    files
    |> list.filter(fn(f) { abs_path(f.path) })
    |> list.group(mount_dir)
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.filter_map(fn(pair) {
      case pair.1 {
        [_, _, ..] ->
          Ok(
            "file inputs "
            <> string.join(
              list.sort(list.map(pair.1, fn(f) { f.name }), string.compare),
              ", ",
            )
            <> " share mount directory "
            <> pair.0,
          )
        _ -> Error(Nil)
      }
    })
  list.flatten([
    var_problems,
    file_problems,
    duplicates(var_names, "variable"),
    duplicates(list.map(files, fn(f) { f.name }), "file input"),
    mounts,
  ])
}

fn when(cond: Bool, problem: String) -> List(String) {
  case cond {
    True -> [problem]
    False -> []
  }
}

fn duplicates(names: List(String), what: String) -> List(String) {
  names
  |> list.group(fn(n) { n })
  |> dict.to_list
  |> list.filter_map(fn(pair) {
    case pair.1 {
      [_, _, ..] -> Ok(what <> " " <> pair.0 <> " is declared more than once")
      _ -> Error(Nil)
    }
  })
  |> list.sort(string.compare)
}

fn env_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
      && list.all(rest, string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
        _,
      ))
    [] -> False
  }
}

fn input_name(name: String) -> Bool {
  let lower = "abcdefghijklmnopqrstuvwxyz"
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.length(name) <= 42
      && string.contains(lower, first)
      && list.all(rest, string.contains(lower <> "0123456789-", _))
      && !string.ends_with(name, "-")
    [] -> False
  }
}

fn abs_path(path: String) -> Bool {
  let chars =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"
  string.starts_with(path, "/")
  && string.length(path) > 1
  && list.all(string.to_graphemes(path), string.contains(chars, _))
  && !string.contains(path, "//")
  && !string.ends_with(path, "/")
  && !list.any(string.split(path, "/"), fn(seg) { seg == "." || seg == ".." })
}

fn mount_dir(f: FileMeta) -> String {
  case f.type_ {
    "tls" -> f.path
    _ ->
      case string.split(f.path, "/") |> list.reverse {
        [_, ..rest] ->
          case list.reverse(rest) |> string.join("/") {
            "" -> "/"
            d -> d
          }
        [] -> "/"
      }
  }
}

// ---- export -----------------------------------------------------------------

/// Renders the declaration as `contract.cue`. `name` is the service name (a
/// DNS label); the CUE package is the name with `-` replaced by `_`.
pub fn contract(spec: Spec(a), name name: String) -> Result(String, Error) {
  contract_with(spec, name, None, None)
}

pub fn contract_with(
  spec: Spec(a),
  name: String,
  package: Option(String),
  app_version: Option(String),
) -> Result(String, Error) {
  let #(_, metas, _) = spec.run(collect_context())
  let name_problems = case dns_label(name) {
    True -> []
    False -> ["service name " <> json.quote(name) <> " must be a DNS label"]
  }
  case list.append(name_problems, declaration_problems(metas)) {
    [_, ..] as problems -> Error(InvalidDeclaration(problems))
    [] -> {
      let vars =
        list.filter_map(metas, fn(m) {
          case m {
            VarInput(v) -> Ok(v)
            _ -> Error(Nil)
          }
        })
      let files =
        list.filter_map(metas, fn(m) {
          case m {
            FileInput(f) -> Ok(f)
            _ -> Error(Nil)
          }
        })
      let package = option.unwrap(package, string.replace(name, "-", "_"))
      Ok(cue.render(name, package, app_version, vars, files))
    }
  }
}

/// Writes `contract.cue` to `path`. Call it from a small module of your app
/// and run it with `gleam run -m my_app/contract`.
pub fn write_contract(
  spec: Spec(a),
  name name: String,
  to path: String,
) -> Result(Nil, Error) {
  case contract(spec, name:) {
    Ok(text) -> {
      write_file(path, text)
      Ok(Nil)
    }
    Error(e) -> Error(e)
  }
}

fn dns_label(name: String) -> Bool {
  let ok = "abcdefghijklmnopqrstuvwxyz0123456789-"
  name != ""
  && string.length(name) <= 63
  && list.all(string.to_graphemes(name), string.contains(ok, _))
  && !string.starts_with(name, "-")
  && !string.ends_with(name, "-")
}

/// Feature-flag-looking variable names (SPEC §10), for a build-time lint.
pub fn flag_warnings(spec: Spec(a)) -> List(String) {
  let #(_, metas, _) = spec.run(collect_context())
  list.filter_map(metas, fn(m) {
    case m {
      VarInput(v) ->
        case
          v.flag_warning
          && list.any(
            ["FF_", "FEATURE_", "FEATURE_FLAG_", "ENABLE_"],
            string.starts_with(v.name, _),
          )
        {
          True ->
            Ok(
              v.name
              <> " looks like a feature flag; flags that change without a rollout belong in a flag service (SPEC §10)",
            )
          False -> Error(Nil)
        }
      FileInput(_) -> Error(Nil)
    }
  })
}

// ---- FFI --------------------------------------------------------------------

@external(erlang, "docuconf_ffi", "json_decode")
@external(javascript, "./docuconf_ffi.mjs", "json_decode")
fn json_decode(text: String) -> Result(Dynamic, String)

@external(erlang, "docuconf_ffi", "read_file")
@external(javascript, "./docuconf_ffi.mjs", "read_file")
fn read_file(path: String) -> Result(BitArray, String)

@external(erlang, "docuconf_ffi", "file_info")
@external(javascript, "./docuconf_ffi.mjs", "file_info")
fn file_info(path: String) -> Result(#(String, Int), String)

@external(erlang, "docuconf_ffi", "write_file")
@external(javascript, "./docuconf_ffi.mjs", "write_file")
fn write_file(path: String, text: String) -> Nil

@external(erlang, "docuconf_ffi", "file_exists")
@external(javascript, "./docuconf_ffi.mjs", "file_exists")
fn file_exists(path: String) -> Bool

@external(erlang, "docuconf_ffi", "now_unix")
@external(javascript, "./docuconf_ffi.mjs", "now_unix")
fn now_unix() -> Int

@external(erlang, "docuconf_ffi", "print_error")
@external(javascript, "./docuconf_ffi.mjs", "print_error")
fn print_error(message: String) -> Nil

@external(erlang, "docuconf_ffi", "pem_count")
@external(javascript, "./docuconf_ffi.mjs", "pem_count")
fn pem_count(pem: String) -> #(Int, Int)

@external(erlang, "docuconf_ffi", "keystore_verify")
@external(javascript, "./docuconf_ffi.mjs", "keystore_verify")
fn keystore_verify(
  format: String,
  content: BitArray,
  password: String,
) -> Result(Nil, String)

@external(erlang, "docuconf_ffi", "tls_check")
@external(javascript, "./docuconf_ffi.mjs", "tls_check")
fn tls_check(
  cert: String,
  key: String,
  ca: String,
  dns_names: List(String),
  key_algorithms: List(String),
  min_remaining_seconds: Int,
  now: Int,
) -> List(#(String, String))
