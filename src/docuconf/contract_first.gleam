//// Contract-first mode (SPEC §11.2 item 11): validate an environment
//// against a contract given as JSON, with no Gleam declaration, and get
//// typed values back.
////
//// Write the contract in CUE and export it with `cue export --out json`,
//// or take the `contract.json` a platform hands you, then:
////
//// ```gleam
//// let assert Ok(values) =
////   contract_first.load(contract_json, docuconf.options())
//// let assert Ok(contract_first.IntValue(port)) = dict.get(values, "PORT")
//// ```
////
//// Each variable is declared through the same builders a Gleam declaration
//// uses (`docuconf.int`, `docuconf.min_int`, ...), so values are parsed and
//// checked by exactly the same code, and errors carry the same codes. Every
//// wire encoding of SPEC §5 is read: `csv`, `json` and `indexed` lists, and
//// `go`, `iso8601`, `seconds` and `timespan` durations.
////
//// Not covered: file inputs (a contract with `files` is rejected), and
//// `json` values are not checked against their JSON Schema.

import docuconf.{type Secret, type Spec, type Values, type Var, type VarBuilder}
import docuconf/duration.{type Duration}
import docuconf/json.{type Json}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result

/// The typed value of one variable.
pub type Value {
  /// An optional variable that is not set and has no default.
  Absent
  BoolValue(Bool)
  IntValue(Int)
  FloatValue(Float)
  /// A `string`, `url` or `enum` value.
  StringValue(String)
  DurationValue(Duration)
  /// A `list` of `StringValue` or `IntValue` items.
  ListValue(List(Value))
  JsonValue(Json)
  /// The value of a `secret: true` variable. It prints redacted; read it
  /// with `docuconf.reveal`.
  SecretValue(Secret(Value))
}

/// The value as JSON: `null` when absent, a duration in canonical Go form.
pub fn to_json(value: Value) -> Json {
  case value {
    Absent -> json.Null
    BoolValue(b) -> json.Bool(b)
    IntValue(i) -> json.Int(i)
    FloatValue(f) -> json.Float(f)
    StringValue(s) -> json.String(s)
    DurationValue(d) -> json.String(duration.to_string(d))
    ListValue(items) -> json.Array(list.map(items, to_json))
    JsonValue(j) -> j
    SecretValue(s) -> to_json(docuconf.reveal(s))
  }
}

/// Loads the environment (as `docuconf.load_with` does, from `options`)
/// against a contract given as JSON text. Returns the value of every
/// variable, keyed by name, or every problem found.
pub fn load(
  contract: String,
  options: docuconf.Options,
) -> Result(Dict(String, Value), docuconf.Error) {
  case json.parse(contract) {
    Error(why) ->
      Error(
        docuconf.InvalidDeclaration([
          "contract is not valid JSON (" <> why <> ")",
        ]),
      )
    Ok(contract) -> result.try(spec(contract), docuconf.load_with(_, options))
  }
}

/// The declaration a contract describes, for `docuconf.load_with`,
/// `docuconf.check_declaration` or `docuconf.contract`.
pub fn spec(
  contract: Json,
) -> Result(Spec(Dict(String, Value)), docuconf.Error) {
  let fields = case contract {
    json.Object(fields) -> Ok(fields)
    _ -> Error(["contract must be a JSON object"])
  }
  let built = {
    use fields <- result.try(fields)
    let files = case list.key_find(fields, "files") {
      Ok(json.Object([_, ..])) -> [
        "file inputs are not supported in contract-first mode",
      ]
      _ -> []
    }
    use vars <- result.try(case list.key_find(fields, "vars") {
      Ok(json.Object(vars)) -> Ok(vars)
      Error(Nil) -> Ok([])
      Ok(_) -> Error(["vars must be an object"])
    })
    let #(declared, problems) =
      list.fold(vars, #([], files), fn(acc, pair) {
        let #(name, def) = pair
        case declare(name, def) {
          Ok(var) -> #([#(name, var), ..acc.0], acc.1)
          Error(p) -> #(acc.0, ["variable " <> name <> ": " <> p, ..acc.1])
        }
      })
    case problems {
      [] -> Ok(build(list.reverse(declared), []))
      _ -> Error(list.reverse(problems))
    }
  }
  result.map_error(built, docuconf.InvalidDeclaration)
}

fn build(
  vars: List(#(String, Var(Value))),
  handles: List(#(String, fn(Values) -> Value)),
) -> Spec(Dict(String, Value)) {
  case vars {
    [] -> {
      use v <- docuconf.build
      dict.from_list(list.map(handles, fn(h) { #(h.0, h.1(v)) }))
    }
    [#(name, var), ..rest] -> {
      use value <- docuconf.env(var)
      build(rest, [#(name, value), ..handles])
    }
  }
}

// ---- one variable -------------------------------------------------------------

type Def =
  List(#(String, Json))

fn declare(name: String, def: Json) -> Result(Var(Value), String) {
  use def <- result.try(case def {
    json.Object(fields) -> Ok(fields)
    _ -> Error("must be an object")
  })
  use type_ <- result.try(text(def, "type") |> required_field("type"))
  let description =
    text(def, "description") |> result.unwrap(Some("")) |> option.unwrap("")
  case type_ {
    "string" -> {
      let b = docuconf.string(name, description)
      use b <- result.try(apply(b, def, "minLength", whole, docuconf.min_length))
      use b <- result.try(apply(b, def, "maxLength", whole, docuconf.max_length))
      use b <- result.try(apply(b, def, "pattern", text, docuconf.pattern))
      finish(b, def, StringValue, string_of)
    }
    "int" -> {
      let b = docuconf.int(name, description)
      use b <- result.try(apply(b, def, "min", whole, docuconf.min_int))
      use b <- result.try(apply(b, def, "max", whole, docuconf.max_int))
      finish(b, def, IntValue, int_of)
    }
    "float" -> {
      let b = docuconf.float(name, description)
      use b <- result.try(apply(b, def, "min", number, docuconf.min_float))
      use b <- result.try(apply(b, def, "max", number, docuconf.max_float))
      finish(b, def, FloatValue, float_of)
    }
    "bool" -> finish(docuconf.bool(name, description), def, BoolValue, bool_of)
    "duration" -> {
      use encoding <- result.try(duration_encoding(def))
      let b = docuconf.duration_with(name, description, encoding:)
      use b <- result.try(apply(b, def, "min", span, docuconf.min_duration))
      use b <- result.try(apply(b, def, "max", span, docuconf.max_duration))
      finish(b, def, DurationValue, duration_of)
    }
    "url" -> {
      let b = docuconf.url(name, description)
      use b <- result.try(apply(b, def, "schemes", strings, docuconf.schemes))
      use b <- result.try(apply(b, def, "maxLength", whole, docuconf.max_length))
      finish(b, def, StringValue, string_of)
    }
    "enum" -> {
      use values <- result.try(
        strings(def, "values") |> required_field("values"),
      )
      case values {
        [] -> Error("values must not be empty")
        _ ->
          docuconf.enum(name, description, list.map(values, fn(v) { #(v, v) }))
          |> finish(def, StringValue, string_of)
      }
    }
    "list" -> declare_list(name, description, def)
    "json" -> {
      let b =
        docuconf.json(name, description, decoder: json.decoder(), encode: fn(j) {
          j
        })
      use b <- result.try(apply(b, def, "schema", any, docuconf.schema))
      use b <- result.try(apply(b, def, "maxLength", whole, docuconf.max_length))
      finish(b, def, JsonValue, Ok)
    }
    other -> Error("unknown type " <> json.quote(other))
  }
}

fn declare_list(
  name: String,
  description: String,
  def: Def,
) -> Result(Var(Value), String) {
  use encoding <- result.try(list_encoding(def))
  use items <- result.try(text(def, "items") |> required_field("items"))
  let bounds = fn(b: VarBuilder(List(a))) {
    use b <- result.try(apply(b, def, "minItems", whole, docuconf.min_items))
    apply(b, def, "maxItems", whole, docuconf.max_items)
  }
  case items {
    "string" -> {
      use b <- result.try(
        bounds(docuconf.string_list_with(name, description, encoding:)),
      )
      use b <- result.try(no_item_bounds(b, def))
      use b <- result.try(apply(
        b,
        def,
        "itemMinLength",
        whole,
        docuconf.item_min_length,
      ))
      use b <- result.try(apply(
        b,
        def,
        "itemMaxLength",
        whole,
        docuconf.item_max_length,
      ))
      finish(b, def, fn(l) { ListValue(list.map(l, StringValue)) }, fn(j) {
        list_of(j, string_of)
      })
    }
    "int" -> {
      use b <- result.try(
        bounds(docuconf.int_list_with(name, description, encoding:)),
      )
      use b <- result.try(no_item_lengths(b, def))
      use b <- result.try(apply(b, def, "itemMin", whole, docuconf.item_min))
      use b <- result.try(apply(b, def, "itemMax", whole, docuconf.item_max))
      finish(b, def, fn(l) { ListValue(list.map(l, IntValue)) }, fn(j) {
        list_of(j, int_of)
      })
    }
    other -> Error("unknown list items " <> json.quote(other))
  }
}

fn no_item_bounds(b: VarBuilder(a), def: Def) -> Result(VarBuilder(a), String) {
  case list.key_find(def, "itemMin"), list.key_find(def, "itemMax") {
    Error(Nil), Error(Nil) -> Ok(b)
    _, _ -> Error("itemMin and itemMax only apply to int lists")
  }
}

fn no_item_lengths(
  b: VarBuilder(a),
  def: Def,
) -> Result(VarBuilder(a), String) {
  case
    list.key_find(def, "itemMinLength"),
    list.key_find(def, "itemMaxLength")
  {
    Error(Nil), Error(Nil) -> Ok(b)
    _, _ -> Error("itemMinLength and itemMaxLength only apply to string lists")
  }
}

fn list_encoding(def: Def) -> Result(docuconf.ListEncoding, String) {
  use encoding <- result.try(text(def, "encoding"))
  case option.unwrap(encoding, "csv") {
    "csv" -> {
      use separator <- result.try(text(def, "separator"))
      Ok(docuconf.Csv(option.unwrap(separator, ",")))
    }
    "json" -> Ok(docuconf.JsonArray)
    "indexed" -> Ok(docuconf.Indexed)
    other -> Error("unknown list encoding " <> json.quote(other))
  }
}

fn duration_encoding(def: Def) -> Result(docuconf.DurationEncoding, String) {
  use encoding <- result.try(text(def, "encoding"))
  case option.unwrap(encoding, "go") {
    "go" -> Ok(docuconf.Go)
    "iso8601" -> Ok(docuconf.Iso8601)
    "seconds" -> Ok(docuconf.Seconds)
    "timespan" -> Ok(docuconf.Timespan)
    other -> Error("unknown duration encoding " <> json.quote(other))
  }
}

/// Applies the secret flag, then finishes the variable as required, with
/// its default, or optional.
fn finish(
  b: VarBuilder(a),
  def: Def,
  wrap: fn(a) -> Value,
  default_of: fn(Json) -> Result(a, String),
) -> Result(Var(Value), String) {
  // Docs only (SPEC §4.2): checked with the declaration, never read at runtime.
  use b <- result.try(apply(b, def, "details", text, docuconf.details))
  use secret <- result.try(flag(def, "secret"))
  case secret, list.key_find(def, "default") {
    True, Ok(_) -> Error("a secret must not have a default")
    True, Error(Nil) ->
      finish_var(
        docuconf.secret(b),
        def,
        fn(s) { SecretValue(docuconf.map_secret(s, wrap)) },
        fn(_) { Error("a secret must not have a default") },
      )
    False, _ -> finish_var(b, def, wrap, default_of)
  }
}

fn finish_var(
  b: VarBuilder(a),
  def: Def,
  wrap: fn(a) -> Value,
  default_of: fn(Json) -> Result(a, String),
) -> Result(Var(Value), String) {
  use required <- result.try(flag(def, "required"))
  case required, list.key_find(def, "default") {
    True, _ -> Ok(docuconf.required(b) |> docuconf.map(wrap))
    False, Ok(j) -> {
      use value <- result.try(
        default_of(j) |> result.map_error(fn(e) { "default " <> e }),
      )
      Ok(docuconf.default(b, value) |> docuconf.map(wrap))
    }
    False, Error(Nil) ->
      Ok(
        docuconf.optional(b)
        |> docuconf.map(fn(o) {
          case o {
            Some(v) -> wrap(v)
            None -> Absent
          }
        }),
      )
  }
}

// ---- reading contract fields --------------------------------------------------

/// Applies a constraint when the field is present.
fn apply(
  b: VarBuilder(a),
  def: Def,
  key: String,
  read: fn(Def, String) -> Result(option.Option(v), String),
  with: fn(VarBuilder(a), v) -> VarBuilder(a),
) -> Result(VarBuilder(a), String) {
  case read(def, key) {
    Ok(Some(v)) -> Ok(with(b, v))
    Ok(None) -> Ok(b)
    Error(e) -> Error(e)
  }
}

fn required_field(
  r: Result(option.Option(v), String),
  key: String,
) -> Result(v, String) {
  case r {
    Ok(Some(v)) -> Ok(v)
    Ok(None) -> Error(key <> " is required")
    Error(e) -> Error(e)
  }
}

fn field(
  def: Def,
  key: String,
  convert: fn(Json) -> Result(v, String),
) -> Result(option.Option(v), String) {
  case list.key_find(def, key) {
    Error(Nil) -> Ok(None)
    Ok(j) ->
      case convert(j) {
        Ok(v) -> Ok(Some(v))
        Error(e) -> Error(key <> " " <> e)
      }
  }
}

fn text(def: Def, key: String) -> Result(option.Option(String), String) {
  field(def, key, string_of)
}

fn span(def: Def, key: String) -> Result(option.Option(Duration), String) {
  field(def, key, duration_of)
}

fn whole(def: Def, key: String) -> Result(option.Option(Int), String) {
  field(def, key, int_of)
}

fn number(def: Def, key: String) -> Result(option.Option(Float), String) {
  field(def, key, float_of)
}

fn strings(
  def: Def,
  key: String,
) -> Result(option.Option(List(String)), String) {
  field(def, key, list_of(_, string_of))
}

fn any(def: Def, key: String) -> Result(option.Option(Json), String) {
  field(def, key, Ok)
}

fn flag(def: Def, key: String) -> Result(Bool, String) {
  field(def, key, bool_of) |> result.map(option.unwrap(_, False))
}

fn string_of(j: Json) -> Result(String, String) {
  case j {
    json.String(s) -> Ok(s)
    _ -> Error("must be a string")
  }
}

fn int_of(j: Json) -> Result(Int, String) {
  case j {
    json.Int(i) -> Ok(i)
    _ -> Error("must be an integer")
  }
}

fn float_of(j: Json) -> Result(Float, String) {
  case j {
    json.Float(f) -> Ok(f)
    json.Int(i) -> Ok(int.to_float(i))
    _ -> Error("must be a number")
  }
}

fn bool_of(j: Json) -> Result(Bool, String) {
  case j {
    json.Bool(b) -> Ok(b)
    _ -> Error("must be true or false")
  }
}

fn duration_of(j: Json) -> Result(Duration, String) {
  use s <- result.try(string_of(j))
  duration.parse(s)
  |> result.replace_error("must be a Go duration such as 1m30s")
}

fn list_of(
  j: Json,
  item: fn(Json) -> Result(v, String),
) -> Result(List(v), String) {
  case j {
    json.Array(items) -> list.try_map(items, item)
    _ -> Error("must be a list")
  }
}
