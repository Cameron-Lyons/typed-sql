import Base
import ./model.bend as M
import ./lexer.bend as L

def require(ok: Bool, msg: String) -> M.Checked(Unit):
  match ok:
    case True{}: Done{Unit{}}
    case False{}: Fail{msg}

# A conservative set of SQL words for portable unquoted identifiers.
def reserved(+s: String) -> Bool:
  List.contains(~String, ~String.eq,
    ["abort","action","add","after","all","alter","always","analyse","analyze","and","any","array","as","asc",
     "asymmetric","attach","authorization","autoincrement","before","begin","between","bigint","binary",
     "bool","boolean","both","by","cascade","case","cast","check","collate","collation","column",
     "commit","concurrently","conflict","constraint","create","cross","current","current_catalog",
     "current_date","current_role","current_schema","current_time","current_timestamp","current_user",
     "database","default","deferrable","deferred","delete","desc","detach","distinct","do","drop",
     "each","else","end","escape","except","exclude","exclusive","exists","explain","fail","false",
     "fetch","filter","first","following","for","foreign","freeze","from","full","generated","glob",
     "grant","group","groups","having","if","ignore","ilike","immediate","in","index","indexed",
     "initially","inner","insert","instead","int","integer","intersect","into","is","isnull","join",
     "key","last","lateral","leading","left","like","limit","localtime","localtimestamp","match",
     "materialized","natural","no","not","nothing","notnull","null","nulls","of","offset","on",
     "only","or","order","others","outer","over","overlaps","partition","placing","plan","pragma",
     "preceding","primary","query","raise","range","recursive","references","regexp","reindex",
     "release","rename","replace","restrict","returning","right","rollback","row","rows","savepoint",
     "select","session_user","set","similar","some","symmetric","system_user","table","table_sample","tablesample",
     "temp","temporary","text","then","ties","to","trailing","transaction","trigger","true",
     "unbounded","union","unique","update","user","using","vacuum","values","variadic","verbose",
     "view","virtual","when","where","window","with","without"], s)

def valid_name(+name: String) -> M.Checked(Unit):
  require(L.identifier(name) && Bool.not(reserved(name)), "expected an unquoted SQL identifier, got " ++ name)

def has_field(fs: M.Fields, +name: String) -> Bool:
  match fs:
    case Nil{}: False{}
    case M.Field{n, _, _} <> t: String.eq(name, n) || has_field(t, name)

def lookup(fs: M.Fields, +name: String) -> M.Checked(M.Field):
  match fs:
    case Nil{}: Fail{"unknown column: " ++ name}
    case M.Field{+n, +kind, +nullable} <> t:
      next = Bool.pick(Unit -> M.Checked(M.Field), String.eq(n, name),
        _ => Done{M.Field{n, kind, nullable}}, _ => lookup(t, name))
      next(Unit{})

def has_table(tables: M.Schema, +name: String) -> Bool:
  match tables:
    case Nil{}: False{}
    case M.Table{n, _} <> t: String.eq(name, n) || has_table(t, name)

def find_table(tables: M.Schema, +name: String) -> M.Checked(M.Fields):
  match tables:
    case Nil{}: Fail{"unknown table: " ++ name}
    case M.Table{n, fs} <> t:
      next = Bool.pick(Unit -> M.Checked(M.Fields), String.eq(n, name),
        _ => Done{fs}, _ => find_table(t, name))
      next(Unit{})

def kind(s: String) -> M.Checked(M.SqlType):
  match s:
    case "text": Done{M.SqlText{}}
    case "integer": Done{M.SqlInt{}}
    case "int": Done{M.SqlInt{}}
    case "bigint": Done{M.SqlInt{}}
    case "bool": Done{M.SqlBool{}}
    case "boolean": Done{M.SqlBool{}}
    case _: Fail{"unsupported SQL type: " ++ s}

type Constraints is Data:
  Constraints{primary_key: Bool, non_null: Bool}

def constraints(ts: L.Tokens, primary: Bool, nn: Bool, explicit_null: Bool, unique: Bool) -> M.Checked(Constraints):
  match ts:
    case Nil{}: Done{Constraints{primary, nn}}
    case "primary" <> "key" <> t:
      do M.Checked<Constraints>:
        require(Bool.not(primary || explicit_null), "conflicting PRIMARY KEY")
        constraints(t, True{}, nn, False{}, unique)
    case "not" <> "null" <> t:
      do M.Checked<Constraints>:
        require(Bool.not(nn || explicit_null), "conflicting NOT NULL")
        constraints(t, primary, True{}, False{}, unique)
    case "null" <> t:
      do M.Checked<Constraints>:
        require(Bool.not(primary || nn || explicit_null), "conflicting NULL")
        constraints(t, False{}, False{}, True{}, unique)
    case "unique" <> t:
      do M.Checked<Constraints>:
        require(Bool.not(unique), "duplicate UNIQUE")
        constraints(t, primary, nn, explicit_null, True{})
    case h <> _: Fail{"unsupported column constraint: " ++ h}

def column_done(name: String, kind: M.SqlType, +exact_integer: Bool, c: Constraints, fs: M.Fields, +has_pk: Bool) -> M.Checked(M.Fields):
  Constraints{+pk, +nn} = c
  do M.Checked<M.Fields>:
    require(Bool.not(pk && has_pk), "multiple PRIMARY KEY columns")
    require(Bool.not(pk) || nn || exact_integer, "use explicit NOT NULL for this PRIMARY KEY on SQLite")
    return M.Field{name, kind, Bool.not(pk || nn)} <> fs

def has_pk_token(ts: L.Tokens) -> Bool:
  List.contains(~String, ~String.eq, ts, "primary")

def columns(groups: L.Groups, +fs: M.Fields, +has_pk: Bool) -> M.Checked(M.Fields):
  match groups:
    case Nil{}: Done{List.reverse(&2, M.Field, fs)}
    case (+name <> +ty <> +rest) <> t:
      do M.Checked<M.Fields>:
        valid_name(name)
        require(Bool.not(List.contains(~String, ~String.eq, ["ctid", "xmin", "xmax", "cmin", "cmax", "tableoid"], name)), "PostgreSQL system column: " ++ name)
        require(Bool.not(has_field(fs, name)), "duplicate column: " ++ name)
        k : M.SqlType <- kind(ty)
        options : Constraints <- constraints(rest, False{}, False{}, False{}, False{})
        next : M.Fields <- column_done(name, k, String.eq(ty, "integer"), options, fs, has_pk)
        columns(t, next, has_pk || has_pk_token(rest))
    case _ <> _: Fail{"expected a column name and type"}

def table_body(+name: String, reversed: L.Tokens, +tables: M.Schema) -> M.Checked(M.Schema):
  match reversed:
    case ")" <> body:
      do M.Checked<M.Schema>:
        valid_name(name)
        require(Bool.not(String.starts_with(name, "sqlite_")), "SQLite internal table name: " ++ name)
        require(Bool.not(has_table(tables, name)), "duplicate table: " ++ name)
        fields : M.Fields <- columns(L.chunks(List.reverse(&2, String, body), ","), Nil{}, False{})
        return M.Table{name, fields} <> tables
    case _: Fail{"expected closing ) in CREATE TABLE"}

def create(ts: L.Tokens, tables: M.Schema) -> M.Checked(M.Schema):
  match ts:
    case "create" <> "table" <> name <> "(" <> rest: table_body(name, List.reverse(&2, String, rest), tables)
    case "create" <> "table" <> "if" <> "not" <> "exists" <> name <> "(" <> rest: table_body(name, List.reverse(&2, String, rest), tables)
    case _: Fail{"expected CREATE TABLE name (columns)"}

def tables(stmts: L.Groups, acc: M.Schema) -> M.Checked(M.Schema):
  match stmts:
    case Nil{}: Done{List.reverse(&2, M.Table, acc)}
    case Nil{} <> t: tables(t, acc)
    case ts <> t:
      do M.Checked<M.Schema>:
        next : M.Schema <- create(ts, acc)
        tables(t, next)

def parse(sql: String) -> M.Checked(M.Schema):
  do M.Checked<M.Schema>:
    ts : L.Tokens <- L.tokenize(sql)
    tables(L.chunks(ts, ";"), Nil{})
