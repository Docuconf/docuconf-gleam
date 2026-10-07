//// Exports the contract: `gleam run -m orders/contract`.

import docuconf
import orders/config

pub fn main() {
  let assert Ok(Nil) =
    docuconf.write_contract(config.spec(), name: "orders", to: "contract.cue")
}
