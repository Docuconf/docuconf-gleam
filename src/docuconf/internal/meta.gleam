//// What a declaration says about each input, for export and declaration
//// checks. Constraint values are kept as JSON, in contract field order.

import docuconf/json.{type Json}
import gleam/option.{type Option}

pub type VarMeta {
  VarMeta(
    name: String,
    type_: String,
    description: String,
    /// CommonMark for generated docs only (SPEC §4.2); never read at runtime.
    details: Option(String),
    required: Bool,
    secret: Bool,
    group: Option(String),
    examples: List(String),
    config_key: Option(String),
    deprecated: Option(String),
    /// Type-specific contract fields (min, pattern, values, encoding...).
    fields: List(#(String, Json)),
    default: Option(Json),
    flag_warning: Bool,
    /// Problems found while building, reported as declaration errors.
    problems: List(String),
  )
}

pub type FileMeta {
  FileMeta(
    name: String,
    type_: String,
    format: Option(String),
    description: String,
    details: Option(String),
    required: Bool,
    secret: Bool,
    group: Option(String),
    path: String,
    path_env: Option(String),
    max_size: Option(Int),
    fields: List(#(String, Json)),
    problems: List(String),
  )
}

pub type Meta {
  VarInput(VarMeta)
  FileInput(FileMeta)
}
