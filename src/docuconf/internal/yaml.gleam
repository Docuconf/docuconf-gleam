//// A YAML reader for config files and overlays (SPEC §4.6, §4.7): the
//// subset config files use, read into JSON values. Block mappings and
//// sequences, flow collections (`[a, b]`, `{a: 1}`), plain, single- and
//// double-quoted scalars, literal (`|`) and folded (`>`) block scalars, and
//// comments. Plain scalars resolve with the YAML 1.2 core schema: `null`,
//// `~` and an empty value are null, `true`/`false` (any of the three
//// spellings) are booleans, and decimal, `0o` and `0x` integers and decimal
//// floats are numbers; everything else is a string.
////
//// Not supported, and reported as an error rather than misread: anchors and
//// aliases, tags, complex (`?`) keys, several documents in one file, and
//// infinite or NaN numbers, which JSON cannot hold.

import docuconf/json.{type Json}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

type Line {
  Line(number: Int, indent: Int, text: String)
}

/// Parses YAML text into a JSON value, or says what is wrong.
pub fn parse(text: String) -> Result(Json, String) {
  let text = case text {
    "\u{FEFF}" <> rest -> rest
    _ -> text
  }
  let raw =
    string.replace(text, "\r\n", "\n")
    |> string.split("\n")
    |> list.index_map(fn(l, i) { #(i + 1, l) })
  use raw <- result.try(documents(raw))
  use lines <- result.try(
    list.try_map(raw, fn(pair) {
      let #(n, l) = pair
      case string.contains(l, "\t") && string.trim_start(l) != l {
        True ->
          case leading_tab(l) {
            True -> Error(at(n, "tabs cannot indent YAML"))
            False -> Ok(Line(n, indent_of(l), drop_indent(l)))
          }
        False -> Ok(Line(n, indent_of(l), drop_indent(l)))
      }
    }),
  )
  case significant(lines) {
    [] -> Ok(json.Null)
    [first, ..] as lines -> {
      use #(value, rest) <- result.try(block(lines, first.indent))
      case significant(rest) {
        [] -> Ok(value)
        [l, ..] -> Error(at(l.number, "unexpected content"))
      }
    }
  }
}

fn leading_tab(l: String) -> Bool {
  case l {
    " " <> rest -> leading_tab(rest)
    "\t" <> _ -> True
    _ -> False
  }
}

// Drops a leading `---` and a trailing `...`; a second document is an error.
fn documents(
  lines: List(#(Int, String)),
) -> Result(List(#(Int, String)), String) {
  let is_marker = fn(l: String, m: String) {
    l == m
    || string.starts_with(l, m <> " ")
    || string.starts_with(l, m <> "\t")
  }
  let lines =
    list.drop_while(lines, fn(p) { blank_or_comment(p.1) || is_directive(p.1) })
  let lines = case lines {
    [#(n, first), ..rest] ->
      case is_marker(first, "---") {
        True -> [#(n, string.drop_start(first, 3)), ..rest]
        False -> lines
      }
    [] -> []
  }
  let #(body, after) = list.split_while(lines, fn(p) { !is_marker(p.1, "...") })
  case
    list.find(body, fn(p) { is_marker(p.1, "---") }),
    list.drop(after, 1) |> list.find(fn(p) { !blank_or_comment(p.1) })
  {
    Ok(#(n, _)), _ | _, Ok(#(n, _)) ->
      Error(at(n, "a file holds one YAML document"))
    _, _ -> Ok(body)
  }
}

fn is_directive(l: String) -> Bool {
  string.starts_with(l, "%")
}

fn blank_or_comment(l: String) -> Bool {
  let t = string.trim(l)
  t == "" || string.starts_with(t, "#")
}

fn indent_of(l: String) -> Int {
  string.length(l) - string.length(drop_indent(l))
}

fn drop_indent(l: String) -> String {
  case l {
    " " <> rest -> drop_indent(rest)
    _ -> l
  }
}

fn at(line: Int, msg: String) -> String {
  "line " <> int.to_string(line) <> ": " <> msg
}

fn significant(lines: List(Line)) -> List(Line) {
  list.drop_while(lines, fn(l) { blank_or_comment(l.text) })
}

// A block node whose first line is at `indent`.
fn block(
  lines: List(Line),
  indent: Int,
) -> Result(#(Json, List(Line)), String) {
  case significant(lines) {
    [] -> Ok(#(json.Null, []))
    [first, ..] as lines ->
      case is_seq_item(first.text) {
        True -> sequence(lines, first.indent, [])
        False ->
          case split_key(first.text) {
            Ok(_) -> mapping(lines, first.indent, [])
            Error(Nil) -> {
              let _ = indent
              scalar_block(lines, first.indent)
            }
          }
      }
  }
}

fn is_seq_item(text: String) -> Bool {
  text == "-" || string.starts_with(text, "- ")
}

// A scalar or flow collection that may continue on more indented lines.
fn scalar_block(
  lines: List(Line),
  indent: Int,
) -> Result(#(Json, List(Line)), String) {
  let assert [first, ..rest] = lines
  let #(more, rest) =
    list.split_while(rest, fn(l) { l.indent >= indent || l.text == "" })
  let more = list.filter(more, fn(l) { !blank_or_comment(l.text) })
  inline_value(first, more, rest, indent)
}

fn sequence(
  lines: List(Line),
  indent: Int,
  acc: List(Json),
) -> Result(#(Json, List(Line)), String) {
  case significant(lines) {
    [l, ..rest] if l.indent == indent ->
      case is_seq_item(l.text) {
        // A key at the list's indentation ends a list that is a value.
        False -> Ok(#(json.Array(list.reverse(acc)), lines))
        True -> {
          let content = drop_indent(string.drop_start(l.text, 1))
          let child_indent =
            indent + string.length(l.text) - string.length(content)
          use #(item, rest) <- result.try(case strip_comment(content) {
            "" -> nested(rest, indent, l.number)
            _ ->
              block(
                [Line(l.number, child_indent, content), ..rest],
                child_indent,
              )
          })
          sequence(rest, indent, [item, ..acc])
        }
      }
    [l, ..] if l.indent > indent -> Error(at(l.number, "bad indentation"))
    rest -> Ok(#(json.Array(list.reverse(acc)), rest))
  }
}

// The value of a key or item with nothing after it on its own line: a block
// on the following, more indented lines, or null.
fn nested(
  rest: List(Line),
  indent: Int,
  _line: Int,
) -> Result(#(Json, List(Line)), String) {
  case significant(rest) {
    [next, ..] if next.indent > indent -> block(rest, next.indent)
    _ -> Ok(#(json.Null, rest))
  }
}

fn mapping(
  lines: List(Line),
  indent: Int,
  acc: List(#(String, Json)),
) -> Result(#(Json, List(Line)), String) {
  case significant(lines) {
    [l, ..rest] if l.indent == indent && !{ l.text == "-" } ->
      case is_seq_item(l.text) {
        True -> Error(at(l.number, "a list item where a key belongs"))
        False ->
          case split_key(l.text) {
            Error(Nil) -> Error(at(l.number, "expected key: value"))
            Ok(#(raw_key, value_text)) -> {
              use key <- result.try(key_text(raw_key, l.number))
              use <- guard(
                list.key_find(acc, key) |> result.is_ok,
                at(l.number, "duplicate key " <> json.quote(key)),
              )
              use #(value, rest) <- result.try(case strip_comment(value_text) {
                "" ->
                  case significant(rest) {
                    // A list may sit at the key's own indentation.
                    [next, ..] if next.indent == indent ->
                      case is_seq_item(next.text) {
                        True -> sequence(rest, indent, [])
                        False -> Ok(#(json.Null, rest))
                      }
                    _ -> nested(rest, indent, l.number)
                  }
                "|" <> _ | ">" <> _ ->
                  block_scalar(strip_comment(value_text), rest, indent, l)
                _ -> {
                  let #(more, rest) =
                    list.split_while(rest, fn(m) {
                      m.indent > indent || m.text == ""
                    })
                  let more =
                    list.filter(more, fn(m) { !blank_or_comment(m.text) })
                  inline_value(
                    Line(l.number, indent, value_text),
                    more,
                    rest,
                    indent,
                  )
                }
              })
              mapping(rest, indent, [#(key, value), ..acc])
            }
          }
      }
    [l, ..] if l.indent > indent -> Error(at(l.number, "bad indentation"))
    rest -> Ok(#(json.Object(list.reverse(acc)), rest))
  }
}

fn guard(cond: Bool, msg: String, next: fn() -> Result(a, String)) {
  case cond {
    True -> Error(msg)
    False -> next()
  }
}

fn key_text(raw: String, line: Int) -> Result(String, String) {
  case raw {
    "\"" <> _ | "'" <> _ -> {
      use #(s, rest) <- result.try(quoted(raw, line))
      case string.trim(rest) {
        "" -> Ok(s)
        _ -> Error(at(line, "unexpected text after a quoted key"))
      }
    }
    "?" <> _ -> Error(at(line, "complex keys are not supported"))
    "&" <> _ | "*" <> _ | "!" <> _ ->
      Error(at(line, "anchors, aliases and tags are not supported"))
    "[" <> _ | "{" <> _ -> Error(at(line, "collections cannot be keys"))
    _ -> Ok(raw)
  }
}

// Splits `key: value` at the first `:` followed by a space or the end,
// outside quotes and brackets. Error when the line is not a mapping entry.
fn split_key(text: String) -> Result(#(String, String), Nil) {
  case text {
    "\"" <> _ | "'" <> _ ->
      case quoted(text, 0) {
        Ok(#(_, rest)) -> {
          let key_len = string.length(text) - string.length(rest)
          let key = string.slice(text, 0, key_len)
          case drop_indent(rest) {
            ":" -> Ok(#(key, ""))
            ":" <> after ->
              case after {
                " " <> v | "\t" <> v -> Ok(#(key, v))
                _ -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    "[" <> _ | "{" <> _ | "#" <> _ -> Error(Nil)
    _ -> plain_key(string.to_graphemes(text), "")
  }
}

fn plain_key(
  chars: List(String),
  acc: String,
) -> Result(#(String, String), Nil) {
  case chars {
    [] -> Error(Nil)
    [":"] -> Ok(#(string.trim_end(acc), ""))
    [":", " ", ..rest] | [":", "\t", ..rest] ->
      Ok(#(string.trim_end(acc), string.concat(rest)))
    [" ", "#", ..] -> Error(Nil)
    [c, ..rest] -> plain_key(rest, acc <> c)
  }
}

// Removes a trailing ` # comment` outside quotes, and surrounding spaces.
fn strip_comment(text: String) -> String {
  strip_loop(string.to_graphemes(text), "", Unquoted)
  |> string.trim
}

type Quote {
  Unquoted
  Single
  Double
}

fn strip_loop(chars: List(String), acc: String, q: Quote) -> String {
  case chars, q {
    [], _ -> acc
    ["#", ..], Unquoted if acc == "" -> acc
    [" ", "#", ..], Unquoted | ["\t", "#", ..], Unquoted -> acc
    ["\"", ..rest], Unquoted -> strip_loop(rest, acc <> "\"", Double)
    ["'", ..rest], Unquoted -> strip_loop(rest, acc <> "'", Single)
    ["\\", c, ..rest], Double -> strip_loop(rest, acc <> "\\" <> c, Double)
    ["\"", ..rest], Double -> strip_loop(rest, acc <> "\"", Unquoted)
    ["'", "'", ..rest], Single -> strip_loop(rest, acc <> "''", Single)
    ["'", ..rest], Single -> strip_loop(rest, acc <> "'", Unquoted)
    [c, ..rest], _ -> strip_loop(rest, acc <> c, q)
  }
}

// A value written after `key:` or `-`, continued on the `more` lines: a
// flow collection, a quoted scalar or a plain scalar.
fn inline_value(
  first: Line,
  more: List(Line),
  rest: List(Line),
  _indent: Int,
) -> Result(#(Json, List(Line)), String) {
  let text = strip_comment(first.text)
  case text {
    "[" <> _ | "{" <> _ -> {
      let whole =
        string.join(
          [text, ..list.map(more, fn(m) { strip_comment(m.text) })],
          " ",
        )
      use #(value, after) <- result.try(flow(whole, first.number))
      case string.trim(after) {
        "" -> Ok(#(value, rest))
        _ -> Error(at(first.number, "unexpected text after a flow collection"))
      }
    }
    "\"" <> _ | "'" <> _ -> {
      use <- guard(
        more != [],
        at(first.number, "multi-line quoted scalars are not supported"),
      )
      use #(s, after) <- result.try(quoted(text, first.number))
      case string.trim(after) {
        "" -> Ok(#(json.String(s), rest))
        _ -> Error(at(first.number, "unexpected text after a quoted scalar"))
      }
    }
    "&" <> _ | "*" <> _ | "!" <> _ ->
      Error(at(first.number, "anchors, aliases and tags are not supported"))
    "- " <> _ | "-" ->
      Error(at(first.number, "a list item cannot follow a key on its line"))
    _ -> {
      // A multi-line plain scalar folds its lines with spaces.
      let parts = [text, ..list.map(more, fn(m) { strip_comment(m.text) })]
      use <- guard(
        list.any(more, fn(m) { split_key(m.text) |> result.is_ok }),
        at(first.number, "bad indentation of a mapping entry"),
      )
      use <- guard(
        string.contains(text, ": "),
        at(first.number, "unexpected ': ' in a plain scalar"),
      )
      resolve(string.join(parts, " "), first.number)
      |> result.map(fn(v) { #(v, rest) })
    }
  }
}

fn block_scalar(
  header: String,
  rest: List(Line),
  indent: Int,
  l: Line,
) -> Result(#(Json, List(Line)), String) {
  let folded = string.starts_with(header, ">")
  let indicators = string.drop_start(header, 1)
  let chomp = case
    string.contains(indicators, "-"),
    string.contains(indicators, "+")
  {
    True, _ -> "strip"
    _, True -> "keep"
    _, _ -> "clip"
  }
  use <- guard(
    string.replace(string.replace(indicators, "-", ""), "+", "") != "",
    at(l.number, "explicit block indentation is not supported"),
  )
  let #(body, rest) =
    list.split_while(rest, fn(m) { m.indent > indent || m.text == "" })
  // Trailing blank lines belong to the scalar only for chomping.
  let content_indent = case list.find(body, fn(m) { m.text != "" }) {
    Ok(m) -> m.indent
    Error(Nil) -> indent + 1
  }
  let texts =
    list.map(body, fn(m) {
      case m.text {
        "" -> ""
        _ -> string.repeat(" ", m.indent - content_indent) <> m.text
      }
    })
  let #(trailing, content) =
    list.reverse(texts) |> list.split_while(fn(t) { t == "" })
  let content = list.reverse(content)
  let joined = case folded {
    False -> string.join(content, "\n")
    True -> fold_lines(content)
  }
  let value = case chomp, content {
    _, [] -> ""
    "strip", _ -> joined
    "clip", _ -> joined <> "\n"
    _, _ -> joined <> "\n" <> string.repeat("\n", list.length(trailing))
  }
  Ok(#(json.String(value), rest))
}

fn fold_lines(lines: List(String)) -> String {
  list.fold(lines, #("", False, True), fn(acc, line) {
    let #(out, prev_blank, first) = acc
    case first, line {
      True, _ -> #(line, line == "", False)
      _, "" -> #(out <> "\n", True, False)
      _, _ ->
        case prev_blank || string.starts_with(line, " ") {
          True -> #(out <> line, False, False)
          False -> #(out <> " " <> line, False, False)
        }
    }
  }).0
}

// ---- flow collections -----------------------------------------------------

fn flow(text: String, line: Int) -> Result(#(Json, String), String) {
  let text = drop_ws(text)
  case text {
    "[" <> rest -> flow_seq(drop_ws(rest), line, [])
    "{" <> rest -> flow_map(drop_ws(rest), line, [])
    "\"" <> _ | "'" <> _ -> {
      use #(s, rest) <- result.try(quoted(text, line))
      Ok(#(json.String(s), rest))
    }
    _ -> {
      let #(plain, rest) = flow_plain(string.to_graphemes(text), "")
      use <- guard(plain == "", at(line, "missing value in a flow collection"))
      use value <- result.try(resolve(string.trim(plain), line))
      Ok(#(value, rest))
    }
  }
}

fn drop_ws(s: String) -> String {
  case s {
    " " <> r | "\t" <> r | "\n" <> r -> drop_ws(r)
    _ -> s
  }
}

fn flow_plain(chars: List(String), acc: String) -> #(String, String) {
  case chars {
    [] -> #(acc, "")
    [",", ..] | ["]", ..] | ["}", ..] -> #(acc, string.concat(chars))
    [":", " ", ..] | [":", ",", ..] | [":", "]", ..] | [":", "}", ..] | [":"] -> #(
      acc,
      string.concat(chars),
    )
    [c, ..rest] -> flow_plain(rest, acc <> c)
  }
}

fn flow_seq(
  text: String,
  line: Int,
  acc: List(Json),
) -> Result(#(Json, String), String) {
  case text {
    "]" <> rest -> Ok(#(json.Array(list.reverse(acc)), rest))
    "" -> Error(at(line, "unclosed flow sequence"))
    _ -> {
      use #(item, rest) <- result.try(flow(text, line))
      case drop_ws(rest) {
        "," <> rest -> flow_seq(drop_ws(rest), line, [item, ..acc])
        "]" <> rest -> Ok(#(json.Array(list.reverse([item, ..acc])), rest))
        "" -> Error(at(line, "unclosed flow sequence"))
        _ -> Error(at(line, "expected , or ] in a flow sequence"))
      }
    }
  }
}

fn flow_map(
  text: String,
  line: Int,
  acc: List(#(String, Json)),
) -> Result(#(Json, String), String) {
  case text {
    "}" <> rest -> Ok(#(json.Object(list.reverse(acc)), rest))
    "" -> Error(at(line, "unclosed flow mapping"))
    _ -> {
      use #(key, rest) <- result.try(flow(text, line))
      use key <- result.try(case key {
        json.String(s) -> Ok(s)
        json.Null -> Error(at(line, "missing key in a flow mapping"))
        other -> Ok(json.to_string(other))
      })
      use <- guard(
        list.key_find(acc, key) |> result.is_ok,
        at(line, "duplicate key " <> json.quote(key)),
      )
      use #(value, rest) <- result.try(case drop_ws(rest) {
        ":" <> rest ->
          case drop_ws(rest) {
            "," <> _ | "}" <> _ -> Ok(#(json.Null, drop_ws(rest)))
            r -> flow(r, line)
          }
        r -> Ok(#(json.Null, r))
      })
      case drop_ws(rest) {
        "," <> rest -> flow_map(drop_ws(rest), line, [#(key, value), ..acc])
        "}" <> rest ->
          Ok(#(json.Object(list.reverse([#(key, value), ..acc])), rest))
        "" -> Error(at(line, "unclosed flow mapping"))
        _ -> Error(at(line, "expected , or } in a flow mapping"))
      }
    }
  }
}

// ---- scalars ----------------------------------------------------------------

fn quoted(text: String, line: Int) -> Result(#(String, String), String) {
  case text {
    "\"" <> rest -> double(string.to_graphemes(rest), "", line)
    "'" <> rest -> single(string.to_graphemes(rest), "", line)
    _ -> Error(at(line, "expected a quoted scalar"))
  }
}

fn single(chars: List(String), acc: String, line: Int) {
  case chars {
    [] -> Error(at(line, "unclosed single-quoted scalar"))
    ["'", "'", ..rest] -> single(rest, acc <> "'", line)
    ["'", ..rest] -> Ok(#(acc, string.concat(rest)))
    [c, ..rest] -> single(rest, acc <> c, line)
  }
}

fn double(chars: List(String), acc: String, line: Int) {
  case chars {
    [] -> Error(at(line, "unclosed double-quoted scalar"))
    ["\"", ..rest] -> Ok(#(acc, string.concat(rest)))
    ["\\", c, ..rest] -> {
      let simple = case c {
        "n" -> Ok("\n")
        "t" | "\t" -> Ok("\t")
        "r" -> Ok("\r")
        "0" -> Ok("\u{0000}")
        "a" -> Ok("\u{0007}")
        "b" -> Ok("\u{0008}")
        "e" -> Ok("\u{001B}")
        "f" -> Ok("\u{000C}")
        "v" -> Ok("\u{000B}")
        " " -> Ok(" ")
        "/" -> Ok("/")
        "\\" -> Ok("\\")
        "\"" -> Ok("\"")
        "N" -> Ok("\u{0085}")
        "_" -> Ok("\u{00A0}")
        "L" -> Ok("\u{2028}")
        "P" -> Ok("\u{2029}")
        _ -> Error(Nil)
      }
      case simple, c {
        Ok(s), _ -> double(rest, acc <> s, line)
        Error(Nil), "x" -> hex_escape(rest, 2, acc, line)
        Error(Nil), "u" -> hex_escape(rest, 4, acc, line)
        Error(Nil), "U" -> hex_escape(rest, 8, acc, line)
        Error(Nil), _ -> Error(at(line, "invalid escape \\" <> c))
      }
    }
    [c, ..rest] -> double(rest, acc <> c, line)
  }
}

fn hex_escape(chars: List(String), n: Int, acc: String, line: Int) {
  let digits = list.take(chars, n) |> string.concat
  let n_ok = string.length(digits) == n
  case int.base_parse(digits, 16) {
    Ok(code) if n_ok ->
      case string.utf_codepoint(code) {
        Ok(cp) ->
          double(
            list.drop(chars, n),
            acc <> string.from_utf_codepoints([cp]),
            line,
          )
        Error(Nil) -> Error(at(line, "invalid character escape"))
      }
    _ -> Error(at(line, "invalid hex escape"))
  }
}

/// Resolves a plain scalar with the YAML 1.2 core schema.
fn resolve(s: String, line: Int) -> Result(Json, String) {
  case s {
    "" | "~" | "null" | "Null" | "NULL" -> Ok(json.Null)
    "true" | "True" | "TRUE" -> Ok(json.Bool(True))
    "false" | "False" | "FALSE" -> Ok(json.Bool(False))
    ".inf"
    | ".Inf"
    | ".INF"
    | "+.inf"
    | "+.Inf"
    | "+.INF"
    | "-.inf"
    | "-.Inf"
    | "-.INF"
    | ".nan"
    | ".NaN"
    | ".NAN" -> Error(at(line, "infinite and NaN numbers are not supported"))
    "&" <> _ | "*" <> _ | "!" <> _ ->
      Error(at(line, "anchors, aliases and tags are not supported"))
    "0o" <> d ->
      int.base_parse(d, 8)
      |> result.map(json.Int)
      |> result.unwrap(json.String(s))
      |> Ok
    "0x" <> d ->
      int.base_parse(d, 16)
      |> result.map(json.Int)
      |> result.unwrap(json.String(s))
      |> Ok
    _ ->
      case decimal_int(s) {
        True -> {
          let assert Ok(n) = int.parse(string.replace(s, "+", ""))
          Ok(json.Int(n))
        }
        False ->
          case decimal_float(s) {
            Ok(f) -> Ok(json.Float(f))
            Error(Nil) -> Ok(json.String(s))
          }
      }
  }
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c) && c != ""
}

fn decimal_int(s: String) -> Bool {
  let body = case s {
    "-" <> r | "+" <> r -> r
    r -> r
  }
  body != "" && list.all(string.to_graphemes(body), is_digit)
}

// [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
fn decimal_float(s: String) -> Result(Float, Nil) {
  let #(sign, body) = case s {
    "-" <> r -> #("-", r)
    "+" <> r -> #("", r)
    r -> #("", r)
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
    Ok(#(w, f)) -> #(w, f)
    Error(Nil) -> #(mantissa, "")
  }
  let digits = fn(d) { list.all(string.to_graphemes(d), is_digit) }
  let exp_ok = case exponent {
    Error(Nil) -> True
    Ok("-" <> e) | Ok("+" <> e) | Ok(e) -> e != "" && digits(e)
  }
  let ok =
    digits(whole)
    && digits(frac)
    && { whole != "" || frac != "" }
    && { string.contains(mantissa, ".") || result.is_ok(exponent) }
  case ok && exp_ok {
    False -> Error(Nil)
    True ->
      float.parse(
        sign
        <> zero(whole)
        <> "."
        <> zero(frac)
        <> case exponent {
          Ok(e) -> "e" <> e
          Error(Nil) -> ""
        },
      )
  }
}

fn zero(s: String) -> String {
  case s {
    "" -> "0"
    _ -> s
  }
}
