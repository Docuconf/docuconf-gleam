//// The webhook key set: a rotation, step by step, and the key sets that
//// fail at boot.

import docuconf
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import orders/config
import orders/webhook

fn load(env: List(#(String, String))) {
  let options =
    docuconf.options()
    |> docuconf.with_env(dict.from_list(env))
  docuconf.load_with(config.spec(), options)
}

const old_key = "oooooooooooooooooooooooooooooooo"

const new_key = "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn"

const body = "{\"order\":\"42\",\"status\":\"paid\"}"

fn sign(key: String) -> String {
  crypto.hmac(
    bit_array.from_string(body),
    crypto.Sha256,
    bit_array.from_string(key),
  )
  |> bit_array.base16_encode
  |> string.lowercase
}

// WEBHOOK_KEYS as the service loads it at boot.
fn keys(value: String) -> List(String) {
  let assert Ok(config) =
    load([
      #("DATABASE_URL", "postgres://u:p@db/orders"),
      #("WEBHOOK_KEYS", value),
    ])
  let assert option.Some(keys) = config.webhook_keys
  docuconf.reveal(keys)
}

fn accepts(keys: List(String), key: String) -> Bool {
  webhook.verify(keys, bit_array.from_string(body), sign(key))
}

pub fn rotation_test() {
  // Before: the old key only.
  let ks = keys(old_key)
  assert accepts(ks, old_key)
  assert !accepts(ks, new_key)
  // The overlap: both keys.
  let ks = keys(old_key <> "," <> new_key)
  assert accepts(ks, old_key)
  assert accepts(ks, new_key)
  // After: the new key only.
  let ks = keys(new_key)
  assert !accepts(ks, old_key)
  assert accepts(ks, new_key)
}

pub fn bad_signature_test() {
  let ks = keys(old_key)
  assert !webhook.verify(ks, bit_array.from_string(body), "")
  assert !webhook.verify(ks, bit_array.from_string(body), "not hex")
  assert !accepts(ks, string.repeat("x", 32))
  assert !webhook.verify(ks, bit_array.from_string(body <> " "), sign(old_key))
  assert !webhook.verify([], bit_array.from_string(body), sign(old_key))
}

pub fn webhook_keys_are_optional_test() {
  let assert Ok(config) = load([#("DATABASE_URL", "postgres://u:p@db/orders")])
  assert config.webhook_keys == option.None
}

pub fn bad_key_sets_test() {
  [
    // An empty second key (a trailing comma).
    #(old_key <> ",", docuconf.OutOfRange),
    // A truncated key.
    #(old_key <> "," <> string.slice(new_key, 0, 10), docuconf.OutOfRange),
    #(
      old_key <> "," <> new_key <> "," <> string.repeat("x", 32),
      docuconf.TooManyItems,
    ),
  ]
  |> list.each(fn(c) {
    let #(value, code) = c
    let assert Error(docuconf.InvalidConfig([violation])) =
      load([
        #("DATABASE_URL", "postgres://u:p@db/orders"),
        #("WEBHOOK_KEYS", value),
      ])
    assert violation.input == "WEBHOOK_KEYS"
    assert violation.code == code
    assert !string.contains(violation.message, old_key)
    assert !string.contains(violation.message, string.slice(new_key, 0, 10))
  })
}
