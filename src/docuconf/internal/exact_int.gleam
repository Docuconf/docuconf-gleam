//// A 64-bit integer held exactly on both targets, for contract-first mode.
//// On Erlang every integer is `Small`. On JavaScript an `Int` is a double,
//// exact only within ±(2^53 − 1), so an integer beyond that is `Big`: its
//// decimal text, with no `+` and no leading zeros.

import gleam/int
import gleam/order.{type Order}
import gleam/string

pub type ExactInt {
  Small(Int)
  Big(String)
}

/// Compares with an `Int` bound. A `Big` value only exists on JavaScript,
/// where bounds are within ±(2^53 − 1), so it lies beyond any bound on the
/// side of its sign.
pub fn compare(value: ExactInt, bound: Int) -> Order {
  case value {
    Small(n) -> int.compare(n, bound)
    Big("-" <> _) -> order.Lt
    Big(_) -> order.Gt
  }
}

/// The exact decimal text.
pub fn to_string(value: ExactInt) -> String {
  case value {
    Small(n) -> int.to_string(n)
    Big(text) -> text
  }
}

/// Whether digits (no sign, no leading zeros) exceed 9007199254740991, the
/// largest integer a JavaScript number holds exactly.
pub fn beyond_safe(digits: String) -> Bool {
  case int.compare(string.length(digits), 16) {
    order.Lt -> False
    order.Gt -> True
    order.Eq -> string.compare(digits, "9007199254740991") == order.Gt
  }
}
