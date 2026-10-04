//// RE2 patterns on the host engines (PCRE on Erlang, ECMAScript on
//// JavaScript). SPEC §4.3: patterns are RE2 and match anywhere. Features
//// RE2 lacks are rejected at declaration time; the shorthand classes `\d`,
//// `\w`, `\s`, `\b` are rewritten to their ASCII-only RE2 meaning; and the
//// Erlang FFI compiles with `dollar_endonly`, so `$` is end of text.

import gleam/string

@external(erlang, "docuconf_ffi", "regex_compile")
@external(javascript, "../../docuconf_ffi.mjs", "regex_compile")
fn ffi_compile(pattern: String) -> Result(Nil, String)

@external(erlang, "docuconf_ffi", "regex_matches")
@external(javascript, "../../docuconf_ffi.mjs", "regex_matches")
fn ffi_matches(pattern: String, value: String) -> Bool

/// Checks an RE2 pattern: Ok(Nil), or Error(why it cannot be used).
pub fn check(pattern: String) -> Result(Nil, String) {
  case non_re2_feature(pattern) {
    Ok(feature) -> Error("uses " <> feature <> ", which RE2 does not support")
    Error(Nil) -> ffi_compile(translate(pattern))
  }
}

/// Partial match with RE2 semantics. The pattern must have passed `check`.
pub fn matches(pattern: String, value: String) -> Bool {
  ffi_matches(translate(pattern), value)
}

/// The first PCRE- or ECMAScript-only feature in the pattern, if any.
pub fn non_re2_feature(pattern: String) -> Result(String, Nil) {
  scan(pattern, False, False)
}

fn scan(s: String, in_class: Bool, after_atom: Bool) -> Result(String, Nil) {
  case s, in_class {
    "", _ -> Error(Nil)
    "\\k<" <> _, False -> Ok("named backreference \\k<...>")
    "\\g" <> _, False -> Ok("backreference or subroutine \\g")
    "\\K" <> _, False -> Ok("match reset \\K")
    "\\Z" <> _, False -> Ok("\\Z (use \\z)")
    "\\" <> rest, _ ->
      case string.pop_grapheme(rest) {
        Ok(#(c, rest)) ->
          case in_class, string.contains("123456789", c) {
            False, True -> Ok("backreference \\" <> c)
            _, _ -> scan(rest, in_class, True)
          }
        Error(Nil) -> Ok("trailing backslash")
      }
    "]" <> rest, True -> scan(rest, False, True)
    "[^]" <> rest, False -> scan(rest, True, True)
    "[]" <> rest, False -> scan(rest, True, True)
    "[^" <> rest, False -> scan(rest, True, True)
    "[" <> rest, False -> scan(rest, True, True)
    "(?=" <> _, False -> Ok("lookahead (?=...)")
    "(?!" <> _, False -> Ok("negative lookahead (?!...)")
    "(?<=" <> _, False -> Ok("lookbehind (?<=...)")
    "(?<!" <> _, False -> Ok("negative lookbehind (?<!...)")
    "(?>" <> _, False -> Ok("atomic group (?>...)")
    "(?(" <> _, False -> Ok("conditional (?(...)")
    "(?|" <> _, False -> Ok("branch reset (?|...)")
    "(?R" <> _, False -> Ok("recursion (?R)")
    "(?&" <> _, False -> Ok("subroutine call (?&...)")
    "(?P>" <> _, False -> Ok("subroutine call (?P>...)")
    "(?P=" <> _, False -> Ok("named backreference (?P=...)")
    "(?#" <> _, False -> Ok("comment group (?#...)")
    "*+" <> _, False if after_atom -> Ok("possessive quantifier *+")
    "++" <> _, False if after_atom -> Ok("possessive quantifier ++")
    "?+" <> _, False if after_atom -> Ok("possessive quantifier ?+")
    "}+" <> _, False -> Ok("possessive quantifier {n}+")
    _, _ ->
      case string.pop_grapheme(s) {
        Ok(#(c, rest)) ->
          scan(rest, in_class, !{ c == "*" || c == "+" || c == "?" })
        Error(Nil) -> Error(Nil)
      }
  }
}

const word = "0-9A-Za-z_"

const space = "\\t\\n\\f\\r "

/// Rewrites `\d`, `\w`, `\s`, `\b` and their negations to explicit ASCII
/// classes, which every engine reads the way RE2 does.
pub fn translate(pattern: String) -> String {
  ascii(pattern, False, "")
}

fn ascii(s: String, in_class: Bool, acc: String) -> String {
  case s, in_class {
    "", _ -> acc
    "\\z" <> r, False -> ascii(r, False, acc <> "$")
    "\\A" <> r, False -> ascii(r, False, acc <> "^")
    "(?P<" <> r, False -> ascii(r, False, acc <> "(?<")
    "\\d" <> r, False -> ascii(r, False, acc <> "[0-9]")
    "\\D" <> r, False -> ascii(r, False, acc <> "[^0-9]")
    "\\w" <> r, False -> ascii(r, False, acc <> "[" <> word <> "]")
    "\\W" <> r, False -> ascii(r, False, acc <> "[^" <> word <> "]")
    "\\s" <> r, False -> ascii(r, False, acc <> "[" <> space <> "]")
    "\\S" <> r, False -> ascii(r, False, acc <> "[^" <> space <> "]")
    "\\b" <> r, False ->
      ascii(
        r,
        False,
        acc
          <> "(?:(?<=["
          <> word
          <> "])(?!["
          <> word
          <> "])|(?<!["
          <> word
          <> "])(?=["
          <> word
          <> "]))",
      )
    "\\B" <> r, False ->
      ascii(
        r,
        False,
        acc
          <> "(?:(?<=["
          <> word
          <> "])(?=["
          <> word
          <> "])|(?<!["
          <> word
          <> "])(?!["
          <> word
          <> "]))",
      )
    "\\d" <> r, True -> ascii(r, True, acc <> "0-9")
    "\\w" <> r, True -> ascii(r, True, acc <> word)
    "\\s" <> r, True -> ascii(r, True, acc <> space)
    "\\" <> r, _ ->
      case string.pop_grapheme(r) {
        Ok(#(c, r)) -> ascii(r, in_class, acc <> "\\" <> c)
        Error(Nil) -> acc <> "\\"
      }
    "[^]" <> r, False -> ascii(r, True, acc <> "[^\\]")
    "[]" <> r, False -> ascii(r, True, acc <> "[\\]")
    "[^" <> r, False -> ascii(r, True, acc <> "[^")
    "[" <> r, False -> ascii(r, True, acc <> "[")
    "]" <> r, True -> ascii(r, False, acc <> "]")
    _, _ ->
      case string.pop_grapheme(s) {
        Ok(#(c, r)) -> ascii(r, in_class, acc <> c)
        Error(Nil) -> acc
      }
  }
}
