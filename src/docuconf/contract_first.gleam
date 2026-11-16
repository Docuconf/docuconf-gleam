//// Contract-first mode (SPEC §11.2 item 11): validate an environment and
//// the files it names against a contract given as JSON, with no Gleam
//// declaration, and get typed values back.
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
//// Each input is declared through the same builders a Gleam declaration
//// uses (`docuconf.int`, `docuconf.min_int`, `docuconf.tls`, ...), so values
//// are parsed and checked by exactly the same code, and errors carry the
//// same codes. Every wire encoding of SPEC §5 is read: `csv`, `json` and
//// `indexed` lists and key sets, and `go`, `iso8601`, `seconds` and
//// `timespan` durations.
////
//// The whole contract is covered:
////
//// - `vars` of every type, `keySet` included, with `deprecated` inputs
////   (a boot warning names each one that is set);
//// - `files`: `config` files in JSON, YAML and TOML (checked against their
////   `schema`), `tls` key pairs, `caBundle`s, `keystore`s (PKCS#12 and JKS,
////   checked through their integrity MAC), `text` and `binary` files, all
////   under `DOCUCONF_FILE_ROOT` when it is set;
//// - `profiles` and `overlays`, layered as SPEC §4.4 and §4.7 order them:
////   the variable's default, then the selected profile's default, then a
////   config-file overlay, then the environment. Layering needs the
////   environment, so it applies through `load` and `load_json`; `spec`
////   returns the declaration without it.
//// - `requiredIf` on variables and files (SPEC §4.2.1): the input is
////   required while the condition variable's loaded value (environment,
////   overlay, profile or default) is the condition's value. A missing
////   variable is then `missing_required`, `is required when TLS_ENABLED is
////   true`, and a missing file `file_missing`, its message ending with
////   `, and is required when TLS_ENABLED is true`.
//// - `roles` (SPEC §4.9): `DOCUCONF_ROLE` names the workload's role, and an
////   input whose `roles` do not include it is optional. Without a valid
////   role every input with `roles` is optional, so the role is the one
////   problem reported.
//// - `includes` (SPEC §4.8): read and checked, and returned by `includes`.
////   The fragments' variables are inline in `vars`, so they load like any
////   other.
////
//// An `int` holds the full 64-bit range on both targets: an `IntValue`, or
//// on JavaScript, beyond ±(2^53 − 1) where an `Int` is not exact, a
//// `BigIntValue` with its decimal text. A `json` value is checked against
//// the variable's `schema` (see "Contract-first mode" in the README): a
//// value that does not match is `schema_mismatch`, and a schema using a
//// keyword the validator does not support is a declaration error.
////
//// Not covered: `reload: watch`, which is a declaration error, since the
//// SDK reads each file once at boot.

import docuconf.{
  type Layer, type Secret, type Spec, type Values, type Var, type VarBuilder,
}
import docuconf/duration.{type Duration}
import docuconf/internal/exact_int.{type ExactInt, Big, Small}
import docuconf/internal/json_schema
import docuconf/internal/toml
import docuconf/internal/yaml
import docuconf/json.{type Json}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The typed value of one input.
pub type Value {
  /// An optional input that is not set (or a file that is absent) and has
  /// no default.
  Absent
  BoolValue(Bool)
  IntValue(Int)
  /// An `int` beyond ±(2^53 − 1) on the JavaScript target, where an `Int`
  /// cannot hold it exactly: its decimal text, with no `+` and no leading
  /// zeros, such as `"9223372036854775807"`. Never produced on Erlang, where
  /// every 64-bit integer is an `IntValue`. `int_text` reads either.
  BigIntValue(String)
  FloatValue(Float)
  /// A `string`, `url` or `enum` value, or the content of a `text` file.
  StringValue(String)
  DurationValue(Duration)
  /// A `list` of `StringValue` or `IntValue` items.
  ListValue(List(Value))
  /// A `json` value, or the data of a `config` file.
  JsonValue(Json)
  /// A `keySet`: its keys, in order. Always secret; it prints redacted.
  KeySetValue(docuconf.KeySet)
  /// A `tls` key pair directory that passed its checks.
  TlsValue(docuconf.Tls)
  /// A `caBundle` that passed its checks.
  CaBundleValue(docuconf.CaBundle)
  /// The path of a `keystore` that opened with its password.
  KeystoreValue(String)
  /// The path of a `binary` file.
  BinaryValue(String)
  /// The value of a `secret: true` variable or file. It prints redacted;
  /// read it with `docuconf.reveal`.
  SecretValue(Secret(Value))
}

/// The exact decimal text of an `IntValue` or a `BigIntValue` (a secret's
/// too), on either target.
pub fn int_text(value: Value) -> Result(String, Nil) {
  case value {
    IntValue(i) -> Ok(int.to_string(i))
    BigIntValue(text) -> Ok(text)
    SecretValue(s) -> int_text(docuconf.reveal(s))
    _ -> Error(Nil)
  }
}

/// The value as JSON, as the conformance suite writes it: `null` when
/// absent, a duration in canonical Go form, a key set as its keys, and
/// `true` for a present `tls`, `caBundle`, `keystore` or `binary` input.
/// On JavaScript a `BigIntValue` becomes the nearest double; read its exact
/// text with `int_text`.
pub fn to_json(value: Value) -> Json {
  case value {
    Absent -> json.Null
    BoolValue(b) -> json.Bool(b)
    IntValue(i) -> json.Int(i)
    // The nearest double: exact text is in int_text.
    BigIntValue(text) -> {
      let assert Ok(i) = int.parse(text)
      json.Int(i)
    }
    FloatValue(f) -> json.Float(f)
    StringValue(s) -> json.String(s)
    DurationValue(d) -> json.String(duration.to_string(d))
    ListValue(items) -> json.Array(list.map(items, to_json))
    JsonValue(j) -> j
    KeySetValue(set) -> json.array(docuconf.keys(set), json.String)
    TlsValue(_) | CaBundleValue(_) | KeystoreValue(_) | BinaryValue(_) ->
      json.Bool(True)
    SecretValue(s) -> to_json(docuconf.reveal(s))
  }
}

/// Loads the environment and files (as `docuconf.load_with` does, from
/// `options`) against a contract given as JSON text. Returns the value of
/// every input, keyed by name, or every problem found.
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
    Ok(contract) -> load_json(contract, options)
  }
}

/// `load` with the contract already parsed.
pub fn load_json(
  contract: Json,
  options: docuconf.Options,
) -> Result(Dict(String, Value), docuconf.Error) {
  use c <- result.try(
    read_contract(contract) |> result.map_error(docuconf.InvalidDeclaration),
  )
  let env = docuconf.environment(options)
  let root = docuconf.file_root(options, env)
  // The selected profile's values become the variables' defaults.
  let vars = case c.profiles {
    None -> c.vars
    Some(p) -> with_profile(c.vars, p, selected(p, c.vars, env))
  }
  let #(layers, violations) = overlay_layers(c, root)
  // Roles (SPEC §4.9): an input only other roles use is optional here.
  let role = selected_role(c, env)
  let vars = list.map(vars, narrow(_, role))
  let files = list.map(c.files, narrow(_, role))
  // Conditional requirements (SPEC §4.2.1), on the condition variables'
  // loaded values.
  let value_of = condition_value(vars, _, options, env, layers)
  let vars = list.map(vars, activate(_, role, value_of))
  let files = list.map(files, activate(_, role, value_of))
  use spec <- result.try(
    build_spec(Contract(..c, vars:, files:))
    |> result.map_error(docuconf.InvalidDeclaration),
  )
  docuconf.load_with(spec, docuconf.with_layers(options, layers, violations))
}

/// The well-known fragments a contract includes (SPEC §4.8), as
/// `name@major`, such as `["go-runtime@1", "otel@1"]`; empty when it has
/// none. Their variables are inline in `vars` and load like any other.
pub fn includes(contract: Json) -> Result(List(String), docuconf.Error) {
  read_contract(contract)
  |> result.map(fn(c) { c.includes })
  |> result.map_error(docuconf.InvalidDeclaration)
}

/// The roles a contract declares (SPEC §4.9); empty when it has none.
pub fn roles(contract: Json) -> Result(List(String), docuconf.Error) {
  read_contract(contract)
  |> result.map(fn(c) { option.unwrap(c.roles, []) })
  |> result.map_error(docuconf.InvalidDeclaration)
}

/// The declaration a contract describes, for `docuconf.load_with`,
/// `docuconf.check_declaration` or `docuconf.contract`. Profiles and
/// overlays are checked, but only `load` and `load_json` apply them.
pub fn spec(
  contract: Json,
) -> Result(Spec(Dict(String, Value)), docuconf.Error) {
  read_contract(contract)
  |> result.try(build_spec)
  |> result.map_error(docuconf.InvalidDeclaration)
}

// ---- the contract -------------------------------------------------------------

type Def =
  List(#(String, Json))

type Profiles {
  Profiles(
    selector: String,
    default: String,
    defaults: List(#(String, List(#(String, Json)))),
  )
}

type Overlay {
  Overlay(name: String, format: String, path: String, separator: String)
}

type Contract {
  Contract(
    vars: List(#(String, Def)),
    files: List(#(String, Def)),
    profiles: Option(Profiles),
    overlays: List(Overlay),
    roles: Option(List(String)),
    includes: List(String),
  )
}

/// The variable that names the workload's role (SPEC §4.9).
const role_var = "DOCUCONF_ROLE"

/// Set on an input a `requiredIf` condition makes required at this boot, to
/// the condition as its message writes it (`TLS_ENABLED is true`). Never
/// read from a contract: `read_contract` drops it.
const when_key = "requiredWhen"

fn read_contract(contract: Json) -> Result(Contract, List(String)) {
  use fields <- result.try(case contract {
    json.Object(fields) -> Ok(fields)
    _ -> Error(["contract must be a JSON object"])
  })
  let objects = fn(key, what) {
    case list.key_find(fields, key) {
      Error(Nil) | Ok(json.Null) -> Ok([])
      Ok(json.Object(entries)) ->
        list.try_map(entries, fn(e) {
          case e.1 {
            json.Object(def) ->
              Ok(#(e.0, list.filter(def, fn(f) { f.0 != when_key })))
            _ -> Error([what <> " " <> e.0 <> ": must be an object"])
          }
        })
      Ok(_) -> Error([key <> " must be an object"])
    }
  }
  use vars <- result.try(objects("vars", "variable"))
  use files <- result.try(objects("files", "file"))
  let #(profiles, profile_problems) = case list.key_find(fields, "profiles") {
    Error(Nil) | Ok(json.Null) -> #(None, [])
    Ok(p) -> read_profiles(p, vars)
  }
  let #(overlays, overlay_problems) = case list.key_find(fields, "overlays") {
    Error(Nil) | Ok(json.Null) -> #([], [])
    Ok(o) -> read_overlays(o)
  }
  let #(includes, include_problems) =
    read_includes(list.key_find(fields, "includes"))
  let #(roles, role_problems) = case list.key_find(fields, "roles") {
    Error(Nil) | Ok(json.Null) -> #(None, [])
    Ok(r) -> read_roles(r)
  }
  let inputs =
    list.append(
      list.map(vars, fn(v) { #("variable " <> v.0, v) }),
      list.map(files, fn(f) { #("file " <> f.0, f) }),
    )
  let input_problems =
    list.flat_map(inputs, fn(i) {
      let #(what, #(name, def)) = i
      list.flatten([
        input_role_problems(def, roles)
          |> list.map(fn(p) { what <> ": " <> p }),
        condition_problems(name, def, vars)
          |> list.map(fn(p) { what <> ": " <> p }),
      ])
    })
  let c = Contract(vars:, files:, profiles:, overlays:, roles:, includes:)
  case
    list.flatten([
      profile_problems,
      overlay_problems,
      include_problems,
      role_problems,
      input_problems,
      role_var_problems(roles, vars),
    ])
  {
    [] -> Ok(c)
    problems -> Error(problems)
  }
}

// ---- includes, roles and requiredIf ---------------------------------------------

// `includes` (SPEC §4.8): a list of fragment names, name@major, none twice.
fn read_includes(found: Result(Json, Nil)) -> #(List(String), List(String)) {
  let malformed = "includes must be a list of fragment names, such as otel@1"
  case found {
    Error(Nil) | Ok(json.Null) -> #([], [])
    Ok(json.Array(items)) ->
      case list.try_map(items, string_of) {
        Error(_) -> #([], [malformed])
        Ok(names) -> {
          let #(names, problems) =
            list.fold(names, #([], []), fn(acc, name) {
              case fragment_name(name), list.contains(acc.0, name) {
                False, _ -> #(acc.0, [
                  "includes: "
                    <> json.quote(name)
                    <> " is not a fragment name, name@major",
                  ..acc.1
                ])
                True, True -> #(acc.0, [
                  "includes: " <> name <> " is listed twice",
                  ..acc.1
                ])
                True, False -> #([name, ..acc.0], acc.1)
              }
            })
          #(list.reverse(names), list.reverse(problems))
        }
      }
    Ok(_) -> #([], [malformed])
  }
}

// name@major: a lowercase name, then a major version from 1, with no
// leading zero.
fn fragment_name(name: String) -> Bool {
  let lower = "abcdefghijklmnopqrstuvwxyz"
  let digits = "0123456789"
  case string.split_once(name, "@") {
    Ok(#(base, major)) ->
      case string.to_graphemes(base), string.to_graphemes(major) {
        [first, ..rest], [lead, ..more] ->
          string.contains(lower, first)
          && list.all(rest, string.contains(lower <> digits <> "-", _))
          && string.contains("123456789", lead)
          && list.all(more, string.contains(digits, _))
        _, _ -> False
      }
    Error(Nil) -> False
  }
}

// A list of roles (SPEC §4.9): DNS labels, at least one, none listed twice.
fn read_roles(node: Json) -> #(Option(List(String)), List(String)) {
  let names = case node {
    json.Array([_, ..] as items) -> list.try_map(items, string_of)
    _ -> Error("")
  }
  case names {
    Error(_) -> #(None, ["roles must be a list of at least one role name"])
    Ok(names) -> {
      let problems =
        list.index_map(names, fn(r, i) {
          case role_name(r), list.contains(list.take(names, i), r) {
            False, _ -> ["role " <> json.quote(r) <> " must be a DNS label"]
            True, True -> ["role " <> r <> " is listed twice"]
            True, False -> []
          }
        })
      #(Some(names), list.flatten(problems))
    }
  }
}

// A DNS label: at most 63 lowercase letters, digits and hyphens, starting
// and ending with a letter or digit.
fn role_name(name: String) -> Bool {
  let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  let n = string.length(name)
  n >= 1
  && n <= 63
  && list.all(string.to_graphemes(name), string.contains(chars <> "-", _))
  && !string.starts_with(name, "-")
  && !string.ends_with(name, "-")
}

// An input's roles: readable, and each one of the contract's.
fn input_role_problems(def: Def, roles: Option(List(String))) -> List(String) {
  case list.key_find(def, "roles") {
    Error(Nil) | Ok(json.Null) -> []
    Ok(node) ->
      case read_roles(node), roles {
        #(_, [_, ..] as problems), _ -> problems
        #(_, []), None -> ["has roles, but the contract declares none"]
        #(used, []), Some(roles) ->
          option.unwrap(used, [])
          |> list.filter(fn(r) { !list.contains(roles, r) })
          |> list.map(fn(r) {
            "role "
            <> r
            <> " is not one of the contract's roles, "
            <> string.join(roles, ", ")
          })
      }
  }
}

// With roles, DOCUCONF_ROLE is a required enum whose values are the roles,
// used by every role.
fn role_var_problems(
  roles: Option(List(String)),
  vars: List(#(String, Def)),
) -> List(String) {
  case roles {
    None -> []
    Some(roles) -> {
      let ok = case list.key_find(vars, role_var) {
        Ok(def) ->
          list.key_find(def, "type") == Ok(json.String("enum"))
          && list.key_find(def, "required") == Ok(json.Bool(True))
          && absent(def, "roles")
          && list.key_find(def, "values")
          == Ok(json.Array(list.map(roles, json.String)))
        Error(Nil) -> False
      }
      when(
        !ok,
        "variable "
          <> role_var
          <> ": a contract with roles declares it as a required enum whose values are the roles, "
          <> string.join(roles, ", ")
          <> ", used by every role",
      )
    }
  }
}

fn absent(def: Def, key: String) -> Bool {
  case list.key_find(def, key) {
    Error(Nil) | Ok(json.Null) -> True
    Ok(_) -> False
  }
}

// `requiredIf: {VAR: value}` (SPEC §4.2.1): one other declared variable, a
// plain string, int, bool or enum one, and a value it can hold, on an input
// that is not required, has no default and is not deprecated.
fn condition_problems(
  name: String,
  def: Def,
  vars: List(#(String, Def)),
) -> List(String) {
  case list.key_find(def, "requiredIf") {
    Error(Nil) | Ok(json.Null) -> []
    Ok(json.Object([#(on, want)])) ->
      case env_var_name(on), want {
        True, json.String(_) | True, json.Int(_) | True, json.Bool(_) ->
          list.flatten([
            when(
              list.key_find(def, "required") == Ok(json.Bool(True))
                || !absent(def, "default"),
              "an input with requiredIf cannot be required or have a default",
            ),
            when(
              !absent(def, "deprecated"),
              "a conditionally required input cannot be deprecated: the platform could not stop setting it",
            ),
            condition_target(name, on, want, vars),
          ])
        _, _ -> [
          "requiredIf must name one variable and a string, integer or boolean value",
        ]
      }
    Ok(_) -> ["requiredIf must name one variable and its value: {VAR: value}"]
  }
}

fn condition_target(
  name: String,
  on: String,
  want: Json,
  vars: List(#(String, Def)),
) -> List(String) {
  case list.key_find(vars, on) {
    Ok(on_def) if on != name -> {
      let type_ = case list.key_find(on_def, "type") {
        Ok(json.String(t)) -> t
        _ -> ""
      }
      let plain =
        list.key_find(on_def, "secret") != Ok(json.Bool(True))
        && list.contains(["string", "int", "bool", "enum"], type_)
      // A bool is never an int, nor an int a bool.
      let same_type = case type_, want {
        "int", json.Int(_) -> True
        "bool", json.Bool(_) -> True
        "string", json.String(_) | "enum", json.String(_) -> True
        _, _ -> False
      }
      let cannot = fn(detail) {
        [
          "requiredIf: "
          <> condition_text(on, want)
          <> " is not a value "
          <> on
          <> " can have"
          <> detail,
        ]
      }
      case plain, same_type {
        False, _ -> [
          "requiredIf names "
          <> on
          <> ", which is not a plain string, int, bool or enum variable",
        ]
        True, False -> cannot("")
        True, True ->
          case value_problems(on, on_def, want) {
            [] -> []
            [p, ..] -> cannot(": " <> p)
          }
      }
    }
    _ -> [
      "requiredIf must name another declared variable, not " <> json.quote(on),
    ]
  }
}

// What the variable's constraints say about the value, as they would about
// its default.
fn value_problems(name: String, def: Def, value: Json) -> List(String) {
  case declare(name, with_default(def, value)) {
    Error(p) -> [p]
    Ok(var) ->
      docuconf.check_declaration({
        use _ <- docuconf.env(var)
        docuconf.succeed(Nil)
      })
      |> list.filter_map(fn(p) {
        // "variable NAME: default does not satisfy ..."
        case string.split_once(p, ": ") {
          Ok(#(_, rest)) ->
            case string.starts_with(rest, "default") {
              True -> Ok(rest)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
  }
}

// The condition as messages write it: the value as JSON, so a string is
// quoted (`LOG_FORMAT is "json"`).
fn condition_text(on: String, want: Json) -> String {
  on <> " is " <> json.to_string(want)
}

fn env_var_name(name: String) -> Bool {
  let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains(upper, first)
      && list.all(rest, string.contains(upper <> "0123456789_", _))
    [] -> False
  }
}

// ---- roles and conditions at load -------------------------------------------------

// The workload's role: DOCUCONF_ROLE when it is one of the contract's roles.
fn selected_role(c: Contract, env: Dict(String, String)) -> Option(String) {
  case c.roles, dict.get(env, role_var) {
    Some(roles), Ok(r) ->
      case list.contains(roles, r) {
        True -> Some(r)
        False -> None
      }
    _, _ -> None
  }
}

// Whether the workload's role uses the input: every role uses an input
// without roles, and with no role only those inputs are used.
fn in_role(def: Def, role: Option(String)) -> Bool {
  case list.key_find(def, "roles"), role {
    Ok(json.Array(used)), Some(r) -> list.contains(used, json.String(r))
    Ok(json.Array(_)), None -> False
    _, _ -> True
  }
}

// An input another role uses is optional in this one.
fn narrow(input: #(String, Def), role: Option(String)) -> #(String, Def) {
  case in_role(input.1, role) {
    True -> input
    False -> #(
      input.0,
      list.map(input.1, fn(f) {
        case f.0 {
          "required" -> #("required", json.Bool(False))
          _ -> f
        }
      }),
    )
  }
}

// An input whose condition holds, in a role that uses it, is required, and
// its message says why.
fn activate(
  input: #(String, Def),
  role: Option(String),
  value_of: fn(String) -> Option(Value),
) -> #(String, Def) {
  let #(name, def) = input
  case list.key_find(def, "requiredIf") {
    Ok(json.Object([#(on, want)])) ->
      case in_role(def, role) && holds(value_of(on), want) {
        True -> #(
          name,
          def
            |> list.filter(fn(f) { f.0 != "required" })
            |> list.append([
              #("required", json.Bool(True)),
              #(when_key, json.String(condition_text(on, want))),
            ]),
        )
        False -> input
      }
    _ -> input
  }
}

// Whether a loaded value is the condition's value (a bool is never an int).
fn holds(value: Option(Value), want: Json) -> Bool {
  case value, want {
    Some(BoolValue(b)), json.Bool(w) -> b == w
    Some(IntValue(_) as v), json.Int(w)
    | Some(BigIntValue(_) as v), json.Int(w)
    -> int_text(v) == Ok(int.to_string(w))
    Some(StringValue(s)), json.String(w) -> s == w
    _, _ -> False
  }
}

// A condition variable's loaded value: the environment, an overlay, the
// selected profile or its default, as the load itself reads it. A variable
// with a violation of its own has no value, and makes nothing required.
fn condition_value(
  vars: List(#(String, Def)),
  name: String,
  options: docuconf.Options,
  env: Dict(String, String),
  layers: Dict(String, Layer),
) -> Option(Value) {
  case list.key_find(vars, name) {
    Error(Nil) -> None
    Ok(def) ->
      case declare(name, def) {
        Error(_) -> None
        Ok(var) -> {
          // Quietly: the load itself reports and warns.
          let quiet =
            options
            |> docuconf.with_env(env)
            |> docuconf.without_termination_log
            |> docuconf.on_warning(fn(_) { Nil })
            |> docuconf.with_layers(layers, [])
          case docuconf.load_with(build([#(name, var)], [], []), quiet) {
            Ok(values) -> option.from_result(dict.get(values, name))
            Error(_) -> None
          }
        }
      }
  }
}

fn read_profiles(
  p: Json,
  vars: List(#(String, Def)),
) -> #(Option(Profiles), List(String)) {
  case p {
    json.Object(fields) -> {
      let unknown =
        list.filter_map(fields, fn(f) {
          case list.contains(["selector", "default", "defaults"], f.0) {
            True -> Error(Nil)
            False -> Ok("profiles: unknown field " <> f.0)
          }
        })
      let selector = case list.key_find(fields, "selector") {
        Ok(json.String(s)) -> s
        _ -> ""
      }
      let default = list.key_find(fields, "default")
      let defaults = case list.key_find(fields, "defaults") {
        Ok(json.Object(profiles)) ->
          list.map(profiles, fn(pr) {
            case pr.1 {
              json.Object(values) -> #(pr.0, Ok(values))
              _ -> #(pr.0, Error(Nil))
            }
          })
        _ -> []
      }
      let problems =
        list.flatten([
          unknown,
          case list.key_find(vars, selector) {
            Ok(_) -> []
            Error(Nil) -> [
              "profiles.selector "
              <> json.quote(selector)
              <> " must be a declared variable",
            ]
          },
          case default {
            Ok(json.String(_)) -> []
            _ -> ["profiles.default must be a string"]
          },
          case list.key_find(fields, "defaults") {
            Ok(json.Object(_)) | Error(Nil) -> []
            Ok(_) -> ["profiles.defaults must be an object"]
          },
          list.flat_map(defaults, fn(pr) {
            case pr.1 {
              Error(Nil) -> [
                "profiles.defaults." <> pr.0 <> " must be an object",
              ]
              Ok(values) ->
                profile_problems(pr.0, values, vars)
                |> list.map(fn(m) { "profiles.defaults." <> pr.0 <> ": " <> m })
            }
          }),
        ])
      let profiles =
        Profiles(
          selector:,
          default: case default {
            Ok(json.String(d)) -> d
            _ -> ""
          },
          defaults: list.map(defaults, fn(pr) {
            #(pr.0, result.unwrap(pr.1, []))
          }),
        )
      #(Some(profiles), problems)
    }
    _ -> #(None, ["profiles must be an object"])
  }
}

// Every profile default names a declared, non-secret variable and
// satisfies its constraints, as its own default would have to.
fn profile_problems(
  _profile: String,
  values: List(#(String, Json)),
  vars: List(#(String, Def)),
) -> List(String) {
  list.flat_map(values, fn(pair) {
    let #(name, value) = pair
    case list.key_find(vars, name) {
      Error(Nil) -> [name <> " is not a declared variable"]
      Ok(def) ->
        case list.key_find(def, "secret") {
          Ok(json.Bool(True)) -> [
            name <> " is secret, and a secret has no value in a config file",
          ]
          _ ->
            case declare(name, with_default(def, value)) {
              Error(p) -> [name <> " " <> p]
              Ok(var) ->
                docuconf.check_declaration({
                  use _ <- docuconf.env(var)
                  docuconf.succeed(Nil)
                })
                |> list.map(fn(p) {
                  // "variable NAME: default does not satisfy ..."
                  case string.split_once(p, ": ") {
                    Ok(#(_, rest)) -> name <> " " <> rest
                    Error(Nil) -> p
                  }
                })
            }
        }
    }
  })
}

fn with_default(def: Def, value: Json) -> Def {
  def
  |> list.filter(fn(f) { f.0 != "default" && f.0 != "required" })
  |> list.append([#("default", value)])
}

fn read_overlays(o: Json) -> #(List(Overlay), List(String)) {
  case o {
    json.Object(entries) -> {
      let read =
        list.map(entries, fn(e) {
          let #(name, def) = e
          let fail = fn(m) { "overlay " <> name <> ": " <> m }
          case def {
            json.Object(f) -> {
              let text = fn(k) {
                case list.key_find(f, k) {
                  Ok(json.String(s)) -> s
                  _ -> ""
                }
              }
              let ov =
                Overlay(
                  name:,
                  format: text("format"),
                  path: text("path"),
                  separator: text("keySeparator"),
                )
              let problems =
                list.flatten([
                  list.filter_map(f, fn(field) {
                    case
                      list.contains(
                        [
                          "name", "description", "format", "path",
                          "keySeparator", "reload",
                        ],
                        field.0,
                      )
                    {
                      True -> Error(Nil)
                      False -> Ok(fail("unknown field " <> field.0))
                    }
                  }),
                  when(
                    !docuconf_input_name(name),
                    fail("name must be a DNS label"),
                  ),
                  when(
                    !list.contains(["json", "yaml", "toml"], ov.format),
                    fail("format must be json, yaml or toml"),
                  ),
                  when(
                    !absolute(ov.path),
                    fail(
                      "path "
                      <> json.quote(ov.path)
                      <> " must be absolute and normalised",
                    ),
                  ),
                  when(
                    ov.separator != ":" && ov.separator != ".",
                    fail("keySeparator must be \":\" or \".\""),
                  ),
                  case list.key_find(f, "reload") {
                    Error(Nil) | Ok(json.String("restart")) -> []
                    Ok(json.String("watch")) -> [
                      fail(
                        "reload: watch is not supported: docuconf reads an overlay once, at boot",
                      ),
                    ]
                    Ok(_) -> [fail("reload must be restart or watch")]
                  },
                ])
              #(Some(ov), problems)
            }
            _ -> #(None, [fail("must be an object")])
          }
        })
      #(
        list.filter_map(read, fn(r) { option.to_result(r.0, Nil) })
          |> list.sort(fn(a, b) { string.compare(a.name, b.name) }),
        list.flat_map(read, fn(r) { r.1 }),
      )
    }
    _ -> #([], ["overlays must be an object"])
  }
}

fn when(cond: Bool, problem: String) -> List(String) {
  case cond {
    True -> [problem]
    False -> []
  }
}

fn docuconf_input_name(name: String) -> Bool {
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

fn absolute(path: String) -> Bool {
  string.starts_with(path, "/")
  && string.length(path) > 1
  && !string.contains(path, "//")
  && !string.ends_with(path, "/")
  && !list.any(string.split(path, "/"), fn(seg) { seg == "." || seg == ".." })
}

// ---- profiles and overlays ------------------------------------------------------

// The profile in effect: the selector's value when the environment sets it,
// read as #Validate reads it (for a string selector, the empty string is a
// value), or profiles.default.
fn selected(
  p: Profiles,
  vars: List(#(String, Def)),
  env: Dict(String, String),
) -> String {
  let is_string = case list.key_find(vars, p.selector) {
    Ok(def) -> list.key_find(def, "type") == Ok(json.String("string"))
    Error(Nil) -> False
  }
  case dict.get(env, p.selector) {
    Ok(raw) if raw != "" || is_string -> raw
    _ -> p.default
  }
}

// Each variable the profile sets takes the profile's value as its default;
// a required one is then satisfied by it (SPEC §4.4).
fn with_profile(
  vars: List(#(String, Def)),
  p: Profiles,
  profile: String,
) -> List(#(String, Def)) {
  let values = list.key_find(p.defaults, profile) |> result.unwrap([])
  list.map(vars, fn(v) {
    case list.key_find(values, v.0) {
      Ok(value) -> #(v.0, with_default(v.1, value))
      Error(Nil) -> v
    }
  })
}

// Reads every overlay (SPEC §4.7): the value of each variable at its
// configKey, as the wire string it stands for, and the violations of the
// overlay files themselves. The first overlay, by name, that sets a
// variable wins.
fn overlay_layers(
  c: Contract,
  root: Option(String),
) -> #(Dict(String, Layer), List(docuconf.Violation)) {
  let selector = option.map(c.profiles, fn(p) { p.selector })
  list.fold(c.overlays, #(dict.new(), []), fn(acc, ov) {
    let #(layers, violations) = acc
    let path = case root {
      Some(r) if r != "" -> r <> ov.path
      _ -> ov.path
    }
    let malformed = fn(msg) {
      #(layers, [
        docuconf.Violation(
          ov.name,
          docuconf.FileKind,
          docuconf.FileMalformed,
          msg,
        ),
        ..violations
      ])
    }
    case docuconf.read_bytes(path) {
      // An overlay is optional.
      Error("enoent") -> acc
      Error(why) -> #(layers, [
        docuconf.Violation(
          ov.name,
          docuconf.FileKind,
          docuconf.FileUnreadable,
          path <> " cannot be read (" <> why <> ")",
        ),
        ..violations
      ])
      Ok(bits) ->
        case bit_array.to_string(bits) {
          Error(Nil) -> malformed(path <> " is not valid UTF-8 text")
          Ok(text) -> {
            let text = case text {
              "\u{FEFF}" <> rest -> rest
              _ -> text
            }
            let parsed = case ov.format {
              "yaml" -> yaml.parse(text)
              "toml" -> toml.parse(text)
              _ -> json.parse(text)
            }
            case parsed {
              Error(why) ->
                malformed(
                  path
                  <> " is not valid "
                  <> string.uppercase(ov.format)
                  <> " ("
                  <> why
                  <> ")",
                )
              Ok(json.Object(_) as doc) ->
                list.fold(c.vars, #(layers, violations), fn(acc, v) {
                  let #(name, def) = v
                  case list.key_find(def, "configKey") {
                    Ok(json.String(key)) if Some(name) != selector ->
                      case lookup(doc, string.split(key, ov.separator)) {
                        Ok(value) if value != json.Null ->
                          case dict.has_key(acc.0, name) {
                            True -> acc
                            False -> #(
                              dict.insert(
                                acc.0,
                                name,
                                overlay_value(def, value, ov.name, key),
                              ),
                              acc.1,
                            )
                          }
                        _ -> acc
                      }
                    _ -> acc
                  }
                })
              Ok(_) -> malformed(path <> " does not hold an object")
            }
          }
        }
    }
  })
}

fn lookup(doc: Json, keys: List(String)) -> Result(Json, Nil) {
  case keys, doc {
    [], _ -> Ok(doc)
    [k, ..rest], json.Object(fields) ->
      list.key_find(fields, k) |> result.try(lookup(_, rest))
    _, _ -> Error(Nil)
  }
}

// A native overlay value as the wire string it stands for (SPEC §4.7),
// which the variable then parses and checks like an environment value.
fn overlay_value(def: Def, value: Json, overlay: String, key: String) -> Layer {
  let at = fn(msg) {
    docuconf.LayerInvalid(
      "overlay " <> overlay <> ", at " <> key <> ": " <> msg,
    )
  }
  case list.key_find(def, "secret"), list.key_find(def, "type") {
    Ok(json.Bool(True)), _ ->
      docuconf.LayerInvalid(
        "is secret, but overlay "
        <> overlay
        <> " sets it at "
        <> key
        <> "; supply secrets through the environment",
      )
    _, Ok(json.String("json")) -> docuconf.LayerText(json.to_string(value))
    _, Ok(json.String("list")) | _, Ok(json.String("keySet")) ->
      case value {
        json.Array(items) ->
          case
            list.index_map(items, fn(item, i) { #(item, i) })
            |> list.try_map(fn(pair) {
              scalar_text(pair.0)
              |> result.map_error(fn(kind) {
                "item "
                <> int.to_string(pair.1 + 1)
                <> " is "
                <> kind
                <> ", not a scalar"
              })
            })
          {
            Ok(texts) -> docuconf.LayerItems(texts)
            Error(msg) -> at(msg)
          }
        other -> at("is " <> kind_of(other) <> ", not a list")
      }
    _, _ ->
      case scalar_text(value) {
        Ok(text) -> docuconf.LayerText(text)
        Error(kind) -> at("is " <> kind <> ", not a scalar")
      }
  }
}

// A string as it is, a bool as true or false, a number with an integral
// value as an integer (50.0 is 50), any other number in shortest
// round-trip decimal.
fn scalar_text(value: Json) -> Result(String, String) {
  case value {
    json.String(s) -> Ok(s)
    json.Bool(True) -> Ok("true")
    json.Bool(False) -> Ok("false")
    json.Int(i) -> Ok(int.to_string(i))
    json.Float(f) ->
      case f == float.floor(f) && float.absolute_value(f) <. 9.2e18 {
        True -> Ok(int.to_string(float.truncate(f)))
        False -> Ok(float.to_string(f))
      }
    other -> Error(kind_of(other))
  }
}

fn kind_of(value: Json) -> String {
  case value {
    json.Object(_) -> "an object"
    json.Array(_) -> "a list"
    json.Null -> "null"
    _ -> "a scalar"
  }
}

// ---- the declaration ------------------------------------------------------------

fn build_spec(c: Contract) -> Result(Spec(Dict(String, Value)), List(String)) {
  let #(vars, var_problems) =
    list.fold(c.vars, #([], []), fn(acc, pair) {
      let #(name, def) = pair
      case declare(name, def) {
        Ok(var) -> #([#(name, var), ..acc.0], acc.1)
        Error(p) -> #(acc.0, ["variable " <> name <> ": " <> p, ..acc.1])
      }
    })
  let #(files, file_problems) =
    list.fold(c.files, #([], []), fn(acc, pair) {
      let #(name, def) = pair
      case declare_file(name, def) {
        Ok(file) -> #([#(name, file), ..acc.0], acc.1)
        Error(p) -> #(acc.0, ["file " <> name <> ": " <> p, ..acc.1])
      }
    })
  case list.append(list.reverse(var_problems), list.reverse(file_problems)) {
    [] -> Ok(build(list.reverse(vars), list.reverse(files), []))
    problems -> Error(problems)
  }
}

fn build(
  vars: List(#(String, Var(Value))),
  files: List(#(String, docuconf.File(Value))),
  handles: List(#(String, fn(Values) -> Value)),
) -> Spec(Dict(String, Value)) {
  case vars, files {
    [], [] -> {
      use v <- docuconf.build
      dict.from_list(list.map(handles, fn(h) { #(h.0, h.1(v)) }))
    }
    [#(name, var), ..rest], _ -> {
      use value <- docuconf.env(var)
      build(rest, files, [#(name, value), ..handles])
    }
    [], [#(name, file), ..rest] -> {
      use value <- docuconf.file(file)
      build([], rest, [#(name, value), ..handles])
    }
  }
}

// ---- one variable -------------------------------------------------------------

fn declare(name: String, def: Def) -> Result(Var(Value), String) {
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
      let b = docuconf.exact_int(name, description)
      use b <- result.try(apply(b, def, "min", whole, docuconf.exact_min))
      use b <- result.try(apply(b, def, "max", whole, docuconf.exact_max))
      finish(b, def, int_value, exact_of)
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
    "keySet" -> {
      use encoding <- result.try(list_encoding(def))
      let b = docuconf.key_set_with(name, description, encoding:)
      use b <- result.try(apply(b, def, "minKeys", whole, docuconf.min_keys))
      use b <- result.try(apply(b, def, "maxKeys", whole, docuconf.max_keys))
      use b <- result.try(apply(
        b,
        def,
        "keyMinLength",
        whole,
        docuconf.key_min_length,
      ))
      use b <- result.try(apply(
        b,
        def,
        "keyMaxLength",
        whole,
        docuconf.key_max_length,
      ))
      use b <- result.try(documented(b, def))
      use secret <- result.try(field(def, "secret", bool_of))
      case secret, list.key_find(def, "default") {
        Some(False), _ -> Error("a keySet is always secret")
        _, Ok(_) -> Error("a secret must not have a default")
        _, Error(Nil) ->
          finish_var(b, def, KeySetValue, fn(_) {
            Error("a secret must not have a default")
          })
      }
    }
    "json" -> {
      let b =
        docuconf.json(name, description, decoder: json.decoder(), encode: fn(j) {
          j
        })
      use b <- result.try(apply(b, def, "schema", any, docuconf.schema))
      use b <- result.try(case list.key_find(def, "schema") {
        Error(Nil) -> Ok(b)
        Ok(schema) ->
          case json_schema.problems(schema) {
            [] -> Ok(docuconf.check_json(b, json_schema.validate(schema, _)))
            problems -> Error("schema " <> string.join(problems, "; "))
          }
      })
      use b <- result.try(apply(b, def, "maxLength", whole, docuconf.max_length))
      finish(b, def, JsonValue, Ok)
    }
    other -> Error("unknown type " <> json.quote(other))
  }
}

// details (docs only, SPEC §4.2: checked with the declaration, never read
// at runtime) and deprecated.
fn documented(b: VarBuilder(a), def: Def) -> Result(VarBuilder(a), String) {
  use b <- result.try(apply(b, def, "details", text, docuconf.details))
  use deprecation <- result.try(deprecation(def))
  case deprecation {
    None -> Ok(b)
    Some(#(message, replaced_by)) -> {
      let b = docuconf.deprecated(b, message)
      Ok(case replaced_by {
        Some(r) -> docuconf.replaced_by(b, r)
        None -> b
      })
    }
  }
}

fn deprecation(def: Def) -> Result(Option(#(String, Option(String))), String) {
  case list.key_find(def, "deprecated") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Object(d)) -> {
      use message <- result.try(
        text(d, "message") |> required_field("deprecated.message"),
      )
      use replaced_by <- result.try(text(d, "replacedBy"))
      Ok(Some(#(message, replaced_by)))
    }
    Ok(_) -> Error("deprecated must be an object with a message")
  }
}

// ---- one file input -----------------------------------------------------------

fn declare_file(
  name: String,
  def: Def,
) -> Result(docuconf.File(Value), String) {
  use type_ <- result.try(text(def, "type") |> required_field("type"))
  use path <- result.try(text(def, "path") |> required_field("path"))
  let description =
    text(def, "description") |> result.unwrap(Some("")) |> option.unwrap("")
  case type_ {
    "config" -> {
      use format <- result.try(text(def, "format") |> required_field("format"))
      use check <- result.try(case list.key_find(def, "schema") {
        Error(Nil) -> Ok(fn(_) { [] })
        Ok(schema) ->
          case json_schema.problems(schema) {
            [] -> Ok(json_schema.validate(schema, _))
            problems -> Error("schema " <> string.join(problems, "; "))
          }
      })
      let b =
        docuconf.config_file_json(name, description, path:, format:, check:)
      use b <- result.try(apply_file(
        b,
        def,
        "schema",
        any,
        docuconf.file_schema,
      ))
      finish_file(b, def, JsonValue)
    }
    "text" -> {
      let b = docuconf.text(name, description, path:)
      use b <- result.try(apply_file(
        b,
        def,
        "pattern",
        text,
        docuconf.text_pattern,
      ))
      use b <- result.try(apply_file(
        b,
        def,
        "minLength",
        whole,
        docuconf.text_min_length,
      ))
      use b <- result.try(apply_file(
        b,
        def,
        "maxLength",
        whole,
        docuconf.text_max_length,
      ))
      finish_file(b, def, StringValue)
    }
    "binary" ->
      finish_file(docuconf.binary(name, description, path:), def, BinaryValue)
    "tls" -> {
      let b = docuconf.tls(name, description, path:)
      use b <- result.try(apply_file(
        b,
        def,
        "dnsNames",
        strings,
        docuconf.dns_names,
      ))
      use algorithms <- result.try(strings(def, "keyAlgorithms"))
      use b <- result.try(case algorithms {
        None -> Ok(b)
        Some(names) ->
          list.try_map(names, fn(n) {
            case n {
              "RSA" -> Ok(docuconf.Rsa)
              "ECDSA" -> Ok(docuconf.Ecdsa)
              "Ed25519" -> Ok(docuconf.Ed25519)
              other -> Error("unknown key algorithm " <> json.quote(other))
            }
          })
          |> result.map(docuconf.key_algorithms(b, _))
      })
      use b <- result.try(apply_file(
        b,
        def,
        "minRemaining",
        span,
        docuconf.min_remaining,
      ))
      use require_ca <- result.try(flag(def, "requireCA"))
      let b = case require_ca {
        True -> docuconf.require_ca(b)
        False -> b
      }
      finish_file(b, def, TlsValue)
    }
    "caBundle" -> {
      let b = docuconf.ca_bundle(name, description, path:)
      use b <- result.try(apply_file(
        b,
        def,
        "minCertificates",
        whole,
        docuconf.min_certificates,
      ))
      finish_file(b, def, CaBundleValue)
    }
    "keystore" -> {
      use format <- result.try(case text(def, "format") {
        Ok(Some("pkcs12")) | Ok(None) -> Ok(docuconf.Pkcs12)
        Ok(Some("jks")) -> Ok(docuconf.Jks)
        Ok(Some(other)) ->
          Error("unknown keystore format " <> json.quote(other))
        Error(e) -> Error(e)
      })
      use password_var <- result.try(text(def, "passwordVar"))
      docuconf.keystore(name, description, path:, format:, password_var:)
      |> finish_file(def, KeystoreValue)
    }
    other -> Error("unknown file type " <> json.quote(other))
  }
}

fn apply_file(
  b: docuconf.FileBuilder(a),
  def: Def,
  key: String,
  read: fn(Def, String) -> Result(Option(v), String),
  with: fn(docuconf.FileBuilder(a), v) -> docuconf.FileBuilder(a),
) -> Result(docuconf.FileBuilder(a), String) {
  case read(def, key) {
    Ok(Some(v)) -> Ok(with(b, v))
    Ok(None) -> Ok(b)
    Error(e) -> Error(e)
  }
}

fn finish_file(
  b: docuconf.FileBuilder(a),
  def: Def,
  wrap: fn(a) -> Value,
) -> Result(docuconf.File(Value), String) {
  use b <- result.try(apply_file(b, def, "details", text, docuconf.file_details))
  use b <- result.try(apply_file(b, def, "pathEnv", text, docuconf.path_env))
  use b <- result.try(apply_file(b, def, "maxSize", whole, docuconf.max_size))
  use b <- result.try(apply_file(b, def, "group", text, docuconf.file_group))
  use deprecation <- result.try(deprecation(def))
  let b = case deprecation {
    None -> b
    Some(#(message, replaced_by)) -> {
      let b = docuconf.file_deprecated(b, message)
      case replaced_by {
        Some(r) -> docuconf.file_replaced_by(b, r)
        None -> b
      }
    }
  }
  use <- bool_guard(
    text(def, "reload") == Ok(Some("watch")),
    "reload: watch is not supported: docuconf reads each file once, at boot",
  )
  use secret <- result.try(flag(def, "secret"))
  use required <- result.try(flag(def, "required"))
  let type_ = text(def, "type") |> result.unwrap(None)
  // tls and keystore inputs are always secret; their values are paths.
  let secret = secret && type_ != Some("tls") && type_ != Some("keystore")
  case secret, required {
    True, True ->
      Ok(
        docuconf.secret_file(b)
        |> require_file(def)
        |> docuconf.map_file(fn(s) { SecretValue(docuconf.map_secret(s, wrap)) }),
      )
    True, False ->
      Ok(
        docuconf.secret_file(b)
        |> docuconf.file_optional
        |> docuconf.map_file(fn(o) {
          case o {
            Some(s) -> SecretValue(docuconf.map_secret(s, wrap))
            None -> Absent
          }
        }),
      )
    False, True -> Ok(require_file(b, def) |> docuconf.map_file(wrap))
    False, False ->
      Ok(
        docuconf.file_optional(b)
        |> docuconf.map_file(fn(o) {
          case o {
            Some(v) -> wrap(v)
            None -> Absent
          }
        }),
      )
  }
}

// A required file, its message naming the requiredIf condition that makes
// it required, if any.
fn require_file(b: docuconf.FileBuilder(a), def: Def) -> docuconf.File(a) {
  case list.key_find(def, when_key) {
    Ok(json.String(condition)) -> docuconf.file_required_when(b, condition)
    _ -> docuconf.file_required(b)
  }
}

fn bool_guard(
  cond: Bool,
  problem: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case cond {
    True -> Error(problem)
    False -> next()
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
        bounds(docuconf.exact_int_list_with(name, description, encoding:)),
      )
      use b <- result.try(no_item_lengths(b, def))
      use b <- result.try(apply(
        b,
        def,
        "itemMin",
        whole,
        docuconf.exact_item_min,
      ))
      use b <- result.try(apply(
        b,
        def,
        "itemMax",
        whole,
        docuconf.exact_item_max,
      ))
      finish(b, def, fn(l) { ListValue(list.map(l, int_value)) }, fn(j) {
        list_of(j, exact_of)
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
  use b <- result.try(documented(b, def))
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
    True, _ ->
      case list.key_find(def, when_key) {
        Ok(json.String(condition)) ->
          Ok(docuconf.required_when(b, condition) |> docuconf.map(wrap))
        _ -> Ok(docuconf.required(b) |> docuconf.map(wrap))
      }
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

fn exact_of(j: Json) -> Result(ExactInt, String) {
  int_of(j) |> result.map(Small)
}

fn int_value(n: ExactInt) -> Value {
  case n {
    Small(i) -> IntValue(i)
    Big(text) -> BigIntValue(text)
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
