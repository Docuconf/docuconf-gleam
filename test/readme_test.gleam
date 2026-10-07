//// Every `gleam` code block of README.md must appear, line for line
//// (indentation aside), in a file that CI compiles: test/readme_snippets.gleam (both
//// targets) or the examples/orders app (its own CI job). A README edit
//// that is not mirrored there fails this test.

import gleam/list
import gleam/string
import support

const sources = [
  "test/readme_snippets.gleam", "examples/orders/src/orders/config.gleam",
  "examples/orders/src/orders.gleam",
  "examples/orders/dev/orders/contract.gleam",
  "examples/orders/test/orders_test.gleam",
]

// Lines without their indentation, so a fragment matches wherever it is
// nested.
fn normalise(text: String) -> String {
  string.split(text, "\n")
  |> list.map(string.trim_start)
  |> string.join("\n")
}

fn gleam_blocks(markdown: String) -> List(String) {
  case string.split_once(markdown, "```gleam\n") {
    Error(Nil) -> []
    Ok(#(_, rest)) -> {
      let assert Ok(#(block, rest)) = string.split_once(rest, "```")
      [string.trim_end(block), ..gleam_blocks(rest)]
    }
  }
}

pub fn readme_snippets_are_compiled_test() {
  let assert Ok(readme) = support.read_file("README.md")
  let code =
    list.map(sources, fn(path) {
      case support.read_file(path) {
        Ok(text) -> normalise(text)
        Error(Nil) -> panic as { "cannot read " <> path }
      }
    })
  let blocks = gleam_blocks(readme)
  let assert True = list.length(blocks) >= 8
  list.each(blocks, fn(block) {
    case list.any(code, string.contains(_, normalise(block))) {
      True -> Nil
      False ->
        panic as {
          "this README block is not in any compiled source:\n" <> block
        }
    }
  })
}
