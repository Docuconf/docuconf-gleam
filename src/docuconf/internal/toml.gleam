//// A TOML 1.0 reader for config files and overlays (SPEC §4.6, §4.7), read
//// into JSON values: key/value pairs with bare, quoted and dotted keys,
//// `[tables]` and `[[arrays of tables]]`, basic, literal and multi-line
//// strings, integers (decimal, `0x`, `0o`, `0b`, with `_`), floats, booleans,
//// arrays and inline tables. Dates and times are read as their text.
//// Infinite and NaN floats, which JSON cannot hold, are an error.

import docuconf/json.{type Json}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// A table under construction. `defined` is set once a [header] or a key
// defines it, so a second definition is an error; `fixed` marks inline
// tables and values, which cannot be extended.
type Node {
  Table(entries: List(#(String, Node)), defined: Bool, fixed: Bool)
  Tables(items: List(Node))
  Value(Json)
}

type State {
  State(root: Node, current: List(String), line: Int)
}

/// Parses TOML text into a JSON object, or says what is wrong.
pub fn parse(text: String) -> Result(Json, String) {
  let text = case text {
    "\u{FEFF}" <> rest -> rest
    _ -> text
  }
  let chars = string.to_graphemes(string.replace(text, "\r\n", "\n"))
  use state <- result.try(document(chars, State(Table([], True, False), [], 1)))
  Ok(to_json(state.root))
}

fn fail(line: Int, msg: String) -> Result(a, String) {
  Error("line " <> int.to_string(line) <> ": " <> msg)
}

fn document(chars: List(String), s: State) -> Result(State, String) {
  case skip_ws(chars) {
    [] -> Ok(s)
    ["\n", ..rest] -> document(rest, State(..s, line: s.line + 1))
    ["#", ..rest] -> document(skip_comment(rest), s)
    ["[", "[", ..rest] -> {
      use #(key, rest) <- result.try(key(skip_ws(rest), s.line, []))
      case skip_ws(rest) {
        ["]", "]", ..rest] -> {
          use root <- result.try(append_table(s.root, key, s.line))
          use rest <- result.try(end_of_line(rest, s.line))
          document(rest, State(root, key, s.line + 1))
        }
        _ -> fail(s.line, "expected ]] after an array of tables")
      }
    }
    ["[", ..rest] -> {
      use #(key, rest) <- result.try(key(skip_ws(rest), s.line, []))
      case skip_ws(rest) {
        ["]", ..rest] -> {
          use root <- result.try(define_table(s.root, key, s.line))
          use rest <- result.try(end_of_line(rest, s.line))
          document(rest, State(root, key, s.line + 1))
        }
        _ -> fail(s.line, "expected ] after a table name")
      }
    }
    chars -> {
      use #(path, rest) <- result.try(key(chars, s.line, []))
      case skip_ws(rest) {
        ["=", ..rest] -> {
          use #(v, rest, lines) <- result.try(value(skip_ws(rest), s.line))
          use root <- result.try(set_value(s.root, s.current, path, v, s.line))
          let line = s.line + lines
          use rest <- result.try(end_of_line(rest, line))
          document(rest, State(..s, root:, line: line + 1))
        }
        _ -> fail(s.line, "expected = after a key")
      }
    }
  }
}

fn skip_ws(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] -> skip_ws(rest)
    _ -> chars
  }
}

fn skip_comment(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..] -> chars
    [_, ..rest] -> skip_comment(rest)
  }
}

// After a value or header: spaces, an optional comment, then a newline or
// the end. Consumes the newline.
fn end_of_line(chars: List(String), line: Int) -> Result(List(String), String) {
  case skip_ws(chars) {
    [] -> Ok([])
    ["\n", ..rest] -> Ok(rest)
    ["#", ..rest] ->
      case skip_comment(rest) {
        ["\n", ..rest] -> Ok(rest)
        rest -> Ok(rest)
      }
    _ -> fail(line, "unexpected text after a value")
  }
}

// ---- keys -------------------------------------------------------------------

fn key(
  chars: List(String),
  line: Int,
  acc: List(String),
) -> Result(#(List(String), List(String)), String) {
  use #(part, rest) <- result.try(simple_key(chars, line))
  let acc = [part, ..acc]
  case skip_ws(rest) {
    [".", ..rest] -> key(skip_ws(rest), line, acc)
    _ -> Ok(#(list.reverse(acc), rest))
  }
}

fn simple_key(
  chars: List(String),
  line: Int,
) -> Result(#(String, List(String)), String) {
  case chars {
    ["\"", "\"", "\"", ..] | ["'", "'", "'", ..] ->
      fail(line, "a key cannot be a multi-line string")
    ["\"", ..rest] -> basic_string(rest, "", line)
    ["'", ..rest] -> literal_string(rest, "", line)
    _ -> {
      let #(bare, rest) = list.split_while(chars, is_bare)
      case bare {
        [] -> fail(line, "expected a key")
        _ -> Ok(#(string.concat(bare), rest))
      }
    }
  }
}

fn is_bare(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    c,
  )
  && c != ""
}

// ---- values -----------------------------------------------------------------

// A value, the rest of the input, and how many newlines it spanned.
fn value(
  chars: List(String),
  line: Int,
) -> Result(#(Json, List(String), Int), String) {
  case chars {
    ["\"", "\"", "\"", ..rest] -> {
      let #(rest, first) = drop_newline(rest)
      use #(s, after, n) <- result.try(ml_basic(rest, "", line, first))
      Ok(#(json.String(s), after, n))
    }
    ["'", "'", "'", ..rest] -> {
      let #(rest, first) = drop_newline(rest)
      use #(s, after, n) <- result.try(ml_literal(rest, "", line, first))
      Ok(#(json.String(s), after, n))
    }
    ["\"", ..rest] -> {
      use #(s, after) <- result.try(basic_string(rest, "", line))
      Ok(#(json.String(s), after, 0))
    }
    ["'", ..rest] -> {
      use #(s, after) <- result.try(literal_string(rest, "", line))
      Ok(#(json.String(s), after, 0))
    }
    ["[", ..rest] -> array(rest, line, [], 0)
    ["{", ..rest] -> inline_table(skip_ws(rest), line, Table([], True, True))
    ["t", "r", "u", "e", ..rest] -> Ok(#(json.Bool(True), rest, 0))
    ["f", "a", "l", "s", "e", ..rest] -> Ok(#(json.Bool(False), rest, 0))
    _ -> {
      let #(token, rest) = list.split_while(chars, is_atom)
      // A date-time may hold one space between the date and the time.
      let #(token, rest) = case token, rest {
        [_, _, _, _, "-", _, _, "-", _, _], [" ", d, ..more] -> {
          case string.contains("0123456789", d) && d != "" {
            True -> {
              let #(time, rest) = list.split_while([d, ..more], is_atom)
              #(list.flatten([token, [" "], time]), rest)
            }
            False -> #(token, rest)
          }
        }
        _, _ -> #(token, rest)
      }
      use v <- result.try(atom(string.concat(token), line))
      Ok(#(v, rest, 0))
    }
  }
}

// A newline right after the opening delimiter is not part of the string.
fn drop_newline(chars: List(String)) -> #(List(String), Int) {
  case chars {
    ["\n", ..rest] -> #(rest, 1)
    _ -> #(chars, 0)
  }
}

fn is_atom(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+.:",
    c,
  )
  && c != ""
}

fn atom(token: String, line: Int) -> Result(Json, String) {
  let bad = fail(line, "invalid value " <> json.quote(token))
  case token {
    "" -> fail(line, "missing value")
    "inf" | "+inf" | "-inf" | "nan" | "+nan" | "-nan" ->
      fail(line, "infinite and NaN numbers are not supported")
    "0x" <> d -> radix(d, 16, bad)
    "0o" <> d -> radix(d, 8, bad)
    "0b" <> d -> radix(d, 2, bad)
    _ ->
      case is_date(token) {
        True -> Ok(json.String(token))
        False -> number(token, bad)
      }
  }
}

fn radix(d: String, base: Int, bad: Result(Json, String)) {
  case underscores_ok(d) {
    False -> bad
    True ->
      case int.base_parse(string.replace(d, "_", ""), base) {
        Ok(n) -> Ok(json.Int(n))
        Error(Nil) -> bad
      }
  }
}

fn is_date(token: String) -> Bool {
  case string.to_graphemes(token) {
    [a, b, c, d, "-", e, f, "-", g, h, ..] ->
      list.all([a, b, c, d, e, f, g, h], is_digit)
    [a, b, ":", c, d, ":", e, f, ..] -> list.all([a, b, c, d, e, f], is_digit)
    _ -> False
  }
}

fn is_digit(c: String) -> Bool {
  c != "" && string.contains("0123456789", c)
}

// `_` only between digits.
fn underscores_ok(s: String) -> Bool {
  !string.starts_with(s, "_")
  && !string.ends_with(s, "_")
  && !string.contains(s, "__")
  && s != ""
}

fn number(token: String, bad: Result(Json, String)) -> Result(Json, String) {
  let #(sign, body) = case token {
    "-" <> r -> #("-", r)
    "+" <> r -> #("", r)
    r -> #("", r)
  }
  let digits_ok = fn(d: String) {
    d != ""
    && underscores_ok(d)
    && list.all(string.to_graphemes(string.replace(d, "_", "")), is_digit)
  }
  // Leading zeros are not allowed.
  let no_leading_zero = fn(d: String) {
    !{ string.starts_with(d, "0") && string.length(d) > 1 }
  }
  let #(mantissa, exponent) = case string.split_once(body, "e") {
    Ok(#(m, e)) -> #(m, Ok(e))
    Error(Nil) ->
      case string.split_once(body, "E") {
        Ok(#(m, e)) -> #(m, Ok(e))
        Error(Nil) -> #(body, Error(Nil))
      }
  }
  let #(whole, frac) = case string.split_once(mantissa, ".") {
    Ok(#(w, f)) -> #(w, Ok(f))
    Error(Nil) -> #(mantissa, Error(Nil))
  }
  let whole_ok = digits_ok(whole) && no_leading_zero(whole)
  case frac, exponent {
    Error(Nil), Error(Nil) ->
      case whole_ok {
        True -> {
          let assert Ok(n) = int.parse(sign <> string.replace(whole, "_", ""))
          Ok(json.Int(n))
        }
        False -> bad
      }
    _, _ -> {
      let frac_ok = case frac {
        Ok(f) -> digits_ok(f)
        Error(Nil) -> True
      }
      let exp_ok = case exponent {
        Ok("-" <> e) | Ok("+" <> e) | Ok(e) -> digits_ok(e)
        Error(Nil) -> True
      }
      case whole_ok && frac_ok && exp_ok {
        False -> bad
        True -> {
          let text =
            sign
            <> string.replace(whole, "_", "")
            <> "."
            <> case frac {
              Ok(f) -> string.replace(f, "_", "")
              Error(Nil) -> "0"
            }
            <> case exponent {
              Ok(e) -> "e" <> string.replace(e, "_", "")
              Error(Nil) -> ""
            }
          case float.parse(text) {
            Ok(f) -> Ok(json.Float(f))
            Error(Nil) -> bad
          }
        }
      }
    }
  }
}

fn array(
  chars: List(String),
  line: Int,
  acc: List(Json),
  lines: Int,
) -> Result(#(Json, List(String), Int), String) {
  case skip_ws(chars) {
    ["\n", ..rest] -> array(rest, line, acc, lines + 1)
    ["#", ..rest] -> array(skip_comment(rest), line, acc, lines)
    ["]", ..rest] -> Ok(#(json.Array(list.reverse(acc)), rest, lines))
    [] -> fail(line, "unclosed array")
    chars -> {
      use #(v, rest, n) <- result.try(value(chars, line + lines))
      array_sep(rest, line, [v, ..acc], lines + n)
    }
  }
}

fn array_sep(
  chars: List(String),
  line: Int,
  acc: List(Json),
  lines: Int,
) -> Result(#(Json, List(String), Int), String) {
  case skip_ws(chars) {
    ["\n", ..rest] -> array_sep(rest, line, acc, lines + 1)
    ["#", ..rest] -> array_sep(skip_comment(rest), line, acc, lines)
    [",", ..rest] -> array(rest, line, acc, lines)
    ["]", ..rest] -> Ok(#(json.Array(list.reverse(acc)), rest, lines))
    _ -> fail(line + lines, "expected , or ] in an array")
  }
}

fn inline_table(
  chars: List(String),
  line: Int,
  table: Node,
) -> Result(#(Json, List(String), Int), String) {
  case chars {
    ["}", ..rest] -> Ok(#(to_json(table), rest, 0))
    _ -> {
      use #(path, rest) <- result.try(key(chars, line, []))
      case skip_ws(rest) {
        ["=", ..rest] -> {
          use #(v, rest, _) <- result.try(value(skip_ws(rest), line))
          use table <- result.try(set_in(table, path, v, line, True))
          case skip_ws(rest) {
            [",", ..rest] -> inline_table(skip_ws(rest), line, table)
            ["}", ..rest] -> Ok(#(to_json(table), rest, 0))
            _ -> fail(line, "expected , or } in an inline table")
          }
        }
        _ -> fail(line, "expected = in an inline table")
      }
    }
  }
}

// ---- strings ----------------------------------------------------------------

fn basic_string(
  chars: List(String),
  acc: String,
  line: Int,
) -> Result(#(String, List(String)), String) {
  case chars {
    [] | ["\n", ..] -> fail(line, "unclosed string")
    ["\"", ..rest] -> Ok(#(acc, rest))
    ["\\", ..rest] -> {
      use #(s, rest) <- result.try(escape(rest, line))
      basic_string(rest, acc <> s, line)
    }
    [c, ..rest] -> basic_string(rest, acc <> c, line)
  }
}

fn literal_string(
  chars: List(String),
  acc: String,
  line: Int,
) -> Result(#(String, List(String)), String) {
  case chars {
    [] | ["\n", ..] -> fail(line, "unclosed string")
    ["'", ..rest] -> Ok(#(acc, rest))
    [c, ..rest] -> literal_string(rest, acc <> c, line)
  }
}

fn ml_basic(
  chars: List(String),
  acc: String,
  line: Int,
  lines: Int,
) -> Result(#(String, List(String), Int), String) {
  case chars {
    [] -> fail(line, "unclosed multi-line string")
    ["\"", "\"", "\"", "\"", "\"", ..rest] -> Ok(#(acc <> "\"\"", rest, lines))
    ["\"", "\"", "\"", "\"", ..rest] -> Ok(#(acc <> "\"", rest, lines))
    ["\"", "\"", "\"", ..rest] -> Ok(#(acc, rest, lines))
    ["\\", ..rest] ->
      case skip_ws(rest) {
        ["\n", ..] -> {
          let #(skipped, rest) =
            list.split_while(rest, fn(c) { c == " " || c == "\t" || c == "\n" })
          ml_basic(
            rest,
            acc,
            line,
            lines + list.count(skipped, fn(c) { c == "\n" }),
          )
        }
        _ -> {
          use #(s, rest) <- result.try(escape(rest, line + lines))
          ml_basic(rest, acc <> s, line, lines)
        }
      }
    ["\n", ..rest] -> ml_basic(rest, acc <> "\n", line, lines + 1)
    [c, ..rest] -> ml_basic(rest, acc <> c, line, lines)
  }
}

fn ml_literal(
  chars: List(String),
  acc: String,
  line: Int,
  lines: Int,
) -> Result(#(String, List(String), Int), String) {
  case chars {
    [] -> fail(line, "unclosed multi-line string")
    ["'", "'", "'", "'", "'", ..rest] -> Ok(#(acc <> "''", rest, lines))
    ["'", "'", "'", "'", ..rest] -> Ok(#(acc <> "'", rest, lines))
    ["'", "'", "'", ..rest] -> Ok(#(acc, rest, lines))
    ["\n", ..rest] -> ml_literal(rest, acc <> "\n", line, lines + 1)
    [c, ..rest] -> ml_literal(rest, acc <> c, line, lines)
  }
}

fn escape(
  chars: List(String),
  line: Int,
) -> Result(#(String, List(String)), String) {
  case chars {
    ["b", ..rest] -> Ok(#("\u{0008}", rest))
    ["t", ..rest] -> Ok(#("\t", rest))
    ["n", ..rest] -> Ok(#("\n", rest))
    ["f", ..rest] -> Ok(#("\u{000C}", rest))
    ["r", ..rest] -> Ok(#("\r", rest))
    ["e", ..rest] -> Ok(#("\u{001B}", rest))
    ["\"", ..rest] -> Ok(#("\"", rest))
    ["\\", ..rest] -> Ok(#("\\", rest))
    ["u", ..rest] -> unicode(rest, 4, line)
    ["U", ..rest] -> unicode(rest, 8, line)
    _ -> fail(line, "invalid escape in a string")
  }
}

fn unicode(
  chars: List(String),
  n: Int,
  line: Int,
) -> Result(#(String, List(String)), String) {
  let digits = list.take(chars, n) |> string.concat
  let n_ok = string.length(digits) == n
  case int.base_parse(digits, 16) {
    Ok(code) if n_ok ->
      case string.utf_codepoint(code) {
        Ok(cp) -> Ok(#(string.from_utf_codepoints([cp]), list.drop(chars, n)))
        Error(Nil) -> fail(line, "invalid unicode escape")
      }
    _ -> fail(line, "invalid unicode escape")
  }
}

// ---- building the tree ------------------------------------------------------

fn find(entries: List(#(String, Node)), k: String) -> Result(Node, Nil) {
  list.key_find(entries, k)
}

fn put(entries: List(#(String, Node)), k: String, n: Node) {
  case list.key_find(entries, k) {
    Ok(_) -> list.key_set(entries, k, n)
    Error(Nil) -> list.append(entries, [#(k, n)])
  }
}

// Defines [a.b.c]: intermediate tables are created implicitly.
fn define_table(
  root: Node,
  path: List(String),
  line: Int,
) -> Result(Node, String) {
  walk(root, path, line, fn(node) {
    case node {
      Error(Nil) -> Ok(Table([], True, False))
      Ok(Table(e, False, False)) -> Ok(Table(e, True, False))
      Ok(_) ->
        fail(line, "table " <> string.join(path, ".") <> " is defined twice")
    }
  })
}

// Appends a table to [[a.b]].
fn append_table(
  root: Node,
  path: List(String),
  line: Int,
) -> Result(Node, String) {
  walk(root, path, line, fn(node) {
    case node {
      Error(Nil) -> Ok(Tables([Table([], True, False)]))
      Ok(Tables(items)) ->
        Ok(Tables(list.append(items, [Table([], True, False)])))
      Ok(_) ->
        fail(line, string.join(path, ".") <> " is not an array of tables")
    }
  })
}

// Walks to the parent of the last key (through the last table of an array
// of tables) and replaces the last key's node with `f` of the existing one.
fn walk(
  node: Node,
  path: List(String),
  line: Int,
  f: fn(Result(Node, Nil)) -> Result(Node, String),
) -> Result(Node, String) {
  case node, path {
    Table(entries, defined, fixed), [k] -> {
      use n <- result.try(f(find(entries, k)))
      Ok(Table(put(entries, k, n), defined, fixed))
    }
    Table(entries, defined, fixed), [k, ..rest] -> {
      let child = case find(entries, k) {
        Error(Nil) -> Ok(Table([], False, False))
        Ok(Table(_, _, False) as t) -> Ok(t)
        Ok(Tables(_) as t) -> Ok(t)
        Ok(_) -> fail(line, k <> " is not a table")
      }
      use child <- result.try(child)
      use child <- result.try(walk(child, rest, line, f))
      Ok(Table(put(entries, k, child), defined, fixed))
    }
    Tables(items), _ ->
      case list.reverse(items) {
        [last, ..others] -> {
          use last <- result.try(walk(last, path, line, f))
          Ok(Tables(list.reverse([last, ..others])))
        }
        [] -> fail(line, "empty array of tables")
      }
    _, _ -> fail(line, "cannot define " <> string.join(path, "."))
  }
}

// Sets key = value in the current table; a dotted key creates tables.
fn set_value(
  root: Node,
  current: List(String),
  path: List(String),
  v: Json,
  line: Int,
) -> Result(Node, String) {
  case current {
    [] -> set_in(root, path, v, line, False)
    _ ->
      walk(root, current, line, fn(node) {
        case node {
          Ok(t) -> set_in(t, path, v, line, False)
          Error(Nil) -> fail(line, "no current table")
        }
      })
  }
}

fn set_in(
  table: Node,
  path: List(String),
  v: Json,
  line: Int,
  inline: Bool,
) -> Result(Node, String) {
  case table, path {
    Tables(_), _ ->
      walk(table, path, line, fn(node) {
        case node {
          Error(Nil) -> Ok(Value(v))
          Ok(_) ->
            fail(line, "key " <> string.join(path, ".") <> " is set twice")
        }
      })
    Table(entries, defined, fixed), [k] ->
      case find(entries, k) {
        Error(Nil) -> Ok(Table(put(entries, k, Value(v)), defined, fixed))
        Ok(_) -> fail(line, "key " <> k <> " is set twice")
      }
    Table(entries, defined, fixed), [k, ..rest] -> {
      use child <- result.try(case find(entries, k) {
        Error(Nil) -> Ok(Table([], True, inline))
        Ok(Table(_, _, False) as t) -> Ok(t)
        Ok(_) -> fail(line, k <> " cannot be extended with a dotted key")
      })
      use child <- result.try(set_in(child, rest, v, line, inline))
      Ok(Table(put(entries, k, child), defined, fixed))
    }
    _, _ -> fail(line, "cannot set a value here")
  }
}

fn to_json(node: Node) -> Json {
  case node {
    Value(v) -> v
    Tables(items) -> json.Array(list.map(items, to_json))
    Table(entries, _, _) ->
      json.Object(list.map(entries, fn(e) { #(e.0, to_json(e.1)) }))
  }
}
