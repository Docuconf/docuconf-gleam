//// The shop: one program, two roles. It loads contract.json through
//// docuconf's contract-first mode, prints one line saying what it would run,
//// and exits. On a bad environment it prints every problem and exits 1.

import docuconf
import gleam/io
import shop/config

pub fn main() -> Nil {
  case contract() {
    Error(reason) -> {
      io.println_error("shop: cannot read contract.json: " <> reason)
      exit(1)
    }
    Ok(contract) ->
      case config.load(contract, docuconf.options()) {
        Ok(config) -> io.println(config.summary(config))
        // The SDK's report: every problem with its code, never a secret.
        // load has already written it to the termination log.
        Error(error) -> {
          io.println_error(docuconf.describe(error))
          exit(1)
        }
      }
  }
}

/// The contract: contract.json, from the directory the shop runs in.
pub fn contract() -> Result(String, String) {
  read_file("contract.json")
}

@external(erlang, "shop_ffi", "read_file")
@external(javascript, "./shop_ffi.mjs", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "shop_ffi", "exit")
@external(javascript, "./shop_ffi.mjs", "exit")
fn exit(status: Int) -> a
