//// Checks the signature on incoming payment webhooks against the key set
//// in `WEBHOOK_KEYS`.

import docuconf.{type KeySet}
import gleam/bit_array
import gleam/crypto
import gleam/string

/// Whether `signature`, the hex HMAC-SHA256 of `body`, was made with any key
/// in `keys`. Accepting every key in the set is what lets a key be rotated:
/// during the overlap the old and the new key both work.
pub fn verify(keys: KeySet, body: BitArray, signature: String) -> Bool {
  let got = bit_array.from_string(string.lowercase(signature))
  // any_key checks every key, so the time taken does not say which matched.
  docuconf.any_key(keys, fn(key) {
    crypto.hmac(body, crypto.Sha256, bit_array.from_string(key))
    |> bit_array.base16_encode
    |> string.lowercase
    |> bit_array.from_string
    |> crypto.secure_compare(got)
  })
}
