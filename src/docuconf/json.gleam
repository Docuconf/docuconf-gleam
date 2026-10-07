//// JSON values, for JSON Schemas, `json` variable defaults and examples in
//// an exported contract. A small type of its own keeps docuconf free of a
//// JSON library dependency; objects keep their fields in the given order.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// A JSON value. Build it with the constructors or the functions below.
pub type Json {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(Json))
  Object(List(#(String, Json)))
}

/// `null`.
pub fn null() -> Json {
  Null
}

/// `true` or `false`.
pub fn bool(b: Bool) -> Json {
  Bool(b)
}

/// An integer.
pub fn int(i: Int) -> Json {
  Int(i)
}

/// A number with a fraction.
pub fn float(f: Float) -> Json {
  Float(f)
}

/// A string.
pub fn string(s: String) -> Json {
  String(s)
}

/// An array, encoding each item: `array(["a", "b"], string)`.
pub fn array(items: List(a), of encode: fn(a) -> Json) -> Json {
  Array(list.map(items, encode))
}

/// An object; fields keep the order given.
pub fn object(fields: List(#(String, Json))) -> Json {
  Object(fields)
}

/// Parses JSON text. Object fields are sorted by name. On the JavaScript
/// target numbers are doubles, so integers beyond ±(2^53 − 1) are rounded.
pub fn parse(text: String) -> Result(Json, String) {
  case json_decode(text) {
    Error(why) -> Error(why)
    Ok(dyn) ->
      case decode.run(dyn, decoder()) {
        Ok(j) -> Ok(j)
        Error(_) -> Error("not a JSON value")
      }
  }
}

/// Decodes a JSON value already turned into `Dynamic` (by `json.decode` on
/// Erlang or `JSON.parse` on JavaScript). Object fields are sorted by name.
pub fn decoder() -> Decoder(Json) {
  use <- decode.recursive
  decode.one_of(decode.map(decode.bool, Bool), [
    decode.map(decode.int, Int),
    decode.map(decode.float, Float),
    decode.map(decode.string, String),
    decode.map(decode.list(decoder()), Array),
    decode.map(decode.dict(decode.string, decoder()), fn(d) {
      Object(
        dict.to_list(d) |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
      )
    }),
    decode.map(decode.optional(decode.failure(Null, "null")), fn(_) { Null }),
  ])
}

@external(erlang, "docuconf_ffi", "json_decode")
@external(javascript, "../docuconf_ffi.mjs", "json_decode")
fn json_decode(text: String) -> Result(Dynamic, String)

/// Encodes compactly, as the `json` wire encoding expects.
pub fn to_string(j: Json) -> String {
  case j {
    Null -> "null"
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(i) -> int.to_string(i)
    Float(f) -> float.to_string(f)
    String(s) -> quote(s)
    Array(items) -> "[" <> string.join(list.map(items, to_string), ",") <> "]"
    Object(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(f) { quote(f.0) <> ":" <> to_string(f.1) }),
        ",",
      )
      <> "}"
  }
}

/// A JSON string literal, which is also a valid CUE string literal.
pub fn quote(s: String) -> String {
  "\"" <> escape(string.to_utf_codepoints(s), "") <> "\""
}

fn escape(cps: List(UtfCodepoint), acc: String) -> String {
  case cps {
    [] -> acc
    [cp, ..rest] -> {
      let n = string.utf_codepoint_to_int(cp)
      let piece = case n {
        0x22 -> "\\\""
        0x5C -> "\\\\"
        0x0A -> "\\n"
        0x0D -> "\\r"
        0x09 -> "\\t"
        _ if n < 0x20 ->
          "\\u" <> string.pad_start(int.to_base16(n), to: 4, with: "0")
        _ -> string.from_utf_codepoints([cp])
      }
      escape(rest, acc <> piece)
    }
  }
}
