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
    case M.Table{n, _, _, _} <> t: String.eq(name, n) || has_table(t, name)

def find_table(tables: M.Schema, +name: String) -> M.Checked(M.Fields):
  match tables:
    case Nil{}: Fail{"unknown table: " ++ name}
    case M.Table{n, fs, _, _} <> t:
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


def table(tables: M.Schema, +name: String) -> M.Checked(M.Table):
  match tables:
    case Nil{}: Fail{"unknown table: " ++ name}
    case +h <> t:
      M.Table{n, _, _, _} = h
      next = Bool.pick(Unit -> M.Checked(M.Table), String.eq(n, name),
        _ => Done{h}, _ => table(t, name))
      next(Unit{})

def defaults_of(t: M.Table) -> L.Tokens:
  M.Table{_, _, defaults, _} = t
  defaults

def default_columns(tables: M.Schema, name: String) -> M.Checked(L.Tokens):
  do M.Checked<L.Tokens>:
    result : M.Table <- table(tables, name)
    return defaults_of(result)

def same_kind(a: M.SqlType, b: M.SqlType) -> Bool:
  match a b:
    case M.SqlInt{} M.SqlInt{}: True{}
    case M.SqlText{} M.SqlText{}: True{}
    case M.SqlBool{} M.SqlBool{}: True{}
    case _ _: False{}

def contains(xs: L.Tokens, name: String) -> Bool:
  List.contains(~String, ~String.eq, xs, name)

def add_name(+name: String, +seen: L.Tokens) -> M.Checked(L.Tokens):
  do M.Checked<L.Tokens>:
    valid_name(name)
    require(Bool.not(contains(seen, name)), "duplicate constraint name: " ++ name)
    return name <> seen

def add_names(xs: L.Tokens, seen: L.Tokens) -> M.Checked(L.Tokens):
  match xs:
    case Nil{}: Done{seen}
    case name <> rest:
      do M.Checked<L.Tokens>:
        next : L.Tokens <- add_name(name, seen)
        add_names(rest, next)

def names_parts(xs: L.Groups, +seen: L.Tokens) -> M.Checked(L.Tokens):
  match xs:
    case Nil{}: Done{List.reverse(&2, String, seen)}
    case [+name] <> rest:
      do M.Checked<L.Tokens>:
        valid_name(name)
        require(Bool.not(contains(seen, name)), "duplicate key column: " ++ name)
        names_parts(rest, name <> seen)
    case _: Fail{"expected a nonempty list of column names"}

def column_names(ts: L.Tokens) -> M.Checked(L.Tokens):
  names_parts(L.chunks(ts, ","), Nil{})

def parenthesized(reversed: L.Tokens) -> M.Checked(L.Tokens):
  match reversed:
    case ")" <> t: Done{List.reverse(&2, String, t)}
    case _: Fail{"expected closing parenthesis"}

type Foreign is Data:
  Foreign{local: L.Tokens, target: String, remote: L.Tokens}

def Foreigns() -> Data:
  List<&2, Foreign>

def action_tail(ts: L.Tokens) -> M.Checked(L.Tokens):
  match ts:
    case "cascade" <> t: Done{t}
    case "restrict" <> t: Done{t}
    case "no" <> "action" <> t: Done{t}
    case "set" <> "null" <> t: Done{t}
    case "set" <> "default" <> t: Done{t}
    case _: Fail{"expected a foreign key action"}

def reference_actions(fuel: Nat, ts: L.Tokens, +seen: L.Tokens) -> M.Checked(L.Tokens):
  match fuel ts:
    case 1n+n "on" <> +event <> rest:
      do M.Checked<L.Tokens>:
        require(String.eq(event, "delete") || String.eq(event, "update"), "expected ON DELETE or ON UPDATE")
        require(Bool.not(contains(seen, event)), "duplicate foreign key action")
        tail : L.Tokens <- action_tail(rest)
        reference_actions(n, tail, event <> seen)
    case _ "on" <> _: Fail{"incomplete foreign key action"}
    case _ _: Done{ts}

type ReferenceResult is Data:
  ReferenceResult{ref: Foreign, tail: L.Tokens}

def reference_parts(split: L.Split, local: L.Tokens, +target: String) -> M.Checked(ReferenceResult):
  match split:
    case L.Split{cols, +tail, True{}}:
      do M.Checked<ReferenceResult>:
        valid_name(target)
        remote : L.Tokens <- column_names(cols)
        rest : L.Tokens <- reference_actions(List.length(&2, String, tail), tail, Nil{})
        return ReferenceResult{Foreign{local, target, remote}, rest}
    case _: Fail{"expected closing parenthesis in REFERENCES"}

def reference(ts: L.Tokens, local: L.Tokens) -> M.Checked(ReferenceResult):
  match ts:
    case target <> "(" <> rest: reference_parts(L.split_at(rest, ")", Nil{}), local, target)
    case _: Fail{"expected REFERENCES table (columns)"}

type Options is Data:
  Options{primary: Bool, non_null: Bool, explicit_null: Bool, unique: Bool,
    default_value: Maybe<&2, L.Tokens>, refs: Foreigns, names: L.Tokens}

def with_default(value: L.Tokens, opts: Options) -> M.Checked(Options):
  match opts:
    case Options{pk, nn, nul, uq, None{}, refs, names}:
      Done{Options{pk, nn, nul, uq, Some{value}, refs, names}}
    case _: Fail{"duplicate DEFAULT"}

type OptionsResult is Data:
  OptionsResult{opts: Options, tail: L.Tokens}

def options_value(result: OptionsResult) -> Options:
  OptionsResult{opts, _} = result
  opts

def options_tail(result: OptionsResult) -> L.Tokens:
  OptionsResult{_, tail} = result
  tail

def with_reference(r: ReferenceResult, opts: Options) -> M.Checked(OptionsResult):
  ReferenceResult{ref, rest} = r
  Options{pk, nn, nul, uq, defval, +refs, names} = opts
  do M.Checked<OptionsResult>:
    require(List.is_empty(&2, Foreign, refs), "duplicate column REFERENCES")
    return OptionsResult{Options{pk, nn, nul, uq, defval, ref <> refs, names}, rest}

def default_atom(ts: L.Tokens) -> M.Checked(L.Split):
  match ts:
    case "+" <> value <> rest: Done{L.Split{["+", value], rest, True{}}}
    case "-" <> value <> rest: Done{L.Split{["-", value], rest, True{}}}
    case value <> rest: Done{L.Split{[value], rest, True{}}}
    case Nil{}: Fail{"expected DEFAULT literal"}

def default_close(parsed: L.Split) -> M.Checked(L.Split):
  match parsed:
    case L.Split{value, ")" <> rest, _}: Done{L.Split{value, rest, True{}}}
    case _: Fail{"expected closing ) after DEFAULT literal"}

def default_tokens(ts: L.Tokens) -> M.Checked(L.Split):
  match ts:
    case "(" <> rest:
      do M.Checked<L.Split>:
        parsed : L.Split <- default_atom(rest)
        default_close(parsed)
    case _: default_atom(ts)

def default_step(parsed: L.Split, opts: Options) -> M.Checked(OptionsResult):
  L.Split{value, rest, _} = parsed
  do M.Checked<OptionsResult>:
    next : Options <- with_default(value, opts)
    return OptionsResult{next, rest}

# Parse one constraint before iterating. Keeping token dispatch separate from
# the Options record avoids expanding a cross product of nested match patterns.
def expected_token(ts: L.Tokens, +expected: String) -> M.Checked(L.Tokens):
  match ts:
    case h <> rest:
      do M.Checked<L.Tokens>:
        require(String.eq(h, expected), "expected " ++ expected)
        return rest
    case Nil{}: Fail{"expected " ++ expected}

def named_option(ts: L.Tokens, opts: Options) -> M.Checked(OptionsResult):
  match ts:
    case name <> +next <> t:
      Options{pk, nn, nul, uq, defval, refs, names} = opts
      do M.Checked<OptionsResult>:
        require(contains(["primary", "unique", "not", "null", "references"], next), "expected a named column constraint")
        named : L.Tokens <- add_name(name, names)
        return OptionsResult{Options{pk, nn, nul, uq, defval, refs, named}, next <> t}
    case _: Fail{"expected a named column constraint"}

def constraint_kind(+word: String) -> Nat:
  Bool.pick(Nat, String.eq(word, "primary"), 0n, Bool.pick(Nat, String.eq(word, "not"), 1n, Bool.pick(Nat, String.eq(word, "null"), 2n, Bool.pick(Nat, String.eq(word, "unique"), 3n, Bool.pick(Nat, String.eq(word, "default"), 4n, Bool.pick(Nat, String.eq(word, "references"), 5n, Bool.pick(Nat, String.eq(word, "constraint"), 6n, 7n)))))))

def constraint_tag(tag: Nat, word: String, ts: L.Tokens, column: String, opts: Options) -> M.Checked(OptionsResult):
  match tag:
    case 0n:
      Options{+pk, nn, +nul, uq, defval, refs, names} = opts
      do M.Checked<OptionsResult>:
        t : L.Tokens <- expected_token(ts, "key")
        require(Bool.not(pk || nul), "conflicting PRIMARY KEY")
        return OptionsResult{Options{True{}, nn, nul, uq, defval, refs, names}, t}
    case 1n:
      Options{pk, +nn, +nul, uq, defval, refs, names} = opts
      do M.Checked<OptionsResult>:
        t : L.Tokens <- expected_token(ts, "null")
        require(Bool.not(nn || nul), "conflicting NOT NULL")
        return OptionsResult{Options{pk, True{}, nul, uq, defval, refs, names}, t}
    case 2n:
      Options{+pk, +nn, +nul, uq, defval, refs, names} = opts
      do M.Checked<OptionsResult>:
        require(Bool.not(pk || nn || nul), "conflicting NULL")
        return OptionsResult{Options{pk, nn, True{}, uq, defval, refs, names}, ts}
    case 3n:
      Options{pk, nn, nul, +uq, defval, refs, names} = opts
      do M.Checked<OptionsResult>:
        require(Bool.not(uq), "duplicate UNIQUE")
        return OptionsResult{Options{pk, nn, nul, True{}, defval, refs, names}, ts}
    case 4n:
      do M.Checked<OptionsResult>:
        parsed : L.Split <- default_tokens(ts)
        default_step(parsed, opts)
    case 5n:
      do M.Checked<OptionsResult>:
        parsed : ReferenceResult <- reference(ts, [column])
        with_reference(parsed, opts)
    case 6n: named_option(ts, opts)
    case _: Fail{"unsupported column constraint: " ++ word}

def constraint_keyword(+word: String, ts: L.Tokens, column: String, opts: Options) -> M.Checked(OptionsResult):
  constraint_tag(constraint_kind(word), word, ts, column, opts)

def constraint_step(ts: L.Tokens, column: String, opts: Options) -> M.Checked(OptionsResult):
  match ts:
    case word <> rest: constraint_keyword(word, rest, column, opts)
    case Nil{}: Fail{"expected column constraint"}

# A sub-parser returns the unconsumed suffix; fuel bounds the iteration.
def constraints(fuel: Nat, ts: L.Tokens, +column: String, opts: Options) -> M.Checked(Options):
  match fuel ts:
    case _ Nil{}: Done{opts}
    case 0n _: Fail{"incomplete column constraint"}
    case 1n+n h <> t:
      do M.Checked<Options>:
        +pair : OptionsResult <- constraint_step(h <> t, column, opts)
        constraints(n, options_tail(pair), column, options_value(pair))

def default_literal(value: L.Tokens, kind: M.SqlType, nullable: Bool) -> Bool:
  match value kind:
    case ["null"] _: nullable
    case [s] M.SqlInt{}: L.integer_literal(s, False{})
    case ["+", s] M.SqlInt{}: L.integer_literal(s, False{})
    case ["-", s] M.SqlInt{}: L.integer_literal(s, True{})
    case [s] M.SqlText{}: String.starts_with(s, "'")
    case [+s] M.SqlBool{}: String.eq(s, "true") || String.eq(s, "false")
    case _ _: False{}

# PostgreSQL narrows INT and INTEGER defaults at CREATE TABLE time.
def integer32_literal(+raw: String, +negative: Bool) -> Bool:
  +s = L.significant(raw)
  +len = String.length(s)
  limit = Bool.pick(String, negative, "2147483648", "2147483647")
  L.integer_literal(raw, negative) && (Nat.is_lt(len, 10n) || (Nat.is_eq(len, 10n) && String.is_le(s, limit)))

def integer32_default(value: L.Tokens) -> Bool:
  match value:
    case ["null"]: True{}
    case [s]: integer32_literal(s, False{})
    case ["+", s]: integer32_literal(s, False{})
    case ["-", s]: integer32_literal(s, True{})
    case _: False{}

def default_ok(value: Maybe<&2, L.Tokens>, kind: M.SqlType, nullable: Bool, +ty: String) -> M.Checked(Bool):
  match value:
    case None{}: Done{False{}}
    case Some{+literal}:
      do M.Checked<Bool>:
        require(default_literal(literal, kind, nullable), "DEFAULT must be a compatible literal (NULL requires a nullable column)")
        require(Bool.not(String.eq(ty, "int") || String.eq(ty, "integer")) || integer32_default(literal), "INT and INTEGER defaults must fit signed 32-bit; use BIGINT")
        return True{}

def null_default(value: Maybe<&2, L.Tokens>) -> Bool:
  match value:
    case Some{["null"]}: True{}
    case _: False{}

type Build is Data:
  Build{fields: M.Fields, integers: L.Tokens, explicit_nulls: L.Tokens,
    defaults: L.Tokens, keys: L.Groups, primary: L.Tokens, refs: Foreigns, names: L.Tokens,
    null_defaults: L.Tokens}

def add_column(+name: String, +ty: String, +kind: M.SqlType, opts: Options, build: Build) -> M.Checked(Build):
  Options{+pk, +nn, nul, uq, +value, refs, names} = opts
  Build{+fs, +integers, +nulls, +defaults, +keys, +primary, old_refs, old_names, +null_defaults} = build
  do M.Checked<Build>:
    valid_name(name)
    require(Bool.not(contains(["ctid", "xmin", "xmax", "cmin", "cmax", "tableoid"], name)), "PostgreSQL system column: " ++ name)
    require(Bool.not(has_field(fs, name)), "duplicate column: " ++ name)
    require(Bool.not(pk) || List.is_empty(&2, String, primary), "multiple PRIMARY KEY constraints")
    has_default : Bool <- default_ok(value, kind, Bool.not(pk || nn), ty)
    constraint_names : L.Tokens <- add_names(names, old_names)
    return Build{M.Field{name, kind, Bool.not(nn)} <> fs,
      Bool.pick(L.Tokens, String.eq(ty, "integer"), name <> integers, integers),
      Bool.pick(L.Tokens, nul, name <> nulls, nulls),
      Bool.pick(L.Tokens, has_default, name <> defaults, defaults),
      Bool.pick(L.Groups, uq, [name] <> keys, keys),
      Bool.pick(L.Tokens, pk, [name], primary), List.append(&2, Foreign, refs, old_refs), constraint_names,
      Bool.pick(L.Tokens, null_default(value), name <> null_defaults, null_defaults)}

def with_key(+cols: L.Tokens, +pk: Bool, build: Build) -> M.Checked(Build):
  Build{fs, integers, nulls, defaults, +keys, +primary, refs, names, null_defaults} = build
  do M.Checked<Build>:
    require(Bool.not(pk) || List.is_empty(&2, String, primary), "multiple PRIMARY KEY constraints")
    return Build{fs, integers, nulls, defaults, Bool.pick(L.Groups, pk, keys, cols <> keys),
      Bool.pick(L.Tokens, pk, cols, primary), refs, names, null_defaults}

def add_foreign(parsed: ReferenceResult, build: Build) -> M.Checked(Build):
  ReferenceResult{ref, rest} = parsed
  Build{fs, integers, nulls, defaults, keys, primary, refs, names, null_defaults} = build
  do M.Checked<Build>:
    require(List.is_empty(&2, String, rest), "unsupported FOREIGN KEY clause")
    return Build{fs, integers, nulls, defaults, keys, primary, ref <> refs, names, null_defaults}

def table_foreign(split: L.Split, build: Build) -> M.Checked(Build):
  match split:
    case L.Split{local, "references" <> tail, True{}}:
      do M.Checked<Build>:
        cols : L.Tokens <- column_names(local)
        parsed : ReferenceResult <- reference(tail, cols)
        add_foreign(parsed, build)
    case _: Fail{"expected FOREIGN KEY (columns) REFERENCES table (columns)"}

def table_constraint(ts: L.Tokens, build: Build) -> M.Checked(Build):
  match ts:
    case "primary" <> "key" <> "(" <> rest:
      do M.Checked<Build>:
        body : L.Tokens <- parenthesized(List.reverse(&2, String, rest))
        cols : L.Tokens <- column_names(body)
        with_key(cols, True{}, build)
    case "unique" <> "(" <> rest:
      do M.Checked<Build>:
        body : L.Tokens <- parenthesized(List.reverse(&2, String, rest))
        cols : L.Tokens <- column_names(body)
        with_key(cols, False{}, build)
    case "foreign" <> "key" <> "(" <> rest:
      table_foreign(L.split_at(rest, ")", Nil{}), build)
    case _: Fail{"expected PRIMARY KEY, UNIQUE, or FOREIGN KEY table constraint"}

def named_constraint(name: String, ts: L.Tokens, build: Build) -> M.Checked(Build):
  Build{fs, integers, nulls, defaults, keys, primary, refs, names, null_defaults} = build
  do M.Checked<Build>:
    next : L.Tokens <- add_name(name, names)
    table_constraint(ts, Build{fs, integers, nulls, defaults, keys, primary, refs, next, null_defaults})

type ColumnResult is Data:
  ColumnResult{build: Build, closed: Bool}

def column_build(result: ColumnResult) -> Build:
  ColumnResult{build, _} = result
  build

def column_closed(result: ColumnResult) -> Bool:
  ColumnResult{_, closed} = result
  closed

def named_table(ts: L.Tokens, build: Build) -> M.Checked(Build):
  match ts:
    case name <> rest: named_constraint(name, rest, build)
    case Nil{}: Fail{"expected named table constraint"}

def column_definition(ts: L.Tokens, +name: String, build: Build, closed: Bool) -> M.Checked(Build):
  match ts:
    case +ty <> +rest:
      do M.Checked<Build>:
        require(Bool.not(closed), "put column definitions before table constraints")
        k : M.SqlType <- kind(ty)
        opts : Options <- constraints(List.length(&2, String, rest), rest, name, Options{False{}, False{}, False{}, False{}, None{}, Nil{}, Nil{}})
        add_column(name, ty, k, opts, build)
    case Nil{}: Fail{"expected column type"}

def column_tag(tag: Nat, name: String, rest: L.Tokens, build: Build, closed: Bool) -> M.Checked(ColumnResult):
  match tag:
    case 0n:
      do M.Checked<ColumnResult>:
        next : Build <- named_table(rest, build)
        return ColumnResult{next, True{}}
    case 1n:
      do M.Checked<ColumnResult>:
        next : Build <- table_constraint(name <> rest, build)
        return ColumnResult{next, True{}}
    case _:
      do M.Checked<ColumnResult>:
        next : Build <- column_definition(rest, name, build, closed)
        return ColumnResult{next, False{}}

def column_item(ts: L.Tokens, build: Build, closed: Bool) -> M.Checked(ColumnResult):
  match ts:
    case +name <> rest:
      tag = Bool.pick(Nat, String.eq(name, "constraint"), 0n,
        Bool.pick(Nat, contains(["primary", "unique", "foreign"], name), 1n, 2n))
      column_tag(tag, name, rest, build, closed)
    case Nil{}: Fail{"expected column or table constraint"}

def columns(groups: L.Groups, build: Build, closed: Bool) -> M.Checked(Build):
  match groups:
    case Nil{}: Done{build}
    case ts <> t:
      do M.Checked<Build>:
        +next : ColumnResult <- column_item(ts, build, closed)
        columns(t, column_build(next), column_closed(next))

def known_columns(xs: L.Tokens, +fields: M.Fields) -> M.Checked(Unit):
  match xs:
    case Nil{}: Done{Unit{}}
    case name <> rest:
      do M.Checked<Unit>:
        field : M.Field <- lookup(fields, name)
        known_columns(rest, fields)

def known_keys(xs: L.Groups, +fields: M.Fields) -> M.Checked(Unit):
  match xs:
    case Nil{}: Done{Unit{}}
    case cols <> rest:
      do M.Checked<Unit>:
        known_columns(cols, fields)
        known_keys(rest, fields)

def primary_field(field: M.Field, single_integer: Bool, explicit_null: Bool) -> M.Checked(Unit):
  M.Field{name, _, nullable} = field
  require(Bool.not(explicit_null) && (Bool.not(nullable) || single_integer),
    "use explicit NOT NULL for PRIMARY KEY column " ++ name ++ " on SQLite")

def primary_columns(xs: L.Tokens, +fields: M.Fields, +integers: L.Tokens, +nulls: L.Tokens, +single: Bool) -> M.Checked(Unit):
  match xs:
    case Nil{}: Done{Unit{}}
    case +name <> rest:
      do M.Checked<Unit>:
        field : M.Field <- lookup(fields, name)
        primary_field(field, single && contains(integers, name), contains(nulls, name))
        primary_columns(rest, fields, integers, nulls, single)

def nonnull_keys(fs: M.Fields, +primary: L.Tokens) -> M.Fields:
  match fs:
    case Nil{}: Nil{}
    case M.Field{+name, kind, nullable} <> rest:
      M.Field{name, kind, nullable && Bool.not(contains(primary, name))} <> nonnull_keys(rest, primary)

type References is Data:
  References{source: String, refs: Foreigns}

def RefGroups() -> Data:
  List<&2, References>

type Catalog is Data:
  Catalog{tables: M.Schema, refs: RefGroups, names: Set}

def primary_defaults(primary: L.Tokens, +null_defaults: L.Tokens) -> M.Checked(Unit):
  match primary:
    case Nil{}: Done{Unit{}}
    case +name <> rest:
      do M.Checked<Unit>:
        require(Bool.not(contains(null_defaults, name)), "PRIMARY KEY column cannot DEFAULT NULL: " ++ name)
        primary_defaults(rest, null_defaults)

def finish_table(+name: String, build: Build, catalog: Catalog) -> M.Checked(Catalog):
  Build{+fields, integers, nulls, defaults, +keys, +primary, refs, _, null_defaults} = build
  Catalog{tables, groups, names} = catalog
  do M.Checked<Catalog>:
    require(Bool.not(List.is_empty(&2, M.Field, fields)), "a table needs at least one column")
    known_keys(keys, fields)
    primary_columns(primary, fields, integers, nulls, Nat.is_eq(List.length(&2, String, primary), 1n))
    primary_defaults(primary, null_defaults)
    all_keys : L.Groups = Bool.pick(L.Groups, List.is_empty(&2, String, primary), keys, primary <> keys)
    return Catalog{M.Table{name, nonnull_keys(List.reverse(&2, M.Field, fields), primary), List.reverse(&2, String, defaults), all_keys} <> tables,
      References{name, refs} <> groups, Set.add(names, name)}

def relation_name(+name: String, names: Set) -> M.Checked(Unit):
  do M.Checked<Unit>:
    valid_name(name)
    require(Bool.not(String.starts_with(name, "sqlite_")), "SQLite internal relation name: " ++ name)
    require(Bool.not(Pair.snd(Set, Bool, Set.has(names, name))), "duplicate table or index: " ++ name)

# Named primary/unique constraints create PostgreSQL indexes in the relation
# namespace. Other constraint names remain local to their table.
def constraint_relation(+name: String, +kind: String, +names: Set) -> M.Checked(Set):
  next = Bool.pick(Unit -> M.Checked(Set), String.eq(kind, "primary") || String.eq(kind, "unique"),
    _ => do M.Checked<Set>:
      relation_name(name, names)
      return Set.add(names, name),
    _ => Done{names})
  next(Unit{})

def constraint_relations(ts: L.Tokens, names: Set) -> M.Checked(Set):
  match ts:
    case Nil{}: Done{names}
    case "constraint" <> name <> kind <> rest:
      do M.Checked<Set>:
        next : Set <- constraint_relation(name, kind, names)
        constraint_relations(rest, next)
    case _ <> rest: constraint_relations(rest, names)

def create_table(+name: String, rest: L.Tokens, catalog: Catalog) -> M.Checked(Catalog):
  Catalog{tables, refs, +names} = catalog
  do M.Checked<Catalog>:
    relation_name(name, names)
    +body : L.Tokens <- parenthesized(List.reverse(&2, String, rest))
    groups : L.Groups <- L.balanced_chunks(body, ",")
    build : Build <- columns(groups, Build{Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}}, False{})
    relations : Set <- constraint_relations(body, Set.add(names, name))
    finish_table(name, build, Catalog{tables, refs, relations})

def index_columns(xs: L.Groups, +fields: M.Fields, +seen: L.Tokens) -> M.Checked(L.Tokens):
  match xs:
    case Nil{}: Done{List.reverse(&2, String, seen)}
    case (+name <> +rest) <> tail:
      do M.Checked<L.Tokens>:
        require(List.is_empty(&2, String, rest) || Nat.is_eq(List.length(&2, String, rest), 1n) && (contains(rest, "asc") || contains(rest, "desc")), "expected column [ASC | DESC] in index")
        require(Bool.not(contains(seen, name)), "duplicate index column: " ++ name)
        field : M.Field <- lookup(fields, name)
        index_columns(tail, fields, name <> seen)
    case _: Fail{"expected a nonempty list of index columns"}

def add_unique_key(tables: M.Schema, +target: String, +cols: L.Tokens) -> M.Schema:
  match tables:
    case Nil{}: Nil{}
    case M.Table{+name, fs, defaults, +keys} <> tail:
      next = Bool.pick(L.Groups, String.eq(name, target), cols <> keys, keys)
      M.Table{name, fs, defaults, next} <> add_unique_key(tail, target, cols)

def index_done(name: String, +target: String, cols: L.Tokens, unique: Bool, catalog: Catalog) -> Catalog:
  Catalog{+tables, refs, names} = catalog
  Catalog{Bool.pick(M.Schema, unique, add_unique_key(tables, target, cols), tables), refs, Set.add(names, name)}

def create_index(ts: L.Tokens, unique: Bool, +catalog: Catalog) -> M.Checked(Catalog):
  match ts:
    case +name <> "on" <> +target <> "(" <> rest:
      Catalog{tables, _, names} = catalog
      do M.Checked<Catalog>:
        relation_name(name, names)
        +fields : M.Fields <- find_table(tables, target)
        body : L.Tokens <- parenthesized(List.reverse(&2, String, rest))
        groups : L.Groups <- L.balanced_chunks(body, ",")
        cols : L.Tokens <- index_columns(groups, fields, Nil{})
        return index_done(name, target, cols, unique, catalog)
    case _: Fail{"expected CREATE [UNIQUE] INDEX name ON table (columns)"}

def optional_exists(ts: L.Tokens) -> M.Checked(L.Tokens):
  match ts:
    case "if" <> rest:
      do M.Checked<L.Tokens>:
        tail : L.Tokens <- expected_token(rest, "not")
        expected_token(tail, "exists")
    case _: Done{ts}

def table_tokens(ts: L.Tokens, catalog: Catalog) -> M.Checked(Catalog):
  match ts:
    case name <> "(" <> rest: create_table(name, rest, catalog)
    case _: Fail{"expected table name (columns)"}

def create_kind(ts: L.Tokens, catalog: Catalog) -> M.Checked(Catalog):
  match ts:
    case "table" <> rest:
      do M.Checked<Catalog>:
        tail : L.Tokens <- optional_exists(rest)
        table_tokens(tail, catalog)
    case "index" <> rest:
      do M.Checked<Catalog>:
        tail : L.Tokens <- optional_exists(rest)
        create_index(tail, False{}, catalog)
    case "unique" <> rest:
      do M.Checked<Catalog>:
        index : L.Tokens <- expected_token(rest, "index")
        tail : L.Tokens <- optional_exists(index)
        create_index(tail, True{}, catalog)
    case _: Fail{"expected CREATE TABLE or CREATE [UNIQUE] INDEX"}

def create(ts: L.Tokens, catalog: Catalog) -> M.Checked(Catalog):
  do M.Checked<Catalog>:
    rest : L.Tokens <- expected_token(ts, "create")
    create_kind(rest, catalog)

def tables(stmts: L.Groups, acc: Catalog) -> M.Checked(Catalog):
  match stmts:
    case Nil{}: Done{acc}
    case Nil{} <> t: tables(t, acc)
    case ts <> t:
      do M.Checked<Catalog>:
        next : Catalog <- create(ts, acc)
        tables(t, next)

def same_columns(a: L.Tokens, +b: L.Tokens) -> Bool:
  match a:
    case Nil{}: True{}
    case h <> t: contains(b, h) && same_columns(t, b)

def contains_key(keys: L.Groups, +cols: L.Tokens) -> Bool:
  match keys:
    case Nil{}: False{}
    case +key <> rest:
      (Nat.is_eq(List.length(&2, String, key), List.length(&2, String, cols)) && same_columns(key, cols)) || contains_key(rest, cols)

def compatible_fields(a: M.Field, b: M.Field) -> M.Checked(Unit):
  M.Field{an, ak, _} = a
  M.Field{bn, bk, _} = b
  require(same_kind(ak, bk), "incompatible FOREIGN KEY columns: " ++ an ++ " and " ++ bn)

def reference_columns(local: L.Tokens, remote: L.Tokens, +source: M.Fields, +target: M.Fields) -> M.Checked(Unit):
  match local remote:
    case Nil{} Nil{}: Done{Unit{}}
    case a <> aa b <> bb:
      do M.Checked<Unit>:
        from : M.Field <- lookup(source, a)
        to : M.Field <- lookup(target, b)
        compatible_fields(from, to)
        reference_columns(aa, bb, source, target)
    case _ _: Fail{"FOREIGN KEY column counts do not match"}

def reference_target(+remote: L.Tokens, local: L.Tokens, source: M.Fields, target: M.Table) -> M.Checked(Unit):
  M.Table{name, fields, _, keys} = target
  do M.Checked<Unit>:
    require(contains_key(keys, remote), "REFERENCES must name a PRIMARY KEY or UNIQUE key of " ++ name)
    reference_columns(local, remote, source, fields)

def validate_foreigns(refs: Foreigns, +source: M.Fields, +schema: M.Schema) -> M.Checked(Unit):
  match refs:
    case Nil{}: Done{Unit{}}
    case Foreign{local, target, remote} <> rest:
      do M.Checked<Unit>:
        parent : M.Table <- table(schema, target)
        reference_target(remote, local, source, parent)
        validate_foreigns(rest, source, schema)

def validate_refs(groups: RefGroups, +schema: M.Schema) -> M.Checked(Unit):
  match groups:
    case Nil{}: Done{Unit{}}
    case References{_, Nil{}} <> rest: validate_refs(rest, schema)
    case References{name, refs} <> rest:
      do M.Checked<Unit>:
        source : M.Fields <- find_table(schema, name)
        validate_foreigns(refs, source, schema)
        validate_refs(rest, schema)

def finish(catalog: Catalog) -> M.Checked(M.Schema):
  Catalog{+schema, refs, _} = catalog
  do M.Checked<M.Schema>:
    validate_refs(refs, schema)
    return List.reverse(&2, M.Table, schema)

def parse(sql: String) -> M.Checked(M.Schema):
  do M.Checked<M.Schema>:
    ts : L.Tokens <- L.tokenize(sql)
    stmts : L.Groups <- L.balanced_chunks(ts, ";")
    result : Catalog <- tables(stmts, Catalog{Nil{}, Nil{}, MTip{}})
    finish(result)
