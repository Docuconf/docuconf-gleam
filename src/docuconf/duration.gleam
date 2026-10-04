//// Go-syntax durations (`1m30s`, `250ms`, `1.5h`): the `go` wire encoding of
//// SPEC §5. Gleam has no standard duration string format, so docuconf parses
//// Go's syntax itself, as `time.ParseDuration` does, and writes durations to
//// the contract in canonical Go form (`1h30m`, never `90m` or `1.5h`).

import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// A span of time, with nanosecond precision.
pub opaque type Duration {
  Duration(nanoseconds: Int)
}

pub fn nanoseconds(n: Int) -> Duration {
  Duration(n)
}

pub fn milliseconds(n: Int) -> Duration {
  Duration(n * 1_000_000)
}

pub fn seconds(n: Int) -> Duration {
  Duration(n * 1_000_000_000)
}

pub fn to_nanoseconds(d: Duration) -> Int {
  d.nanoseconds
}

/// Whole milliseconds, truncated.
pub fn to_milliseconds(d: Duration) -> Int {
  d.nanoseconds / 1_000_000
}

/// Whole seconds, truncated.
pub fn to_seconds(d: Duration) -> Int {
  d.nanoseconds / 1_000_000_000
}

pub fn compare(a: Duration, b: Duration) -> order.Order {
  int.compare(a.nanoseconds, b.nanoseconds)
}

/// Parses a Go duration string.
///
/// ```gleam
/// parse("1m30s") |> result.map(to_milliseconds)
/// // -> Ok(90_000)
/// ```
pub fn parse(s: String) -> Result(Duration, Nil) {
  let #(sign, rest) = case s {
    "-" <> r -> #(-1, r)
    "+" <> r -> #(1, r)
    r -> #(1, r)
  }
  case rest {
    "0" -> Ok(Duration(0))
    "" -> Error(Nil)
    _ -> terms(rest, 0, sign)
  }
}

fn terms(s: String, acc: Int, sign: Int) -> Result(Duration, Nil) {
  case s {
    "" ->
      // The largest Go duration, about 292 years.
      case acc > 9_223_372 * 1_000_000_000_000 + 36_854_775_807 {
        True -> Error(Nil)
        False -> Ok(Duration(sign * acc))
      }
    _ -> {
      let #(whole, rest) = digits(s, "")
      let #(frac, rest) = case rest {
        "." <> r -> digits(r, "")
        _ -> #("", rest)
      }
      case whole == "" && frac == "" {
        True -> Error(Nil)
        False ->
          case unit(rest) {
            Error(Nil) -> Error(Nil)
            Ok(#(mult, rest)) -> {
              let w = case int.parse(whole) {
                Ok(n) -> n
                Error(_) -> 0
              }
              let f = case int.parse(frac) {
                Ok(n) -> n * mult / pow10(string.length(frac))
                Error(_) -> 0
              }
              terms(rest, acc + w * mult + f, sign)
            }
          }
      }
    }
  }
}

fn pow10(n: Int) -> Int {
  list.fold(list.repeat(10, n), 1, fn(acc, x) { acc * x })
}

fn digits(s: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(s) {
    Ok(#(c, rest)) ->
      case string.contains("0123456789", c) {
        True -> digits(rest, acc <> c)
        False -> #(acc, s)
      }
    Error(Nil) -> #(acc, s)
  }
}

fn unit(s: String) -> Result(#(Int, String), Nil) {
  case s {
    "ns" <> r -> Ok(#(1, r))
    "us" <> r -> Ok(#(1000, r))
    "µs" <> r -> Ok(#(1000, r))
    "μs" <> r -> Ok(#(1000, r))
    "ms" <> r -> Ok(#(1_000_000, r))
    "s" <> r -> Ok(#(1_000_000_000, r))
    "m" <> r -> Ok(#(60_000_000_000, r))
    "h" <> r -> Ok(#(3_600_000_000_000, r))
    _ -> Error(Nil)
  }
}

/// Formats a duration in canonical Go form: `1h30m`, `1s500ms`, `0s`.
pub fn to_string(d: Duration) -> String {
  case d.nanoseconds {
    0 -> "0s"
    n if n < 0 -> "-" <> to_string(Duration(0 - n))
    n -> {
      let #(parts, _) =
        list.fold(
          [
            #("h", 3_600_000_000_000),
            #("m", 60_000_000_000),
            #("s", 1_000_000_000),
            #("ms", 1_000_000),
            #("us", 1000),
            #("ns", 1),
          ],
          #("", n),
          fn(acc, u) {
            let #(out, left) = acc
            let count = left / u.1
            case count > 0 {
              True -> #(out <> int.to_string(count) <> u.0, left - count * u.1)
              False -> #(out, left)
            }
          },
        )
      parts
    }
  }
}
