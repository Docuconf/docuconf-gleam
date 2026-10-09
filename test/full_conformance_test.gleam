//// Contract-first mode's 64-bit integers and JSON Schema checks (the
//// conformance suite's `int64` and `json-schema` capability tags).

import docuconf
import docuconf/contract_first.{BigIntValue, IntValue, ListValue}
import gleam/dict
import gleam/list
import gleam/string
import support

fn load(contract: String, env: List(#(String, String))) {
  contract_first.load(
    contract,
    docuconf.options()
      |> docuconf.with_env(dict.from_list(env))
      |> docuconf.without_termination_log,
  )
}

fn codes(result) -> List(#(String, String)) {
  case result {
    Ok(_) -> []
    Error(docuconf.InvalidConfig(vs)) ->
      list.map(vs, fn(v: docuconf.Violation) {
        #(v.input, docuconf.code_to_string(v.code))
      })
    Error(e) -> [#("error", docuconf.describe(e))]
  }
}

fn messages(result) -> String {
  case result {
    Error(docuconf.InvalidConfig(vs)) ->
      list.map(vs, fn(v: docuconf.Violation) { v.message })
      |> string.join("\n")
    _ -> ""
  }
}

fn contract(vars: String) -> String {
  "{\"apiVersion\": \"docuconf.dev/v1alpha1\", \"kind\": \"ConfigContract\", \"vars\": {"
  <> vars
  <> "}}"
}

// ---- int64 -------------------------------------------------------------------

const ints = "
  \"OFFSET\": {\"type\": \"int\", \"description\": \"Signed offset\"},
  \"PORT\": {\"type\": \"int\", \"description\": \"Listen port\", \"min\": 1, \"max\": 65535},
  \"IDS\": {\"type\": \"list\", \"description\": \"Some identifiers\", \"items\": \"int\", \"encoding\": \"json\"},
  \"CSV\": {\"type\": \"list\", \"description\": \"Some identifiers\", \"items\": \"int\", \"itemMin\": -5},
  \"IDX\": {\"type\": \"list\", \"description\": \"Some identifiers\", \"items\": \"int\", \"encoding\": \"indexed\"}"

fn text(values, name) -> String {
  let assert Ok(v) = dict.get(values, name)
  let assert Ok(t) = contract_first.int_text(v)
  t
}

pub fn int64_values_are_exact_test() {
  let assert Ok(values) =
    load(contract(ints), [
      #("OFFSET", "9223372036854775807"),
      #("IDS", "[1, 9223372036854775807, -9223372036854775808]"),
      #("CSV", "+0009007199254740993,7"),
      #("IDX__0", "-9223372036854775808"),
    ])
  let assert "9223372036854775807" = text(values, "OFFSET")
  let assert Ok(ListValue(ids)) = dict.get(values, "IDS")
  let assert ["1", "9223372036854775807", "-9223372036854775808"] =
    list.map(ids, fn(v) {
      let assert Ok(t) = contract_first.int_text(v)
      t
    })
  let assert Ok(ListValue([csv, IntValue(7)])) = dict.get(values, "CSV")
  let assert Ok("9007199254740993") = contract_first.int_text(csv)
  let assert Ok(ListValue([idx])) = dict.get(values, "IDX")
  let assert Ok("-9223372036854775808") = contract_first.int_text(idx)
  // The representation: an Int on Erlang, the digits on JavaScript.
  case support.target(), dict.get(values, "OFFSET") {
    "erlang", Ok(IntValue(_)) -> Nil
    "javascript", Ok(BigIntValue("9223372036854775807")) -> Nil
    _, other -> panic as { "unexpected OFFSET " <> string.inspect(other) }
  }
  // Within ±(2^53 - 1) every target has an IntValue.
  let assert Ok(values) =
    load(contract(ints), [#("OFFSET", "-9007199254740991")])
  let assert Ok(IntValue(-9_007_199_254_740_991)) = dict.get(values, "OFFSET")
}

pub fn int64_range_test() {
  let c = contract(ints)
  list.each(
    ["9223372036854775808", "-9223372036854775809", "99999999999999999999"],
    fn(raw) {
      let assert [#("OFFSET", "out_of_range")] =
        codes(load(c, [#("OFFSET", raw)]))
    },
  )
  let assert [#("IDS", "out_of_range")] =
    codes(load(c, [#("IDS", "[9223372036854775808]")]))
  let assert [#("IDS", "invalid_type")] =
    codes(load(c, [#("IDS", "[\"9223372036854775807\"]")]))
  let assert [#("CSV", "out_of_range")] =
    codes(load(c, [#("CSV", "1,-9223372036854775809")]))
  let assert [#("OFFSET", "invalid_type")] =
    codes(load(c, [#("OFFSET", "1e3")]))
}

pub fn int64_bounds_compare_exactly_test() {
  let c = contract(ints)
  // Beyond 2^53 on either side of a bound.
  let assert [#("PORT", "out_of_range")] =
    codes(load(c, [#("PORT", "9007199254740993")]))
  let assert [#("PORT", "out_of_range")] =
    codes(load(c, [#("PORT", "-9223372036854775808")]))
  let assert [#("CSV", "out_of_range")] =
    codes(load(c, [#("CSV", "-9007199254740993")]))
  let assert [] = codes(load(c, [#("CSV", "9007199254740993")]))
}

// ---- json-schema ---------------------------------------------------------------

const schema_vars = "
  \"LIMITS\": {\"type\": \"json\", \"description\": \"Rate limits\", \"schema\": {
    \"type\": \"object\",
    \"properties\": {
      \"perMinute\": {\"type\": \"integer\", \"minimum\": 1},
      \"burst\": {\"type\": \"integer\", \"minimum\": 0, \"exclusiveMaximum\": 100},
      \"name\": {\"type\": \"string\", \"minLength\": 2, \"maxLength\": 3, \"pattern\": \"^[a-z]+$\"},
      \"label\": {\"type\": \"string\", \"maxLength\": 3},
      \"tags\": {\"type\": \"array\", \"items\": {\"enum\": [\"a\", \"b\"]}, \"minItems\": 1, \"maxItems\": 2, \"uniqueItems\": true},
      \"mode\": {\"const\": \"fast\"},
      \"either\": {\"anyOf\": [{\"type\": \"string\"}, {\"type\": \"null\"}]},
      \"one\": {\"oneOf\": [{\"type\": \"integer\"}, {\"type\": \"number\", \"multipleOf\": 0.5}]},
      \"email\": {\"type\": \"string\", \"format\": \"email\"},
      \"extra\": {\"type\": \"object\", \"additionalProperties\": {\"type\": \"boolean\"}}
    },
    \"required\": [\"perMinute\"],
    \"additionalProperties\": false
  }},
  \"TOKEN\": {\"type\": \"json\", \"description\": \"A secret document\", \"secret\": true,
    \"schema\": {\"type\": \"object\", \"properties\": {\"key\": {\"type\": \"string\", \"maxLength\": 3}}}},
  \"ANY\": {\"type\": \"json\", \"description\": \"Anything at all\"}"

pub fn json_schema_accepts_a_matching_value_test() {
  let assert Ok(_) =
    load(contract(schema_vars), [
      #(
        "LIMITS",
        "{\"perMinute\":1,\"burst\":99,\"name\":\"ab\",\"label\":\"😀😀😀\",\"tags\":[\"a\",\"b\"],\"mode\":\"fast\",\"either\":null,\"one\":1.5,\"email\":\"not an email\",\"extra\":{\"x\":true}}",
      ),
      #("ANY", "[1, {\"a\": null}]"),
    ])
}

pub fn json_schema_mismatch_test() {
  let c = contract(schema_vars)
  list.each(
    [
      #("{\"perMinute\":0}", "/perMinute: below minimum 1"),
      #("{\"perMinute\":1,\"perHour\":5}", "/: property perHour is not allowed"),
      #("{}", "/: missing required property perMinute"),
      #("{\"perMinute\":1.5}", "/perMinute: expected integer, got number"),
      #("{\"perMinute\":1,\"burst\":100}", "/burst: must be below 100"),
      #("{\"perMinute\":1,\"name\":\"a\"}", "/name: shorter than 2 characters"),
      #(
        "{\"perMinute\":1,\"name\":\"abcd\"}",
        "/name: longer than 3 characters",
      ),
      #("{\"perMinute\":1,\"name\":\"AB\"}", "/name: does not match pattern"),
      #("{\"perMinute\":1,\"label\":\"😀😀😀😀\"}", "/label: longer than 3"),
      #("{\"perMinute\":1,\"tags\":[]}", "/tags: needs at least 1 items"),
      #(
        "{\"perMinute\":1,\"tags\":[\"a\",\"a\"]}",
        "/tags: items must be unique",
      ),
      #("{\"perMinute\":1,\"tags\":[\"c\"]}", "/tags/0: must be one of"),
      #("{\"perMinute\":1,\"mode\":\"slow\"}", "/mode: must equal \"fast\""),
      #("{\"perMinute\":1,\"either\":1}", "/either: matches none"),
      #("{\"perMinute\":1,\"one\":0.25}", "/one: must match exactly one"),
      #("{\"perMinute\":1,\"extra\":{\"x\":1}}", "/extra/x: expected boolean"),
      #("[]", "/: expected object, got array"),
    ],
    fn(pair) {
      let #(value, fragment) = pair
      let r = load(c, [#("LIMITS", value)])
      let assert [#("LIMITS", "schema_mismatch")] = codes(r)
      case string.contains(messages(r), fragment) {
        True -> Nil
        False ->
          panic as { value <> ": " <> messages(r) <> " lacks " <> fragment }
      }
    },
  )
}

pub fn json_schema_hides_a_secret_test() {
  let r = load(contract(schema_vars), [#("TOKEN", "{\"key\":\"hunter2\"}")])
  let assert [#("TOKEN", "schema_mismatch")] = codes(r)
  let assert False = string.contains(messages(r), "hunter2")
}

pub fn json_schema_checks_the_default_test() {
  let assert Error(docuconf.InvalidDeclaration(_)) =
    load(
      contract(
        "\"J\": {\"type\": \"json\", \"description\": \"A document\", \"schema\": {\"type\": \"integer\"}, \"default\": \"x\"}",
      ),
      [],
    )
}

pub fn json_schema_rejects_what_it_cannot_enforce_test() {
  let problem = fn(schema) {
    case
      load(
        contract(
          "\"J\": {\"type\": \"json\", \"description\": \"A document\", \"schema\": "
          <> schema
          <> "}",
        ),
        [],
      )
    {
      Error(docuconf.InvalidDeclaration(ps)) -> string.join(ps, "; ")
      _ -> ""
    }
  }
  let assert True =
    string.contains(
      problem("{\"type\": \"object\", \"patternProperties\": {}}"),
      "/patternProperties: keyword patternProperties is not supported",
    )
  let assert True =
    string.contains(
      problem("{\"properties\": {\"a\": {\"$ref\": \"#/x\"}}}"),
      "/properties/a/$ref: keyword $ref is not supported",
    )
  let assert True =
    string.contains(
      problem("{\"type\": \"string\", \"pattern\": \"(?=a)b\"}"),
      "/pattern: uses",
    )
  let assert True =
    string.contains(problem("{\"type\": \"strin\"}"), "unknown type strin")
  let assert True =
    string.contains(problem("{\"minLength\": -1}"), "/minLength: must be")
  let assert True =
    string.contains(problem("[1]"), "a schema must be an object or a boolean")
}
