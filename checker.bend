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

def project_groups(xs: L.Groups, +fs: M.Fields, star_seen: Bool) -> M.Checked(Projection):
  match xs:
    case Nil{}: Done{Nil{}}
    case ["*"] <> t:
      do M.Checked<Projection>:
        S.require(Bool.not(star_seen), "duplicate * in projection")
        rest : Projection <- project_groups(t, fs, True{})
        return List.append(&2, Projected, project_all(fs), rest)
    case ts <> t:
      do M.Checked<Projection>:
        col : Projected <- project_one(ts, fs)
        tail : Projection <- project_groups(t, fs, star_seen)
        return col <> tail

def Aliases() -> Data:
  Map<&2, String>

def index_outputs(p: Projection, +aliases: Aliases) -> M.Checked(Aliases):
  match p:
    case Nil{}: Done{aliases}
    case Projected{source, M.Field{+name, _, _}} <> t:
      duplicate = Pair.snd(Aliases, Bool, Map.has(&2, String, aliases, name))
      do M.Checked<Aliases>:
        S.require(Bool.not(duplicate), "duplicate output column: " ++ name)
        index_outputs(t, Map.set(&2, String, aliases, name, source))

type Columns is Data:
  Columns{projection: Projection, aliases: Aliases}

def project(ts: L.Tokens, fs: M.Fields) -> M.Checked(Columns):
  match ts:
    case "*" <> Nil{}: Done{Columns{project_all(fs), MTip{}}}
    case _:
      do M.Checked<Columns>:
        +p : Projection <- project_groups(L.chunks(ts, ","), fs, False{})
        aliases : Aliases <- index_outputs(p, MTip{})
        return Columns{p, aliases}

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
  Plan{head: L.Tokens, projection: Projection, tail: L.Tokens, params: M.Fields, bounds: L.Tokens}

def statement(+head: L.Tokens, projection: Projection, tail: L.Tokens, +params: M.Fields, +sqlite: Bool) -> String:
  match projection:
    case Nil{}: B.sql(head, params, sqlite)
    case h <> t:
      +slots = B.index_slots(params, sqlite, 1, MTip{})
      columns = String.join(projection_sql(h <> t, sqlite), ", ")
      first = String.join(B.sql_tokens(head, slots), " ")
      last = String.join(B.sql_tokens(tail, slots), " ")
      String.trim_end(first ++ " " ++ columns ++ " " ++ last)

def checked(name: String, plan: Plan) -> M.Query:
  Plan{+head, +projection, +tail, +params, bounds} = plan
  M.Query{name, statement(head, projection, tail, params, True{}),
    statement(head, projection, tail, params, False{}), params, names(projection), bounds}

def order_nulls(ts: L.Tokens, +direction: String) -> M.Checked(String):
  match ts:
    case Nil{}:
      place = Bool.pick(String, String.eq(direction, "asc"), "last", "first")
      Done{direction ++ " nulls " ++ place}
    case ["nulls", +place]:
      do M.Checked<String>:
        S.require(String.eq(place, "first") || String.eq(place, "last"), "expected NULLS FIRST or NULLS LAST")
        return direction ++ " nulls " ++ place
    case _: Fail{"expected [ASC | DESC] [NULLS FIRST | LAST] in ORDER BY"}

def order_direction(ts: L.Tokens) -> M.Checked(String):
  match ts:
    case "asc" <> t: order_nulls(t, "asc")
    case "desc" <> t: order_nulls(t, "desc")
    case _: order_nulls(ts, "asc")

def order_source(alias: String, +name: String, fs: M.Fields) -> M.Checked(String):
  match alias:
    case SNil{}:
      do M.Checked<String>:
        f : M.Field <- S.lookup(fs, name)
        return name
    case _: Done{alias}

# ORDER BY names prefer output aliases. Qualify the original column so SQLite
# orders its stored value even when a projected integer is returned as text.
def order_terms(xs: L.Groups, +table: String, +fs: M.Fields, +aliases: Aliases) -> M.Checked(L.Tokens):
  match xs:
    case Nil{}: Done{Nil{}}
    case (+name <> modifiers) <> t:
      alias = Pair.snd(Aliases, String, Map.get(String, "", aliases, name))
      do M.Checked<L.Tokens>:
        source : String <- order_source(alias, name, fs)
        direction : String <- order_direction(modifiers)
        rest : L.Tokens <- order_terms(t, table, fs, aliases)
        return (sql_name(table) ++ "." ++ sql_name(source) ++ " " ++ direction) <> rest
    case _: Fail{"empty ORDER BY term"}

def ordering(ts: L.Tokens, found: Bool, table: String, fs: M.Fields, aliases: Aliases) -> M.Checked(L.Tokens):
  match ts found:
    case _ False{}: Done{Nil{}}
    case "by" <> terms True{}:
      do M.Checked<L.Tokens>:
        items : L.Tokens <- order_terms(L.chunks(terms, ","), table, fs, aliases)
        return ["order", "by", String.join(items, ", ")]
    case _ _: Fail{"expected ORDER BY"}

def page_value(ts: L.Tokens) -> M.Checked(String):
  match ts:
    case SCon{Chr{58}, +name} <> Nil{}:
      do M.Checked<String>:
        S.require(L.identifier(name), "invalid pagination parameter: " ++ name)
        return ":" ++ name
    case "+" <> +n <> Nil{}:
      do M.Checked<String>:
        S.require(B.integer_literal(n, False{}), "expected nonnegative integer in LIMIT or OFFSET")
        return n
    case +n <> Nil{}:
      do M.Checked<String>:
        S.require(B.integer_literal(n, False{}), "expected nonnegative integer in LIMIT or OFFSET")
        return n
    case _: Fail{"expected nonnegative integer in LIMIT or OFFSET"}

def page_bounds(split: L.Split) -> M.Checked(L.Tokens):
  match split:
    case L.Split{count, _, False{}}:
      do M.Checked<L.Tokens>:
        n : String <- page_value(count)
        return ["limit", n]
    case L.Split{count, offset, True{}}:
      do M.Checked<L.Tokens>:
        n : String <- page_value(count)
        m : String <- page_value(offset)
        return ["limit", n, "offset", m]

def pagination(ts: L.Tokens, found: Bool) -> M.Checked(L.Tokens):
  match found:
    case False{}: Done{Nil{}}
    case True{}: page_bounds(L.split_at(ts, "offset", Nil{}))

type Pagination is Data:
  Pagination{params: M.Fields, bounds: L.Tokens}

def page_bindings(ts: L.Tokens, params: M.Fields, bounds: L.Tokens) -> M.Checked(Pagination):
  match ts:
    case Nil{}: Done{Pagination{params, List.reverse(&2, String, bounds)}}
    case SCon{Chr{58}, +name} <> rest:
      do M.Checked<Pagination>:
        next : M.Fields <- B.parameter(params, name, M.SqlInt{}, False{})
        page_bindings(rest, next, name <> bounds)
    case _ <> rest: page_bindings(rest, params, bounds)

def source_fields(cols: Projection) -> M.Fields:
  match cols:
    case Nil{}: Nil{}
    case Projected{source, M.Field{_, kind, null}} <> rest:
      M.Field{source, kind, null} <> source_fields(rest)

def select_plan(cols: Projection, table: String, tail: L.Tokens, bound: Pagination, distinct: Bool) -> Plan:
  Pagination{params, bounds} = bound
  head = Bool.pick(L.Tokens, distinct, ["select", "distinct"], ["select"])
  Plan{head, cols, "from" <> table <> tail, params, bounds}

def select_order(split: L.Split, +page: L.Tokens, columns: Columns, +table: String, +fs: M.Fields, +distinct: Bool) -> M.Checked(Plan):
  L.Split{+conditions, sort, has_sort} = split
  Columns{+cols, aliases} = columns
  # PostgreSQL requires DISTINCT ordering to name a projected expression.
  order_fields = Bool.pick(M.Fields, distinct, source_fields(cols), fs)
  do M.Checked<Plan>:
    filters : M.Fields <- B.where_tail(conditions, fs, Nil{})
    bound : Pagination <- page_bindings(page, filters, Nil{})
    ordered : L.Tokens <- ordering(sort, has_sort, table, order_fields, aliases)
    tail : L.Tokens = List.append(&2, String, conditions, List.append(&2, String, ordered, page))
    return select_plan(cols, table, tail, bound, distinct)

def select_limit(split: L.Split, columns: Columns, table: String, fs: M.Fields, distinct: Bool) -> M.Checked(Plan):
  L.Split{filtered, values, found} = split
  do M.Checked<Plan>:
    page : L.Tokens <- pagination(values, found)
    select_order(L.split_at(filtered, "order", Nil{}), page, columns, table, fs, distinct)

def select_parts(split: L.Split, tables: M.Schema, distinct: Bool) -> M.Checked(Plan):
  match split:
    case L.Split{projections, +table <> rest, True{}}:
      do M.Checked<Plan>:
        +fs : M.Fields <- S.find_table(tables, table)
        cols : Columns <- project(projections, fs)
        select_limit(L.split_at(rest, "limit", Nil{}), cols, table, fs, distinct)
    case _: Fail{"expected SELECT columns FROM table"}

def returning_plan(core: L.Tokens, columns: Columns, params: M.Fields) -> Plan:
  Columns{cols, _} = columns
  Plan{List.append(&2, String, core, ["returning"]), cols, Nil{}, params, Nil{}}

def wrote(+core: L.Tokens, returning: L.Tokens, found: Bool, fs: M.Fields, params: M.Fields) -> M.Checked(Plan):
  match found:
    case False{}: Done{Plan{core, Nil{}, Nil{}, params, Nil{}}}
    case True{}:
      do M.Checked<Plan>:
        cols : Columns <- project(returning, fs)
        return returning_plan(core, cols, params)

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

def required_present(fs: M.Fields, +seen: M.Fields, +defaults: L.Tokens) -> M.Checked(Unit):
  match fs:
    case Nil{}: Done{Unit{}}
    case M.Field{+name, _, null} <> t:
      do M.Checked<Unit>:
        S.require(null || S.has_field(seen, name) || List.contains(~String, ~String.eq, defaults, name), "missing required INSERT column: " ++ name)
        required_present(t, seen, defaults)

# Resolve and validate the column list once, even for a large VALUES batch.
def insert_columns(cols: L.Groups, +fs: M.Fields, +seen: M.Fields) -> M.Checked(M.Fields):
  match cols:
    case Nil{}: Done{List.reverse(&2, M.Field, seen)}
    case [+name] <> rest:
      do M.Checked<M.Fields>:
        S.require(Bool.not(S.has_field(seen, name)), "duplicate INSERT column: " ++ name)
        f : M.Field <- S.lookup(fs, name)
        insert_columns(rest, fs, f <> seen)
    case _: Fail{"expected named INSERT columns"}

def inserted(cols: M.Fields, vals: L.Groups, params: M.Fields) -> M.Checked(M.Fields):
  match cols vals:
    case Nil{} Nil{}: Done{params}
    case f <> ct value <> vt:
      do M.Checked<M.Fields>:
        next : M.Fields <- B.value(value, f, params)
        inserted(ct, vt, next)
    case _ _: Fail{"INSERT needs one value for each named column"}

def insert_values(reversed: L.Tokens, cols: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match reversed:
    case ")" <> body: inserted(cols, L.chunks(List.reverse(&2, String, body), ","), params)
    case _: Fail{"expected closing ) in VALUES"}

def insert_rows(rows: L.Groups, +cols: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match rows:
    case Nil{}: Done{params}
    case ("(" <> body) <> rest:
      do M.Checked<M.Fields>:
        next : M.Fields <- insert_values(List.reverse(&2, String, body), cols, params)
        insert_rows(rest, cols, next)
    case _: Fail{"expected parenthesized VALUES row"}

def insert_parts(split: L.Split, +fs: M.Fields, defaults: L.Tokens) -> M.Checked(M.Fields):
  match split:
    case L.Split{cols, "values" <> rest, True{}}:
      do M.Checked<M.Fields>:
        +fields : M.Fields <- insert_columns(L.chunks(cols, ","), fs, Nil{})
        required_present(fs, fields, defaults)
        rows : L.Groups <- L.balanced_chunks(rest, ",")
        insert_rows(rows, fields, Nil{})
    case _: Fail{"expected INSERT INTO table (columns) VALUES (values)"}

def insert_tail(ts: L.Tokens, +fs: M.Fields, defaults: L.Tokens) -> M.Checked(M.Fields):
  match ts:
    case "(" <> rest: insert_parts(L.split_at(rest, ")", Nil{}), fs, defaults)
    case [first, second]:
      do M.Checked<M.Fields>:
        S.require(String.eq(first, "default") && String.eq(second, "values"), "expected DEFAULT VALUES")
        required_present(fs, Nil{}, defaults)
        return Nil{}
    case _: Fail{"expected INSERT column list or DEFAULT VALUES"}

def write_insert(core: L.Tokens, rest: L.Tokens, returning: L.Tokens, found: Bool, +tables: M.Schema) -> M.Checked(Plan):
  match rest:
    case into <> +table <> tail:
      do M.Checked<Plan>:
        S.require(String.eq(into, "into"), "expected INSERT INTO")
        +fs : M.Fields <- S.find_table(tables, table)
        defaults : L.Tokens <- S.default_columns(tables, table)
        params : M.Fields <- insert_tail(tail, fs, defaults)
        wrote(core, returning, found, fs, params)
    case _: Fail{"expected INSERT INTO table"}

def write_update(core: L.Tokens, rest: L.Tokens, returning: L.Tokens, found: Bool, tables: M.Schema) -> M.Checked(Plan):
  match rest:
    case table <> keyword <> tail:
      do M.Checked<Plan>:
        S.require(String.eq(keyword, "set"), "expected SET after UPDATE table")
        +fs : M.Fields <- S.find_table(tables, table)
        params : M.Fields <- update_parts(L.split_at(tail, "where", Nil{}), fs)
        wrote(core, returning, found, fs, params)
    case _: Fail{"expected UPDATE table SET"}

def write_delete(core: L.Tokens, rest: L.Tokens, returning: L.Tokens, found: Bool, tables: M.Schema) -> M.Checked(Plan):
  match rest:
    case keyword <> table <> tail:
      do M.Checked<Plan>:
        S.require(String.eq(keyword, "from"), "expected DELETE FROM")
        +fs : M.Fields <- S.find_table(tables, table)
        params : M.Fields <- B.where_tail(tail, fs, Nil{})
        wrote(core, returning, found, fs, params)
    case _: Fail{"expected DELETE FROM table"}

def write_kind(kind: Nat, core: L.Tokens, rest: L.Tokens, returning: L.Tokens, found: Bool, tables: M.Schema) -> M.Checked(Plan):
  match kind:
    case 1n: write_insert(core, rest, returning, found, tables)
    case 2n: write_update(core, rest, returning, found, tables)
    case 3n: write_delete(core, rest, returning, found, tables)
    case _: Fail{"expected SELECT, INSERT, UPDATE, or DELETE"}

def write_parts(+core: L.Tokens, returning: L.Tokens, found: Bool, tables: M.Schema) -> M.Checked(Plan):
  match core:
    case +command <> +rest:
      kind = Bool.pick(Nat, String.eq(command, "insert"), 1n,
        Bool.pick(Nat, String.eq(command, "update"), 2n,
          Bool.pick(Nat, String.eq(command, "delete"), 3n, 0n)))
      write_kind(kind, core, rest, returning, found, tables)
    case Nil{}: Fail{"expected SELECT, INSERT, UPDATE, or DELETE"}

def writes(split: L.Split, tables: M.Schema) -> M.Checked(Plan):
  L.Split{core, cols, found} = split
  write_parts(core, cols, found, tables)

def select_modifier(kind: Nat, projections: L.Tokens, rest: L.Tokens, tables: M.Schema) -> M.Checked(Plan):
  match kind:
    case 1n: select_parts(L.split_at(rest, "from", Nil{}), tables, True{})
    case 2n: select_parts(L.split_at(rest, "from", Nil{}), tables, False{})
    case _: select_parts(L.split_at(projections, "from", Nil{}), tables, False{})

def select_tokens(+ts: L.Tokens, tables: M.Schema) -> M.Checked(Plan):
  match ts:
    case +first <> rest:
      kind = Bool.pick(Nat, String.eq(first, "distinct"), 1n,
        Bool.pick(Nat, String.eq(first, "all"), 2n, 0n))
      select_modifier(kind, ts, rest, tables)
    case Nil{}: Fail{"expected SELECT columns FROM table"}

def plan_kind(select: Bool, ts: L.Tokens, rest: L.Tokens, tables: M.Schema) -> M.Checked(Plan):
  match select:
    case True{}: select_tokens(rest, tables)
    case False{}: writes(L.split_at(ts, "returning", Nil{}), tables)

def plan(+ts: L.Tokens, tables: M.Schema) -> M.Checked(Plan):
  match ts:
    case command <> rest: plan_kind(String.eq(command, "select"), ts, rest, tables)
    case Nil{}: Fail{"expected SELECT, INSERT, UPDATE, or DELETE"}

def single(groups: L.Groups) -> M.Checked(L.Tokens):
  match groups:
    case ts <> Nil{}: Done{ts}
    case ts <> Nil{} <> Nil{}: Done{ts}
    case _: Fail{"expected exactly one SQL query"}

def finalize_plan(plan: Plan) -> M.Checked(Plan):
  Plan{head, projection, tail, uses, bounds} = plan
  do M.Checked<Plan>:
    params : M.Fields <- B.finalize_parameters(uses)
    return Plan{head, projection, tail, params, bounds}

def analyze(tables: M.Schema, +name: String, sql: String) -> M.Checked(Plan):
  do M.Checked<Plan>:
    S.require(L.identifier(name), "invalid query name: " ++ name)
    tokens : L.Tokens <- L.tokenize(sql)
    ts : L.Tokens <- single(L.chunks(tokens, ";"))
    raw : Plan <- plan(ts, tables)
    finalize_plan(raw)

def query(tables: M.Schema, +name: String, sql: String) -> M.Checked(M.Query):
  do M.Checked<M.Query>:
    compiled : Plan <- analyze(tables, name, sql)
    return checked(name, compiled)
