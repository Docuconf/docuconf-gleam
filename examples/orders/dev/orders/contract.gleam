//// Exports the contract: `gleam run -m orders/contract`. It lives in
//// `dev/`, so it is not part of the production build.

import docuconf
import gleam/io
import orders/config

pub fn main() -> Nil {
  case
    docuconf.write_contract(config.spec(), name: "orders", to: "contract.cue")
  {
    Ok(Nil) -> io.println("wrote contract.cue")
    Error(error) -> panic as docuconf.describe(error)
  }
}
