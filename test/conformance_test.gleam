//// The shared conformance suite (SPEC §12), run through contract-first mode
//// as docuconf-go's conformance/README.md describes.
////
//// cases.json is found through DOCUCONF_CONFORMANCE, else
//// ../docuconf-go/conformance/cases.json. When it is missing the suite is
//// skipped, unless DOCUCONF_REQUIRE_CONFORMANCE=1.

import docuconf
import docuconf/contract_first
import docuconf/json.{type Json}
import envoy
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import support

/// Capability tags this SDK supports: all of them, on both targets. A
/// skipped case fails the suite. On JavaScript an `int` beyond ±(2^53 − 1)
/// is a `BigIntValue` holding its digits.
fn supported_tags() -> List(String) {
  ["int64", "json-schema"]
}

/// Expected integers beyond ±(2^53 − 1), by "<case id> <var>", as their
/// source digits. Empty on Erlang, which parses them exactly.
@external(erlang, "docuconf_test_ffi", "big_expects")
@external(javascript, "./docuconf_test_ffi.mjs", "big_expects")
fn big_expects(text: String) -> List(#(String, String))

type Outcome {
  Passed
  Skipped(tags: List(String))
  Failed(reason: String)
}

pub fn conformance_test() {
  let path = case envoy.get("DOCUCONF_CONFORMANCE") {
    Ok(p) if p != "" -> p
    _ -> "../docuconf-go/conformance/cases.json"
  }
  case support.read_file(path) {
    Error(Nil) ->
      case envoy.get("DOCUCONF_REQUIRE_CONFORMANCE") {
        Ok("1") -> panic as { "conformance cases not found at " <> path }
        _ -> io.println("\nconformance: skipped, " <> path <> " not found")
      }
    Ok(text) -> run(text)
  }
}

fn run(text: String) -> Nil {
  let assert Ok(json.Object(top)) = json.parse(text)
  let assert Ok(json.Array(cases)) = list.key_find(top, "cases")
  let log = support.temp_dir() <> "/termination-log"
  let bigs = big_expects(text)
  let results =
    list.map(cases, fn(c) {
      let assert json.Object(c) = c
      let assert Ok(json.String(id)) = list.key_find(c, "id")
      #(id, run_case(c, log, exact_digits(bigs, id)))
    })
  let failed =
    list.filter_map(results, fn(r) {
      case r.1 {
        Failed(reason) -> Ok(r.0 <> ": " <> reason)
        _ -> Error(Nil)
      }
    })
  let skipped =
    list.flat_map(results, fn(r) {
      case r.1 {
        Skipped(tags) -> [string.join(tags, "+")]
        _ -> []
      }
    })
  let passed = list.count(results, fn(r) { r.1 == Passed })
  let skip_detail = case skipped {
    [] -> ""
    _ ->
      " ("
      <> {
        list.group(skipped, fn(t) { t })
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(p) { p.0 <> ": " <> int.to_string(list.length(p.1)) })
        |> string.join(", ")
      }
      <> ")"
  }
  io.println(
    "\nconformance ("
    <> support.target()
    <> "): "
    <> int.to_string(passed)
    <> " passed, "
    <> int.to_string(list.length(skipped))
    <> " skipped"
    <> skip_detail
    <> ", "
    <> int.to_string(list.length(failed))
    <> " failed",
  )
  case failed, skipped {
    [], [] -> Nil
    [], _ ->
      panic as {
        int.to_string(list.length(skipped))
        <> " conformance cases skipped; every capability tag must be supported"
      }
    _, _ -> {
      list.each(failed, fn(f) { io.println("  FAIL " <> f) })
      panic as {
        int.to_string(list.length(failed)) <> " conformance cases failed"
      }
    }
  }
}

/// A case's expected big integers, by variable name.
fn exact_digits(
  bigs: List(#(String, String)),
  id: String,
) -> List(#(String, String)) {
  list.filter_map(bigs, fn(b) {
    case string.split_once(b.0, id <> " ") {
      Ok(#("", name)) -> Ok(#(name, b.1))
      _ -> Error(Nil)
    }
  })
}

fn run_case(
  c: List(#(String, Json)),
  log: String,
  digits: List(#(String, String)),
) -> Outcome {
  let requires = case list.key_find(c, "requires") {
    Ok(json.Array(tags)) ->
      list.filter_map(tags, fn(t) {
        case t {
          json.String(s) -> Ok(s)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
  case list.filter(requires, fn(t) { !list.contains(supported_tags(), t) }) {
    [_, ..] as missing -> Skipped(missing)
    [] -> {
      let assert Ok(contract) = list.key_find(c, "contract")
      let env = case list.key_find(c, "env") {
        Ok(json.Object(fields)) ->
          list.filter_map(fields, fn(f) {
            case f.1 {
              json.String(s) -> Ok(#(f.0, s))
              _ -> Error(Nil)
            }
          })
        _ -> []
      }
      let _ = support.shell("rm -f '" <> log <> "'")
      let loaded = case contract_first.spec(contract) {
        Error(e) -> Error(e)
        Ok(spec) ->
          docuconf.load_with(
            spec,
            docuconf.options()
              |> docuconf.with_env(dict.from_list(env))
              |> docuconf.with_termination_log(log),
          )
      }
      case list.key_find(c, "expect"), list.key_find(c, "errors") {
        Ok(json.Object(expect)), _ -> check_expect(loaded, expect, digits)
        _, Ok(json.Array(errors)) ->
          check_errors(loaded, errors, secrets(contract, env), log)
        _, _ -> Failed("case has neither expect nor errors")
      }
    }
  }
}

fn check_expect(
  loaded: Result(dict.Dict(String, contract_first.Value), docuconf.Error),
  expect: List(#(String, Json)),
  digits: List(#(String, String)),
) -> Outcome {
  case loaded {
    Error(e) -> Failed("expected success, got " <> docuconf.describe(e))
    Ok(values) -> {
      let wrong =
        list.filter_map(expect, fn(pair) {
          let #(name, want) = pair
          let value = dict.get(values, name)
          let got =
            value
            |> result.map(contract_first.to_json)
            |> result.unwrap(json.String("<not loaded>"))
          // An integer beyond 2^53 compares by its exact digits.
          let ok = case list.key_find(digits, name) {
            Ok(want_digits) ->
              result.try(value, contract_first.int_text) == Ok(want_digits)
            Error(Nil) -> same(got, want)
          }
          case ok {
            True -> Error(Nil)
            False ->
              Ok(
                name
                <> " = "
                <> json.to_string(got)
                <> ", want "
                <> json.to_string(want),
              )
          }
        })
      let extra =
        dict.keys(values)
        |> list.filter(fn(k) { result.is_error(list.key_find(expect, k)) })
        |> list.map(fn(k) { k <> " loaded but not expected" })
      case list.append(wrong, extra) {
        [] -> Passed
        problems -> Failed(string.join(problems, "; "))
      }
    }
  }
}

fn check_errors(
  loaded: Result(dict.Dict(String, contract_first.Value), docuconf.Error),
  errors: List(Json),
  secret_values: List(String),
  log: String,
) -> Outcome {
  let want =
    list.map(errors, fn(e) {
      let assert json.Object(e) = e
      let assert Ok(json.String(var)) = list.key_find(e, "var")
      let assert Ok(json.String(code)) = list.key_find(e, "code")
      var <> " " <> code
    })
    |> list.sort(string.compare)
  case loaded {
    Ok(_) -> Failed("expected errors " <> string.join(want, ", ") <> ", loaded")
    Error(docuconf.InvalidConfig(violations) as e) -> {
      let got =
        list.map(violations, fn(v) {
          v.input <> " " <> docuconf.code_to_string(v.code)
        })
        |> list.sort(string.compare)
      let output =
        docuconf.describe(e)
        <> "\n"
        <> result.unwrap(support.read_file(log), "")
      let leaked = list.filter(secret_values, string.contains(output, _))
      case got == want, leaked {
        True, [] -> Passed
        False, _ ->
          Failed(
            "errors "
            <> string.join(got, ", ")
            <> ", want "
            <> string.join(want, ", "),
          )
        True, _ -> Failed("a secret value appears in the error output")
      }
    }
    Error(e) -> Failed("contract rejected: " <> docuconf.describe(e))
  }
}

/// The raw env values of secret variables (indexed items included).
fn secrets(contract: Json, env: List(#(String, String))) -> List(String) {
  let names = case contract {
    json.Object(fields) ->
      case list.key_find(fields, "vars") {
        Ok(json.Object(vars)) ->
          list.filter_map(vars, fn(v) {
            case v.1 {
              json.Object(def) ->
                case list.key_find(def, "secret") {
                  Ok(json.Bool(True)) -> Ok(v.0)
                  _ -> Error(Nil)
                }
              _ -> Error(Nil)
            }
          })
        _ -> []
      }
    _ -> []
  }
  list.filter_map(env, fn(pair) {
    let secret =
      list.any(names, fn(n) {
        pair.0 == n || string.starts_with(pair.0, n <> "__")
      })
    case secret && pair.1 != "" {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

/// JSON equality with numbers compared numerically (3 equals 3.0) and
/// integers exactly.
fn same(a: Json, b: Json) -> Bool {
  case a, b {
    json.Int(x), json.Int(y) -> x == y
    json.Float(_), json.Int(_)
    | json.Int(_), json.Float(_)
    | json.Float(_), json.Float(_)
    -> to_float(a) == to_float(b)
    json.Array(xs), json.Array(ys) ->
      list.length(xs) == list.length(ys)
      && list.all(list.zip(xs, ys), fn(p) { same(p.0, p.1) })
    json.Object(xs), json.Object(ys) -> {
      let sort = list.sort(_, fn(p: #(String, Json), q: #(String, Json)) {
        string.compare(p.0, q.0)
      })
      let #(xs, ys) = #(sort(xs), sort(ys))
      list.length(xs) == list.length(ys)
      && list.all(list.zip(xs, ys), fn(p) {
        p.0.0 == p.1.0 && same(p.0.1, p.1.1)
      })
    }
    _, _ -> a == b
  }
}

fn to_float(j: Json) -> Option(Float) {
  case j {
    json.Int(i) -> Some(int.to_float(i))
    json.Float(f) -> Some(f)
    _ -> None
  }
}
