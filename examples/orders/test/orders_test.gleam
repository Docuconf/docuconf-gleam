import docuconf
import gleam/dict
import gleeunit
import orders/config

pub fn main() -> Nil {
  gleeunit.main()
}

fn load(env: List(#(String, String))) {
  let options =
    docuconf.options()
    |> docuconf.with_env(dict.from_list(env))
  docuconf.load_with(config.spec(), options)
}

pub fn declaration_test() {
  assert docuconf.check_declaration(config.spec()) == []
}

pub fn defaults_test() {
  let assert Ok(config) = load([#("DATABASE_URL", "postgres://u:p@db/orders")])
  assert config.port == 8080
  assert docuconf.reveal(config.database_url) == "postgres://u:p@db/orders"
}

pub fn bad_port_test() {
  let assert Error(docuconf.InvalidConfig([violation])) =
    load([#("DATABASE_URL", "postgres://db/orders"), #("PORT", "0")])
  assert violation.input == "PORT"
  assert violation.code == docuconf.OutOfRange
}

pub fn contract_is_up_to_date_test() {
  assert docuconf.check_contract(
      config.spec(),
      name: "orders",
      against: "contract.cue",
    )
    == Ok(Nil)
}
