//// JSON values, for JSON Schemas, `json` variable defaults and examples in
//// an exported contract. A small type of its own keeps docuconf free of a
//// JSON library dependency; objects keep their fields in the given order.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

pub type Json {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(Json))
  Object(List(#(String, Json)))
}

pub fn null() -> Json {
  Null
}

pub fn bool(b: Bool) -> Json {
  Bool(b)
}

pub fn int(i: Int) -> Json {
  Int(i)
}

pub fn float(f: Float) -> Json {
  Float(f)
}

pub fn string(s: String) -> Json {
  String(s)
}

pub fn array(items: List(a), of encode: fn(a) -> Json) -> Json {
  Array(list.map(items, encode))
}

pub fn object(fields: List(#(String, Json))) -> Json {
  Object(fields)
}

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
