import Base
import ./model.bend as M
import ./lexer.bend as L
import ./schema.bend as S
import ./binding.bend as B

def schema(sql: String) -> M.Checked(M.Schema):
  S.parse(sql)

type Projected is Data:
  Projected{source: String, output: M.Field}

def Projection() -> Data:
  List<&2, Projected>

def projected(field: M.Field, alias: String) -> Projected:
  M.Field{name, k, null} = field
  Projected{name, M.Field{alias, k, null}}

def project_all(fs: M.Fields) -> Projection:
  match fs:
    case Nil{}: Nil{}
    case M.Field{+name, k, null} <> t:
      Projected{name, M.Field{name, k, null}} <> project_all(t)

def project_one(tokens: L.Tokens, fs: M.Fields) -> M.Checked(Projected):
  match tokens:
    case +name <> Nil{}:
      do M.Checked<Projected>:
        field : M.Field <- S.lookup(fs, name)
        return projected(field, name)
    case name <> "as" <> +alias <> Nil{}:
      do M.Checked<Projected>:
        S.valid_name(alias)
        field : M.Field <- S.lookup(fs, name)
        return projected(field, alias)
    case _: Fail{"expected a column name or column AS alias"}

def names(p: Projection) -> M.Fields:
  match p:
    case Nil{}: Nil{}
    case Projected{_, f} <> t: f <> names(t)

def output_name(p: Projected) -> String:
  Projected{_, M.Field{name, _, _}} = p
  name

def project_groups(xs: L.Groups, +fs: M.Fields) -> M.Checked(Projection):
  match xs:
    case Nil{}: Done{Nil{}}
    case ts <> t:
      do M.Checked<Projection>:
        +col : Projected <- project_one(ts, fs)
        +tail : Projection <- project_groups(t, fs)
        S.require(Bool.not(S.has_field(names(tail), output_name(col))), "duplicate output column: " ++ output_name(col))
        return col <> tail

def project(ts: L.Tokens, fs: M.Fields) -> M.Checked(Projection):
  match ts:
    case "*" <> Nil{}: Done{project_all(fs)}
    case _: project_groups(L.chunks(ts, ","), fs)

def sql_name(name: String) -> String:
  "\"" ++ name ++ "\""

# Binding values as text lets SQLite apply the column's declared affinity.
# Preserve its NULLs and 64-bit integers on reads. A BLOB flags a storage
# class mismatch to the runtime even when its bytes resemble an integer.
def projected_value(+source: String, kind: M.SqlType, sqlite: Bool) -> String:
  match kind sqlite:
    case _ False{}: sql_name(source)
    case M.SqlText{} True{}: source
    case _ True{}:
      "CASE typeof(" ++ source ++ ") WHEN 'integer' THEN CAST(" ++ source ++ " AS TEXT) WHEN 'null' THEN NULL ELSE X'' END"

def projected_sql(p: Projected, sqlite: Bool) -> String:
  Projected{source, M.Field{name, kind, _}} = p
  projected_value(source, kind, sqlite) ++ " AS " ++ sql_name(name)

def projection_sql(p: Projection, +sqlite: Bool) -> L.Tokens:
  match p:
    case Nil{}: Nil{}
    case col <> t: projected_sql(col, sqlite) <> projection_sql(t, sqlite)

type Plan is Data:
  Plan{head: L.Tokens, projection: Projection, tail: L.Tokens, params: M.Fields}

def statement(+head: L.Tokens, projection: Projection, tail: L.Tokens, +params: M.Fields, +sqlite: Bool) -> String:
  match projection:
    case Nil{}: B.sql(head, params, sqlite)
    case h <> t:
      columns = String.join(projection_sql(h <> t, sqlite), ", ")
      String.trim_end(B.sql(head, params, sqlite) ++ " " ++ columns ++ " " ++ B.sql(tail, params, sqlite))

def checked(name: String, plan: Plan) -> M.Query:
  Plan{+head, +projection, +tail, +params} = plan
  M.Query{name, statement(head, projection, tail, params, True{}),
    statement(head, projection, tail, params, False{}), params, names(projection)}

def select_parts(split: L.Split, tables: M.Schema) -> M.Checked(Plan):
  match split:
    case L.Split{projections, +table <> +rest, True{}}:
      do M.Checked<Plan>:
        +fs : M.Fields <- S.find_table(tables, table)
        cols : Projection <- project(projections, fs)
        params : M.Fields <- B.where_tail(rest, fs, Nil{})
        return Plan{["select"], cols, "from" <> table <> rest, params}
    case _: Fail{"expected SELECT columns FROM table"}

def wrote(+core: L.Tokens, returning: L.Tokens, found: Bool, fs: M.Fields, params: M.Fields) -> M.Checked(Plan):
  match found:
    case False{}: Done{Plan{core, Nil{}, Nil{}, params}}
    case True{}:
      do M.Checked<Plan>:
        cols : Projection <- project(returning, fs)
        return Plan{List.append(&2, String, core, ["returning"]), cols, Nil{}, params}

def assigned(tokens: L.Tokens, +fs: M.Fields, +seen: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match tokens:
    case +name <> "=" <> rest:
      do M.Checked<M.Fields>:
        S.require(Bool.not(S.has_field(seen, name)), "duplicate assignment: " ++ name)
        B.lookup_value(fs, name, rest, params)
    case _: Fail{"expected column = value in UPDATE"}

def assignments(parts: L.Groups, +fs: M.Fields, +seen: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match parts:
    case Nil{}: Done{params}
    case (+name <> +rest) <> t:
      do M.Checked<M.Fields>:
        next : M.Fields <- assigned(name <> rest, fs, seen, params)
        field : M.Field <- S.lookup(fs, name)
        assignments(t, fs, field <> seen, next)
    case _: Fail{"empty UPDATE assignment"}

def update_parts(split: L.Split, +fs: M.Fields) -> M.Checked(M.Fields):
  match split:
    case L.Split{sets, rest, +found}:
      do M.Checked<M.Fields>:
        params : M.Fields <- assignments(L.chunks(sets, ","), fs, Nil{}, Nil{})
        B.where_tail(Bool.pick(L.Tokens, found, "where" <> rest, Nil{}), fs, params)

def required_present(fs: M.Fields, +seen: M.Fields) -> M.Checked(Unit):
  match fs:
    case Nil{}: Done{Unit{}}
    case M.Field{+name, _, null} <> t:
      do M.Checked<Unit>:
        S.require(null || S.has_field(seen, name), "missing required INSERT column: " ++ name)
        required_present(t, seen)

def inserted(cols: L.Groups, vals: L.Groups, +fs: M.Fields, +seen: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match cols vals:
    case Nil{} Nil{}:
      do M.Checked<M.Fields>:
        required_present(fs, seen)
        return params
    case (+name <> Nil{}) <> ct value <> vt:
      do M.Checked<M.Fields>:
        S.require(Bool.not(S.has_field(seen, name)), "duplicate INSERT column: " ++ name)
        +f : M.Field <- S.lookup(fs, name)
        next : M.Fields <- B.value(value, f, params)
        inserted(ct, vt, fs, f <> seen, next)
    case _ _: Fail{"INSERT needs one value for each named column"}

def insert_values(reversed: L.Tokens, cols: L.Tokens, fs: M.Fields) -> M.Checked(M.Fields):
  match reversed:
    case ")" <> body: inserted(L.chunks(cols, ","), L.chunks(List.reverse(&2, String, body), ","), fs, Nil{}, Nil{})
    case _: Fail{"expected closing ) in VALUES"}

def insert_parts(split: L.Split, fs: M.Fields) -> M.Checked(M.Fields):
  match split:
    case L.Split{cols, "values" <> "(" <> rest, True{}}: insert_values(List.reverse(&2, String, rest), cols, fs)
    case _: Fail{"expected INSERT INTO table (columns) VALUES (values)"}

def write_parts(+core: L.Tokens, returning: L.Tokens, found: Bool, tables: M.Schema) -> M.Checked(Plan):
  match core:
    case "insert" <> "into" <> table <> "(" <> rest:
      do M.Checked<Plan>:
        +fs : M.Fields <- S.find_table(tables, table)
        params : M.Fields <- insert_parts(L.split_at(rest, ")", Nil{}), fs)
        wrote(core, returning, found, fs, params)
    case "update" <> table <> "set" <> rest:
      do M.Checked<Plan>:
        +fs : M.Fields <- S.find_table(tables, table)
        params : M.Fields <- update_parts(L.split_at(rest, "where", Nil{}), fs)
        wrote(core, returning, found, fs, params)
    case "delete" <> "from" <> table <> rest:
      do M.Checked<Plan>:
        +fs : M.Fields <- S.find_table(tables, table)
        params : M.Fields <- B.where_tail(rest, fs, Nil{})
        wrote(core, returning, found, fs, params)
    case _: Fail{"expected SELECT, INSERT, UPDATE, or DELETE"}

def writes(split: L.Split, tables: M.Schema) -> M.Checked(Plan):
  L.Split{core, cols, found} = split
  write_parts(core, cols, found, tables)

def plan(ts: L.Tokens, tables: M.Schema) -> M.Checked(Plan):
  match ts:
    case "select" <> rest: select_parts(L.split_at(rest, "from", Nil{}), tables)
    case _: writes(L.split_at(ts, "returning", Nil{}), tables)

def single(groups: L.Groups) -> M.Checked(L.Tokens):
  match groups:
    case ts <> Nil{}: Done{ts}
    case ts <> Nil{} <> Nil{}: Done{ts}
    case _: Fail{"expected exactly one SQL query"}

def query(tables: M.Schema, +name: String, sql: String) -> M.Checked(M.Query):
  do M.Checked<M.Query>:
    S.require(L.identifier(name), "invalid query name: " ++ name)
    tokens : L.Tokens <- L.tokenize(sql)
    ts : L.Tokens <- single(L.chunks(tokens, ";"))
    compiled : Plan <- plan(ts, tables)
    return checked(name, compiled)
