import Base
import ./model.bend as M

def bend_type(kind: M.SqlType) -> String:
  match kind:
    case M.SqlInt{}: "D.I64"
    case M.SqlText{}: "String"
    case M.SqlBool{}: "Bool"

def codec(kind: M.SqlType) -> String:
  match kind:
    case M.SqlInt{}: "int"
    case M.SqlText{}: "text"
    case M.SqlBool{}: "bool"

def field_type(kind: M.SqlType, nullable: Bool) -> String:
  match nullable:
    case False{}: bend_type(kind)
    case True{}: "Maybe<&2, " ++ bend_type(kind) ++ ">"

# The checker accepts ASCII identifiers. The prefixes also let SQL names like
# "type" appear in the generated Bend module.
def declarations(fields: M.Fields, +prefix: String) -> List<&2, String>:
  match fields:
    case Nil{}: Nil{}
    case M.Field{name, kind, nullable} <> rest:
      (prefix ++ name ++ ": " ++ field_type(kind, nullable)) <> declarations(rest, prefix)

def field_names(fields: M.Fields, +prefix: String) -> List<&2, String>:
  match fields:
    case Nil{}: Nil{}
    case M.Field{name, _, _} <> rest: (prefix ++ name) <> field_names(rest, prefix)

def binding(name: String, +kind: M.SqlType, nullable: Bool) -> String:
  match nullable:
    case False{}: "Some{D.write_" ++ codec(kind) ++ "(p_" ++ name ++ ")}"
    case True{}:
      "Maybe.map(&2, " ++ bend_type(kind) ++ ", String, D.write_" ++ codec(kind) ++ ", p_" ++ name ++ ")"

def bindings(fields: M.Fields) -> List<&2, String>:
  match fields:
    case Nil{}: Nil{}
    case M.Field{name, kind, nullable} <> rest: binding(name, kind, nullable) <> bindings(rest)

def decode_lines(fields: M.Fields) -> String:
  match fields:
    case Nil{}: ""
    case M.Field{+name, +kind, +nullable} <> rest:
      read = Bool.pick(String, nullable, "D.nullable", "D.required")
      "        col_" ++ name ++ " : " ++ field_type(kind, nullable) ++ " <- " ++ read
        ++ "(" ++ bend_type(kind) ++ ", D.read_" ++ codec(kind) ++ ", " ++ String.quote(name)
        ++ ", raw_" ++ name ++ ")\n" ++ decode_lines(rest)

def row_decoder(+name: String, +cols: M.Fields) -> String:
  +record = "Row_" ++ name
  "type " ++ record ++ " is Data:\n"
    ++ "  " ++ record ++ "{" ++ String.join(declarations(cols, "col_"), ", ") ++ "}\n\n"
    ++ "def decode_" ++ name ++ "(row: R.Row) -> D.Checked(" ++ record ++ "):\n"
    ++ "  match row:\n    case " ++ String.join(field_names(cols, "raw_"), " <> ") ++ " <> Nil{}:\n"
    ++ "      do Result<&2, &2, String, " ++ record ++ ">:\n"
    ++ decode_lines(cols) ++ "        return " ++ record ++ "{" ++ String.join(field_names(cols, "col_"), ", ") ++ "}\n"
    ++ "    case _: Fail{\"unexpected result row width\"}\n\n"

def guards(bounds: List<&2, String>) -> List<&2, String>:
  match bounds:
    case Nil{}: Nil{}
    case name <> rest: ("D.nonnegative(p_" ++ name ++ ")") <> guards(rest)

def function_body(sqlite: String, pg: String, params: M.Fields, width: U32,
  +return_type: String, finish: String, +indent: String) -> String:
  args = "[" ++ String.join(bindings(params), ", ") ++ "]"
  "do IO<R.Outcome<" ++ return_type ++ ">>:\n"
    ++ indent ++ "  result : R.Outcome<R.Rows> <- R.run(db,\n" ++ indent ++ "    " ++ String.quote(sqlite) ++ ",\n" ++ indent ++ "    "
    ++ String.quote(pg) ++ ",\n" ++ indent ++ "    " ++ args ++ ", " ++ U32.show(width) ++ ")\n"
    ++ indent ++ "  return " ++ finish ++ "\n"

def function(+name: String, sqlite: String, pg: String, +params: M.Fields, width: U32,
  +return_type: String, finish: String, bounds: List<&2, String>) -> String:
  match bounds:
    case Nil{}:
      arguments = String.join("db: R.Db" <> declarations(params, "p_"), ", ")
      "def q_" ++ name ++ "(" ++ arguments ++ ") -> IO(R.Outcome<" ++ return_type ++ ">):\n  "
        ++ function_body(sqlite, pg, params, width, return_type, finish, "  ")
    case h <> t:
      arguments = String.join("db: R.Db" <> declarations(params, "+p_"), ", ")
      valid = String.join(guards(h <> t), " && ")
      "def q_" ++ name ++ "(" ++ arguments ++ ") -> IO(R.Outcome<" ++ return_type ++ ">):\n"
        ++ "  valid = Bool.pick(Result<&2, &2, String, Unit>, " ++ valid ++ ",\n"
        ++ "    Done{Unit{}}, Fail{" ++ String.quote(name ++ ": LIMIT and OFFSET must be nonnegative") ++ "})\n"
        ++ "  act = do R.Action<" ++ return_type ++ ">:\n"
        ++ "    R.Action.checked(Unit, valid)\n"
        ++ "    db => " ++ function_body(sqlite, pg, params, width, return_type, finish, "    ")
        ++ "  act(db)\n"

def query(name: String, sqlite: String, pg: String, params: M.Fields, columns: M.Fields, bounds: List<&2, String>) -> String:
  match columns:
    case Nil{}:
      +n = name
      function(n, sqlite, pg, params, 0, "Unit", "D.command(" ++ String.quote(n) ++ ", result)", bounds)
    case Con{first, rest}:
      +n = name
      +cols : M.Fields = first <> rest
      row_decoder(n, cols) ++ function(n, sqlite, pg, params, U32.from_nat(List.length(&2, M.Field, cols)),
        "List<&2, Row_" ++ n ++ ">", "D.select(~Row_" ++ n ++ ", ~decode_" ++ n ++ ", " ++ String.quote(n) ++ ", result)", bounds)

def queries(items: List<&2, M.Query>) -> String:
  match items:
    case Nil{}: ""
    case M.Query{name, sqlite, pg, params, columns, bounds} <> rest:
      "\n" ++ query(name, sqlite, pg, params, columns, bounds) ++ queries(rest)

def emit(items: List<&2, M.Query>, runtime_import: String, decode_import: String) -> String:
  "# Generated by typed-sql. Edit the source SQL and regenerate.\n"
    ++ "import Base\nimport " ++ runtime_import ++ " as R\nimport " ++ decode_import ++ " as D\n" ++ queries(items)
