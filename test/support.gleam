//// Test helpers: shell commands, temporary directories, certificates.

import gleam/int
import gleam/string

@external(erlang, "docuconf_test_ffi", "shell")
@external(javascript, "./docuconf_test_ffi.mjs", "shell")
pub fn shell(cmd: String) -> #(Int, String)

/// "erlang" or "javascript".
@external(erlang, "docuconf_test_ffi", "target")
@external(javascript, "./docuconf_test_ffi.mjs", "target")
pub fn target() -> String

/// Reads a UTF-8 text file.
@external(erlang, "docuconf_test_ffi", "read_file")
@external(javascript, "./docuconf_test_ffi.mjs", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

/// Keeps a string, for a callback to report what it saw.
@external(erlang, "docuconf_test_ffi", "remember")
@external(javascript, "./docuconf_test_ffi.mjs", "remember")
pub fn remember(s: String) -> Nil

/// The strings kept with `remember`, oldest first; clears them.
@external(erlang, "docuconf_test_ffi", "recall")
@external(javascript, "./docuconf_test_ffi.mjs", "recall")
pub fn recall() -> List(String)

/// Runs a command that must succeed; returns its output.
pub fn sh(cmd: String) -> String {
  let #(code, out) = shell(cmd)
  case code {
    0 -> out
    _ ->
      panic as {
        "command failed (" <> int.to_string(code) <> "): " <> cmd <> "\n" <> out
      }
  }
}

pub fn temp_dir() -> String {
  string.trim(sh("mktemp -d"))
}

pub fn write(path: String, content: String) -> Nil {
  let _ = sh("mkdir -p \"$(dirname '" <> path <> "')\"")
  let _ =
    sh(
      "cat > '" <> path <> "' <<'DOCUCONF_EOF'\n" <> content <> "\nDOCUCONF_EOF",
    )
  Nil
}

pub fn has(cmd: String) -> Bool {
  shell("command -v " <> cmd <> " >/dev/null 2>&1").0 == 0
}

/// Writes a CA (ca.key, ca.crt) into dir, with openssl.
pub fn make_ca(dir: String) -> Nil {
  let _ =
    sh(
      "cd '"
      <> dir
      <> "' && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes "
      <> "-keyout ca.key -out ca.crt -days 3650 -subj /CN=TestCA "
      <> "-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>&1",
    )
  Nil
}

/// Issues a leaf for `dns` (comma-separated) from the CA in ca_dir into
/// out_dir/tls.crt and tls.key, valid for `days`. alg: "ec" or "rsa:2048"
/// or "ed25519".
pub fn make_leaf(
  ca_dir: String,
  out_dir: String,
  dns: String,
  days: Int,
  alg: String,
) -> Nil {
  let newkey = case alg {
    "ec" -> "-newkey ec -pkeyopt ec_paramgen_curve:P-256"
    other -> "-newkey " <> other
  }
  let san =
    dns
    |> string.split(",")
    |> list_map_join(fn(d) { "DNS:" <> d }, ",")
  let _ =
    sh(
      "mkdir -p '"
      <> out_dir
      <> "' && cd '"
      <> out_dir
      <> "' && "
      <> "openssl req -new "
      <> newkey
      <> " -nodes -keyout tls.key -out leaf.csr -subj /CN=leaf 2>&1 && "
      <> "printf 'subjectAltName="
      <> san
      <> "\\n' > ext.cnf && "
      <> "openssl x509 -req -in leaf.csr -CA '"
      <> ca_dir
      <> "/ca.crt' -CAkey '"
      <> ca_dir
      <> "/ca.key' "
      <> "-CAcreateserial -days "
      <> int.to_string(days)
      <> " -extfile ext.cnf -out tls.crt 2>&1 && "
      <> "cp '"
      <> ca_dir
      <> "/ca.crt' ca.crt && rm -f leaf.csr ext.cnf",
    )
  Nil
}

fn list_map_join(
  items: List(String),
  f: fn(String) -> String,
  sep: String,
) -> String {
  case items {
    [] -> ""
    [x] -> f(x)
    [x, ..rest] -> f(x) <> sep <> list_map_join(rest, f, sep)
  }
}
