//// A JSON Schema validator for contract-first mode's `json` variables: the
//// keywords SDK-generated schemas use, with JSON Schema draft 2020-12
//// semantics. A schema with any other keyword is rejected by `problems`
//// rather than partly enforced. Patterns are RE2 (SPEC §4.3), matched
//// anywhere in the string; lengths count Unicode code points.

import docuconf/internal/re2
import docuconf/json.{type Json}
import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

const supported = [
  "$schema", "$id", "$comment", "title", "description", "default", "examples",
  "format", "deprecated", "readOnly", "writeOnly", "type", "enum", "const",
  "properties", "required", "additionalProperties", "items", "minItems",
  "maxItems", "uniqueItems", "minimum", "maximum", "exclusiveMinimum",
  "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "pattern",
  "minProperties", "maxProperties", "anyOf", "oneOf", "allOf", "not",
]

const types = [
  "object", "array", "string", "integer", "number", "boolean", "null",
]

/// What makes `schema` unusable: unknown keywords, malformed keyword values
/// and patterns that are not RE2. Each starts with a JSON Pointer into the
/// schema. Empty when the schema can be enforced.
pub fn problems(schema: Json) -> List(String) {
  schema_problems(schema, "")
}

fn schema_problems(schema: Json, path: String) -> List(String) {
  case schema {
    json.Bool(_) -> []
    json.Object(fields) -> list.flat_map(fields, keyword_problems(_, path))
    _ -> [at(path) <> ": a schema must be an object or a boolean"]
  }
}

fn keyword_problems(field: #(String, Json), path: String) -> List(String) {
  let #(key, value) = field
  let here = path <> "/" <> pointer_escape(key)
  let bad = fn(what) { [here <> ": must be " <> what] }
  case list.contains(supported, key) {
    False -> [
      here
      <> ": keyword "
      <> key
      <> " is not supported by the docuconf validator",
    ]
    True ->
      case key, value {
        "properties", json.Object(props) ->
          list.flat_map(props, fn(p) {
            schema_problems(p.1, here <> "/" <> pointer_escape(p.0))
          })
        "properties", _ -> bad("an object of schemas")
        "items", _ | "not", _ | "additionalProperties", _ ->
          schema_problems(value, here)
        "anyOf", json.Array([_, ..] as schemas)
        | "oneOf", json.Array([_, ..] as schemas)
        | "allOf", json.Array([_, ..] as schemas)
        ->
          list.index_map(schemas, fn(s, i) {
            schema_problems(s, here <> "/" <> int.to_string(i))
          })
          |> list.flatten
        "anyOf", _ | "oneOf", _ | "allOf", _ ->
          bad("a non-empty array of schemas")
        "type", json.String(t) -> type_problems([json.String(t)], here)
        "type", json.Array([_, ..] as ts) -> type_problems(ts, here)
        "type", _ -> bad("a type name or a non-empty array of them")
        "enum", json.Array(_) -> []
        "enum", _ -> bad("an array")
        "required", json.Array(names) ->
          case list.all(names, is_string) {
            True -> []
            False -> bad("an array of strings")
          }
        "required", _ -> bad("an array of strings")
        "pattern", json.String(p) ->
          case re2.check(p) {
            Ok(Nil) -> []
            Error(why) -> [here <> ": " <> why]
          }
        "pattern", _ -> bad("a string")
        "minimum", _
        | "maximum", _
        | "exclusiveMinimum", _
        | "exclusiveMaximum", _
        ->
          case to_float(value) {
            Ok(_) -> []
            Error(Nil) -> bad("a number")
          }
        "multipleOf", _ ->
          case to_float(value) {
            Ok(f) if f >. 0.0 -> []
            _ -> bad("a number above 0")
          }
        "minLength", json.Int(n)
        | "maxLength", json.Int(n)
        | "minItems", json.Int(n)
        | "maxItems", json.Int(n)
        | "minProperties", json.Int(n)
        | "maxProperties", json.Int(n)
          if n >= 0
        -> []
        "minLength", _
        | "maxLength", _
        | "minItems", _
        | "maxItems", _
        | "minProperties", _
        | "maxProperties", _
        -> bad("a non-negative integer")
        "uniqueItems", json.Bool(_) | "deprecated", json.Bool(_) -> []
        "readOnly", json.Bool(_) | "writeOnly", json.Bool(_) -> []
        "uniqueItems", _ | "deprecated", _ | "readOnly", _ | "writeOnly", _ ->
          bad("true or false")
        // Annotations: $schema, $id, $comment, title, description, default,
        // examples, format and const take any value.
        _, _ -> []
      }
  }
}

fn type_problems(names: List(Json), here: String) -> List(String) {
  list.filter_map(names, fn(t) {
    case t {
      json.String(name) ->
        case list.contains(types, name) {
          True -> Error(Nil)
          False -> Ok(here <> ": unknown type " <> name)
        }
      _ -> Ok(here <> ": a type must be a string")
    }
  })
}

/// Validates `data` against a schema that has no `problems`. Returns every
/// violation as "<JSON Pointer>: <what is wrong>", empty when it matches.
/// Messages name keys and schema values, never values from `data`.
pub fn validate(schema: Json, data: Json) -> List(String) {
  check(schema, data, "")
}

fn check(schema: Json, data: Json, path: String) -> List(String) {
  case schema {
    json.Bool(True) -> []
    json.Bool(False) -> [at(path) <> ": no value is allowed here"]
    json.Object(s) -> check_object_schema(s, data, path)
    _ -> []
  }
}

fn check_object_schema(
  s: List(#(String, Json)),
  data: Json,
  path: String,
) -> List(String) {
  let type_ok = case list.key_find(s, "type") {
    Ok(json.String(t)) -> Ok([t])
    Ok(json.Array(ts)) -> Ok(list.filter_map(ts, string_of))
    _ -> Error(Nil)
  }
  case type_ok {
    Ok(names) ->
      case list.any(names, has_type(data, _)) {
        False -> [
          at(path)
          <> ": expected "
          <> string.join(names, " or ")
          <> ", got "
          <> type_name(data),
        ]
        True -> check_keywords(s, data, path)
      }
    Error(Nil) -> check_keywords(s, data, path)
  }
}

fn check_keywords(
  s: List(#(String, Json)),
  data: Json,
  path: String,
) -> List(String) {
  let here = at(path)
  let enum_ = case list.key_find(s, "enum") {
    Ok(json.Array(options)) ->
      case list.any(options, equal(_, data)) {
        True -> []
        False -> [
          here
          <> ": must be one of "
          <> string.join(list.map(options, json.to_string), ", "),
        ]
      }
    _ -> []
  }
  let const_ = case list.key_find(s, "const") {
    Ok(c) ->
      case equal(c, data) {
        True -> []
        False -> [here <> ": must equal " <> json.to_string(c)]
      }
    Error(Nil) -> []
  }
  let shape = case data {
    json.Object(fields) -> check_fields(s, fields, path)
    json.Array(items) -> check_items(s, items, path)
    json.String(text) -> check_string(s, text, here)
    json.Int(_) | json.Float(_) -> check_number(s, data, here)
    _ -> []
  }
  let all_of = case list.key_find(s, "allOf") {
    Ok(json.Array(schemas)) -> list.flat_map(schemas, check(_, data, path))
    _ -> []
  }
  let matching = fn(schemas) {
    list.count(schemas, fn(sub) { check(sub, data, path) == [] })
  }
  let any_of = case list.key_find(s, "anyOf") {
    Ok(json.Array(schemas)) ->
      case matching(schemas) {
        0 -> [here <> ": matches none of the allowed shapes (anyOf)"]
        _ -> []
      }
    _ -> []
  }
  let one_of = case list.key_find(s, "oneOf") {
    Ok(json.Array(schemas)) ->
      case matching(schemas) {
        1 -> []
        n -> [
          here
          <> ": must match exactly one shape (oneOf), matches "
          <> int.to_string(n),
        ]
      }
    _ -> []
  }
  let not_ = case list.key_find(s, "not") {
    Ok(sub) ->
      case check(sub, data, path) {
        [] -> [here <> ": matches a disallowed shape (not)"]
        _ -> []
      }
    Error(Nil) -> []
  }
  list.flatten([enum_, const_, shape, all_of, any_of, one_of, not_])
}

fn check_fields(
  s: List(#(String, Json)),
  fields: List(#(String, Json)),
  path: String,
) -> List(String) {
  let here = at(path)
  let props = case list.key_find(s, "properties") {
    Ok(json.Object(props)) -> props
    _ -> []
  }
  let required = case list.key_find(s, "required") {
    Ok(json.Array(names)) ->
      list.filter_map(names, string_of)
      |> list.filter(fn(k) { result.is_error(list.key_find(fields, k)) })
      |> list.map(fn(k) { here <> ": missing required property " <> k })
    _ -> []
  }
  let each =
    list.flat_map(fields, fn(f) {
      let #(k, v) = f
      let child = path <> "/" <> pointer_escape(k)
      case list.key_find(props, k), list.key_find(s, "additionalProperties") {
        Ok(sub), _ -> check(sub, v, child)
        Error(Nil), Ok(json.Bool(False)) -> [
          here <> ": property " <> k <> " is not allowed",
        ]
        Error(Nil), Ok(sub) -> check(sub, v, child)
        Error(Nil), Error(Nil) -> []
      }
    })
  let n = list.length(fields)
  let counts =
    list.flatten([
      at_least(
        s,
        "minProperties",
        n,
        here <> ": needs at least ",
        " properties",
      ),
      at_most(s, "maxProperties", n, here <> ": allows at most ", " properties"),
    ])
  list.flatten([required, each, counts])
}

fn check_items(
  s: List(#(String, Json)),
  items: List(Json),
  path: String,
) -> List(String) {
  let here = at(path)
  let n = list.length(items)
  let has = ", has " <> int.to_string(n)
  let counts =
    list.flatten([
      at_least(s, "minItems", n, here <> ": needs at least ", " items" <> has),
      at_most(s, "maxItems", n, here <> ": allows at most ", " items" <> has),
    ])
  let unique = case list.key_find(s, "uniqueItems") {
    Ok(json.Bool(True)) ->
      case has_duplicate(items) {
        True -> [here <> ": items must be unique"]
        False -> []
      }
    _ -> []
  }
  let each = case list.key_find(s, "items") {
    Ok(sub) ->
      list.index_map(items, fn(v, i) {
        check(sub, v, path <> "/" <> int.to_string(i))
      })
      |> list.flatten
    Error(Nil) -> []
  }
  list.flatten([counts, unique, each])
}

fn check_string(
  s: List(#(String, Json)),
  text: String,
  here: String,
) -> List(String) {
  let n = list.length(string.to_utf_codepoints(text))
  let lengths =
    list.flatten([
      at_least(s, "minLength", n, here <> ": shorter than ", " characters"),
      at_most(s, "maxLength", n, here <> ": longer than ", " characters"),
    ])
  let pattern = case list.key_find(s, "pattern") {
    Ok(json.String(p)) ->
      case re2.matches(p, text) {
        True -> []
        False -> [here <> ": does not match pattern " <> p]
      }
    _ -> []
  }
  list.append(lengths, pattern)
}

fn check_number(
  s: List(#(String, Json)),
  data: Json,
  here: String,
) -> List(String) {
  let limit = fn(key, bad: fn(Json) -> Bool, what) {
    case list.key_find(s, key) {
      Ok(l) ->
        case bad(l) {
          True -> [here <> ": " <> what <> " " <> json.to_string(l)]
          False -> []
        }
      Error(Nil) -> []
    }
  }
  let cmp = fn(l, ok: fn(Int) -> Bool) { !ok(compare(data, l)) }
  list.flatten([
    limit("minimum", cmp(_, fn(c) { c >= 0 }), "below minimum"),
    limit("maximum", cmp(_, fn(c) { c <= 0 }), "above maximum"),
    limit("exclusiveMinimum", cmp(_, fn(c) { c > 0 }), "must be above"),
    limit("exclusiveMaximum", cmp(_, fn(c) { c < 0 }), "must be below"),
    limit("multipleOf", fn(m) { !multiple_of(data, m) }, "not a multiple of"),
  ])
}

// -1, 0 or 1 as a number compares with a bound; integers exactly.
fn compare(a: Json, b: Json) -> Int {
  case a, b {
    json.Int(x), json.Int(y) -> int.compare(x, y) |> order_int
    _, _ -> {
      let x = to_float(a) |> result.unwrap(0.0)
      let y = to_float(b) |> result.unwrap(0.0)
      float.compare(x, y) |> order_int
    }
  }
}

fn order_int(o) -> Int {
  case o {
    order.Lt -> -1
    order.Eq -> 0
    order.Gt -> 1
  }
}

fn multiple_of(data: Json, m: Json) -> Bool {
  case data, m {
    json.Int(_), json.Int(0) -> False
    json.Int(x), json.Int(y) -> x % y == 0
    _, _ -> {
      let x = to_float(data) |> result.unwrap(0.0)
      let y = to_float(m) |> result.unwrap(1.0)
      let q = x /. y
      y != 0.0 && q == float.floor(q)
    }
  }
}

fn at_least(
  s: List(#(String, Json)),
  key: String,
  n: Int,
  before: String,
  after: String,
) -> List(String) {
  case list.key_find(s, key) {
    Ok(json.Int(min)) if n < min -> [before <> int.to_string(min) <> after]
    _ -> []
  }
}

fn at_most(
  s: List(#(String, Json)),
  key: String,
  n: Int,
  before: String,
  after: String,
) -> List(String) {
  case list.key_find(s, key) {
    Ok(json.Int(max)) if n > max -> [before <> int.to_string(max) <> after]
    _ -> []
  }
}

fn has_type(data: Json, name: String) -> Bool {
  case name, data {
    "object", json.Object(_) -> True
    "array", json.Array(_) -> True
    "string", json.String(_) -> True
    "integer", json.Int(_) -> True
    "integer", json.Float(f) -> f == float.floor(f)
    "number", json.Int(_) | "number", json.Float(_) -> True
    "boolean", json.Bool(_) -> True
    "null", json.Null -> True
    _, _ -> False
  }
}

fn type_name(data: Json) -> String {
  case data {
    json.Object(_) -> "object"
    json.Array(_) -> "array"
    json.String(_) -> "string"
    json.Int(_) -> "integer"
    json.Float(_) -> "number"
    json.Bool(_) -> "boolean"
    json.Null -> "null"
  }
}

/// JSON equality: numbers by value (1 equals 1.0), objects in any order.
fn equal(a: Json, b: Json) -> Bool {
  case a, b {
    json.Int(_), json.Float(_) | json.Float(_), json.Int(_) ->
      to_float(a) == to_float(b)
    json.Array(xs), json.Array(ys) ->
      list.length(xs) == list.length(ys)
      && list.all(list.zip(xs, ys), fn(p) { equal(p.0, p.1) })
    json.Object(xs), json.Object(ys) ->
      list.length(xs) == list.length(ys)
      && list.all(xs, fn(f) {
        case list.key_find(ys, f.0) {
          Ok(y) -> equal(f.1, y)
          Error(Nil) -> False
        }
      })
    _, _ -> a == b
  }
}

fn has_duplicate(items: List(Json)) -> Bool {
  case items {
    [] -> False
    [x, ..rest] -> list.any(rest, equal(x, _)) || has_duplicate(rest)
  }
}

fn to_float(j: Json) -> Result(Float, Nil) {
  case j {
    json.Int(i) -> Ok(int.to_float(i))
    json.Float(f) -> Ok(f)
    _ -> Error(Nil)
  }
}

fn string_of(j: Json) -> Result(String, Nil) {
  case j {
    json.String(s) -> Ok(s)
    _ -> Error(Nil)
  }
}

fn is_string(j: Json) -> Bool {
  result.is_ok(string_of(j))
}

fn at(path: String) -> String {
  case path {
    "" -> "/"
    p -> p
  }
}

// RFC 6901: ~ is ~0 and / is ~1 in a pointer segment.
fn pointer_escape(key: String) -> String {
  key |> string.replace("~", "~0") |> string.replace("/", "~1")
}
