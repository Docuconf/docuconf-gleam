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

/// `n` nanoseconds.
pub fn nanoseconds(n: Int) -> Duration {
  Duration(n)
}

/// `n` milliseconds.
pub fn milliseconds(n: Int) -> Duration {
  Duration(n * 1_000_000)
}

/// `n` seconds.
pub fn seconds(n: Int) -> Duration {
  Duration(n * 1_000_000_000)
}

/// `n` minutes.
pub fn minutes(n: Int) -> Duration {
  Duration(n * 60_000_000_000)
}

/// `n` hours.
pub fn hours(n: Int) -> Duration {
  Duration(n * 3_600_000_000_000)
}

/// Whole nanoseconds. To get a `gleam_time` duration:
/// `gleam/time/duration.nanoseconds(to_nanoseconds(d))`.
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

/// Compares two durations.
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

// The largest Go duration, about 292 years.
fn within_range(ns: Int) -> Result(Duration, Nil) {
  case ns > 9_223_372 * 1_000_000_000_000 + 36_854_775_807 {
    True -> Error(Nil)
    False -> Ok(Duration(ns))
  }
}

fn terms(s: String, acc: Int, sign: Int) -> Result(Duration, Nil) {
  case s {
    "" ->
      within_range(acc) |> result_map(fn(d) { Duration(sign * d.nanoseconds) })
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

fn result_map(r: Result(a, Nil), f: fn(a) -> b) -> Result(b, Nil) {
  case r {
    Ok(x) -> Ok(f(x))
    Error(Nil) -> Error(Nil)
  }
}

const second = 1_000_000_000

/// Parses an ISO 8601 duration of days, hours, minutes and seconds, the
/// `iso8601` wire encoding: `PT90S`, `PT1.5S`, `P1DT2H`. Fractions may use
/// `.` or `,`. Years, months and weeks have no fixed length and are
/// rejected, and so are negative durations.
///
/// ```gleam
/// parse_iso8601("PT1M30.5S") |> result.map(to_string)
/// // -> Ok("1m30s500ms")
/// ```
pub fn parse_iso8601(s: String) -> Result(Duration, Nil) {
  case s {
    "P" <> rest -> {
      let #(date, time) = case string.split_once(rest, "T") {
        Ok(#(d, t)) -> #(d, Ok(t))
        Error(Nil) -> #(rest, Error(Nil))
      }
      case date, time {
        "", Error(Nil) | _, Ok("") -> Error(Nil)
        _, _ -> {
          let day = 86_400 * second
          let time_units = [
            #("H", 3600 * second),
            #("M", 60 * second),
            #("S", second),
          ]
          case iso_parts(date, [#("D", day)], 0) {
            Error(Nil) -> Error(Nil)
            Ok(acc) ->
              case time {
                Ok(t) ->
                  case iso_parts(t, time_units, acc) {
                    Ok(ns) -> within_range(ns)
                    Error(Nil) -> Error(Nil)
                  }
                Error(Nil) -> within_range(acc)
              }
          }
        }
      }
    }
    _ -> Error(Nil)
  }
}

// Reads `<number><unit>` terms whose units appear in `units`, in order.
fn iso_parts(
  s: String,
  units: List(#(String, Int)),
  acc: Int,
) -> Result(Int, Nil) {
  case s {
    "" -> Ok(acc)
    _ -> {
      let #(whole, rest) = digits(s, "")
      let #(frac, rest) = case rest {
        "." <> r | "," <> r -> {
          let #(f, r) = digits(r, "")
          case f {
            "" -> #("!", r)
            _ -> #(f, r)
          }
        }
        _ -> #("", rest)
      }
      case whole, frac, string.pop_grapheme(rest) {
        "", _, _ | _, "!", _ -> Error(Nil)
        _, _, Ok(#(u, rest)) ->
          case list.drop_while(units, fn(pair) { pair.0 != u }) {
            [#(_, mult), ..later] ->
              iso_parts(rest, later, acc + decimal(whole, frac, mult))
            [] -> Error(Nil)
          }
        _, _, Error(Nil) -> Error(Nil)
      }
    }
  }
}

/// Parses a decimal number of seconds, the `seconds` wire encoding: `90`,
/// `0.25`.
pub fn parse_seconds(s: String) -> Result(Duration, Nil) {
  let #(whole, frac) = case string.split_once(s, ".") {
    Ok(#(w, f)) -> #(w, f)
    Error(Nil) -> #(s, "")
  }
  case
    all_digits(whole)
    && { frac == "" || all_digits(frac) }
    && !string.ends_with(s, ".")
  {
    True -> within_range(decimal(whole, frac, second))
    False -> Error(Nil)
  }
}

/// Parses the constant format of .NET's `TimeSpan`, the `timespan` wire
/// encoding: `[d.]hh:mm:ss[.fffffff]`, with hours below 24 and minutes and
/// seconds below 60: `00:01:30`, `1.02:03:04.5`.
pub fn parse_timespan(s: String) -> Result(Duration, Nil) {
  case string.split(s, ":") {
    [day_hours, minutes, seconds_frac] -> {
      let #(days, hours) = case string.split_once(day_hours, ".") {
        Ok(#(d, h)) -> #(d, h)
        Error(Nil) -> #("0", day_hours)
      }
      let #(secs, frac) = case string.split_once(seconds_frac, ".") {
        Ok(#(sec, f)) -> #(sec, f)
        Error(Nil) -> #(seconds_frac, "")
      }
      let ok =
        all_digits(days)
        && all_digits(hours)
        && string.length(hours) <= 2
        && all_digits(minutes)
        && string.length(minutes) == 2
        && all_digits(secs)
        && string.length(secs) == 2
        && {
          frac == ""
          && !string.ends_with(seconds_frac, ".")
          || all_digits(frac)
          && string.length(frac) <= 7
        }
      case ok {
        False -> Error(Nil)
        True -> {
          let #(h, m, sec) = #(to_int(hours), to_int(minutes), to_int(secs))
          case h > 23 || m > 59 || sec > 59 {
            True -> Error(Nil)
            False ->
              within_range(
                decimal(days, "", 86_400 * second)
                + h
                * 3600
                * second
                + m
                * 60
                * second
                + decimal(secs, frac, second),
              )
          }
        }
      }
    }
    _ -> Error(Nil)
  }
}

fn all_digits(s: String) -> Bool {
  s != "" && list.all(string.to_graphemes(s), string.contains("0123456789", _))
}

fn to_int(s: String) -> Int {
  case int.parse(s) {
    Ok(n) -> n
    Error(Nil) -> 0
  }
}

// whole.frac units, in nanoseconds, truncated.
fn decimal(whole: String, frac: String, unit: Int) -> Int {
  to_int(whole) * unit + to_int(frac) * unit / pow10(string.length(frac))
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
