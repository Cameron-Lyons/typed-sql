import Base
import ./model.bend as M

def Strings() -> Data:
  List<&2, String>

type Migration is Data:
  Migration{version: U32, name: String, source: String, statements: Strings}

def History() -> Data:
  List<&2, Migration>

def require(ok: Bool, reason: String) -> M.Checked(Unit):
  match ok:
    case True{}: Done{Unit{}}
    case False{}: Fail{reason}

type Mode is Data:
  Plain{}
  InQuote{delimiter: U32}
  LineComment{}
  BlockComment{}

# Inspect only the leading keywords. Keep the original comments and newlines
# in the executed SQL, since PostgreSQL uses newlines between string literals.
def skip_trivia(s: String, mode: Mode) -> String:
  match s mode:
    case SNil{} _: ""
    case SCon{Chr{10}, t} LineComment{}: skip_trivia(t, Plain{})
    case SCon{_, t} LineComment{}: skip_trivia(t, LineComment{})
    case SCon{Chr{42}, SCon{Chr{47}, t}} BlockComment{}: skip_trivia(t, Plain{})
    case SCon{_, t} BlockComment{}: skip_trivia(t, BlockComment{})
    case SCon{Chr{45}, SCon{Chr{45}, t}} Plain{}: skip_trivia(t, LineComment{})
    case SCon{Chr{47}, SCon{Chr{42}, t}} Plain{}: skip_trivia(t, BlockComment{})
    case SCon{+c, +t} _:
      next = Bool.pick(Unit -> String, Char.is_space(c),
        _ => skip_trivia(t, Plain{}), _ => SCon{c, t})
      next(Unit{})

def first_word(s: String) -> String:
  match s:
    case SNil{}: ""
    case SCon{+c, t}:
      part = Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '_') || U32.is_ge(Char.to_u32(c), 128)
      take = Bool.pick(Unit -> String, part,
        _ => SCon{Char.to_upper(c), first_word(t)}, _ => "")
      take(Unit{})

def after_word(s: String, word: String) -> String:
  skip_trivia(String.drop(s, String.length(word)), Plain{})

def table_or_view(+s: String) -> Bool:
  String.eq(s, "TABLE") || String.eq(s, "VIEW")

def create_allowed(+kind: String, +s: String) -> Bool:
  table_or_view(kind) || String.eq(kind, "INDEX") ||
    (String.eq(kind, "UNIQUE") && String.eq(first_word(after_word(s, "UNIQUE")), "INDEX")) ||
    ((String.eq(kind, "TEMP") || String.eq(kind, "TEMPORARY")) && table_or_view(first_word(after_word(s, kind))))

def table_index_or_view(+s: String) -> Bool:
  table_or_view(s) || String.eq(s, "INDEX")

def statement_kind(+first: String) -> U32:
  Bool.pick(U32, String.eq(first, "CREATE"), 1,
    Bool.pick(U32, String.eq(first, "ALTER") || String.eq(first, "DROP"), 2,
      Bool.pick(U32, String.eq(first, "INSERT") || String.eq(first, "UPDATE") || String.eq(first, "DELETE"), 3, 0)))

def allowed_kind(kind: U32, first: String, s: String) -> Bool:
  match kind:
    case 1:
      +tail = after_word(s, first)
      create_allowed(first_word(tail), tail)
    case 2: table_index_or_view(first_word(after_word(s, first)))
    case 3: True{}
    case _: False{}

def allowed(+first: String, s: String) -> Bool:
  allowed_kind(statement_kind(first), first, s)

def admit(sql: String, acc: Strings) -> M.Checked(Strings):
  match sql:
    case SNil{}: Done{acc}
    case SCon{c, t}:
      +statement : String = SCon{c, t}
      +first = first_word(statement)
      do M.Checked<Strings>:
        _ : Unit <- require(allowed(first, statement), "unsupported migration statement starting with " ++ first)
        return statement <> acc

def finish_stmt(buf: String, acc: Strings) -> M.Checked(Strings):
  admit(skip_trivia(String.reverse(String.trim_start(buf)), Plain{}), acc)

# Split one character per step. Pending delimiters stay in the state, avoiding
# the compiler expansion from matching deep source strings against every mode.
type ScanMode is Data:
  SqlPlain{}
  Prefix{code: U32}
  Quoted{delimiter: U32}
  QuoteEnd{delimiter: U32}
  SqlLine{}
  SqlLineCR{}
  SqlBlock{}
  SqlBlockSlash{}
  SqlBlockStar{}

type ScriptState is Data:
  ScriptState{mode: ScanMode, reversed: String, statements: Strings}

def keep(mode: ScanMode, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  Done{ScriptState{mode, SCon{c, buf}, acc}}

def plain_code(code: U32, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match code:
    case 45: keep(Prefix{45}, c, buf, acc)
    case 47: keep(Prefix{47}, c, buf, acc)
    case 58: keep(Prefix{58}, c, buf, acc)
    case 39: keep(Quoted{39}, c, buf, acc)
    case 34: keep(Quoted{34}, c, buf, acc)
    case 59:
      do M.Checked<ScriptState>:
        next : Strings <- finish_stmt(buf, acc)
        return ScriptState{SqlPlain{}, "", next}
    case 63: Fail{"parameters are unsupported in migrations"}
    case 64: Fail{"parameters are unsupported in migrations"}
    case 36: Fail{"dollar quoting and parameters are unsupported in migrations"}
    case 91: Fail{"use double quotes for migration identifiers"}
    case 96: Fail{"use double quotes for migration identifiers"}
    case _: keep(SqlPlain{}, c, buf, acc)

def plain_char(+c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  plain_code(Char.to_u32(c), c, buf, acc)

def prefix_pair(paired: Bool, mode: ScanMode, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match paired:
    case True{}: keep(mode, c, buf, acc)
    case False{}: plain_char(c, buf, acc)

def colon_pair(paired: Bool, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match paired:
    case True{}: keep(SqlPlain{}, c, buf, acc)
    case False{}: Fail{"parameters are unsupported in migrations"}

def prefix_char(code: U32, +c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match code:
    case 45: prefix_pair(Char.is_eq(c, '-'), SqlLine{}, c, buf, acc)
    case 47: prefix_pair(Char.is_eq(c, '*'), SqlBlock{}, c, buf, acc)
    case _: colon_pair(Char.is_eq(c, ':'), c, buf, acc)

def quoted_char(+delimiter: U32, +c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  do M.Checked<ScriptState>:
    require(Bool.not(U32.is_eq(delimiter, 39) && Char.is_eq(c, Chr{92})), "backslash escapes in migration literals are unsupported")
    keep(Bool.pick(ScanMode, U32.is_eq(Char.to_u32(c), delimiter), QuoteEnd{delimiter}, Quoted{delimiter}), c, buf, acc)

def quote_end(doubled: Bool, delimiter: U32, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match doubled:
    case True{}: keep(Quoted{delimiter}, c, buf, acc)
    case False{}: plain_char(c, buf, acc)

def line_char(+c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  mode = Bool.pick(ScanMode, Char.is_eq(c, Chr{10}), SqlPlain{},
    Bool.pick(ScanMode, Char.is_eq(c, Chr{13}), SqlLineCR{}, SqlLine{}))
  keep(mode, c, buf, acc)

def line_cr(newline: Bool, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match newline:
    case True{}: keep(SqlPlain{}, c, buf, acc)
    case False{}: Fail{"use LF or CRLF to end a SQL line comment"}

def block_char(+c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  mode = Bool.pick(ScanMode, Char.is_eq(c, '*'), SqlBlockStar{},
    Bool.pick(ScanMode, Char.is_eq(c, '/'), SqlBlockSlash{}, SqlBlock{}))
  keep(mode, c, buf, acc)

def block_slash(nested: Bool, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match nested:
    case True{}: Fail{"nested block comments are unsupported"}
    case False{}: block_char(c, buf, acc)

def block_star(closed: Bool, c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match closed:
    case True{}: keep(SqlPlain{}, c, buf, acc)
    case False{}: block_char(c, buf, acc)

def split_step(mode: ScanMode, +c: Char, buf: String, acc: Strings) -> M.Checked(ScriptState):
  match mode:
    case SqlPlain{}: plain_char(c, buf, acc)
    case Prefix{code}: prefix_char(code, c, buf, acc)
    case Quoted{q}: quoted_char(q, c, buf, acc)
    case QuoteEnd{+q}: quote_end(U32.is_eq(Char.to_u32(c), q), q, c, buf, acc)
    case SqlLine{}: line_char(c, buf, acc)
    case SqlLineCR{}: line_cr(Char.is_eq(c, Chr{10}), c, buf, acc)
    case SqlBlock{}: block_char(c, buf, acc)
    case SqlBlockSlash{}: block_slash(Char.is_eq(c, '*'), c, buf, acc)
    case SqlBlockStar{}: block_star(Char.is_eq(c, '/'), c, buf, acc)

def split_nonzero(nul: Bool, c: Char, state: ScriptState) -> M.Checked(ScriptState):
  match nul:
    case True{}: Fail{"NUL in migration"}
    case False{}:
      ScriptState{mode, buf, acc} = state
      split_step(mode, c, buf, acc)

def end_state(mode: ScanMode) -> M.Checked(Unit):
  match mode:
    case Quoted{_}: Fail{"unterminated quoted token in migration"}
    case SqlBlock{}: Fail{"unterminated block comment in migration"}
    case SqlBlockSlash{}: Fail{"unterminated block comment in migration"}
    case SqlBlockStar{}: Fail{"unterminated block comment in migration"}
    case SqlLineCR{}: Fail{"use LF or CRLF to end a SQL line comment"}
    case Prefix{58}: Fail{"parameters are unsupported in migrations"}
    case _: Done{Unit{}}

def split_finish(state: ScriptState) -> M.Checked(Strings):
  ScriptState{mode, buf, acc} = state
  do M.Checked<Strings>:
    end_state(mode)
    stmts : Strings <- finish_stmt(buf, acc)
    return List.reverse(&2, String, stmts)

def split_chars(s: String, state: ScriptState) -> M.Checked(Strings):
  match s:
    case SNil{}: split_finish(state)
    case SCon{+c, tail}:
      do M.Checked<Strings>:
        next : ScriptState <- split_nonzero(Char.is_eq(c, Chr{0}), c, state)
        split_chars(tail, next)

def scan_mode(mode: Mode) -> ScanMode:
  match mode:
    case Plain{}: SqlPlain{}
    case InQuote{q}: Quoted{q}
    case LineComment{}: SqlLine{}
    case BlockComment{}: SqlBlock{}

def split_go(s: String, mode: Mode, buf: String, acc: Strings) -> M.Checked(Strings):
  split_chars(s, ScriptState{scan_mode(mode), buf, acc})

def version(parsed: Maybe<&2, U32>) -> M.Checked(U32):
  match parsed:
    case None{}: Fail{"invalid migration version"}
    case Some{0}: Fail{"migration versions start at 1"}
    case Some{v}: Done{v}

def slug(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{+c, t}: (Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '_') || Char.is_eq(c, '-')) && slug(t)

def numbered_parts(parts: Strings) -> M.Checked(U32):
  match parts:
    case prefix <> label <> tail:
      +descr = String.join(label <> tail, "_")
      +stem = String.reverse(String.drop(String.reverse(descr), 4n))
      do M.Checked<U32>:
        _ : Unit <- require(String.ends_with(descr, ".sql") && Bool.not(String.is_empty(stem)) && slug(stem), "expected VERSION_description.sql")
        version(U32.read(prefix))
    case _: Fail{"expected VERSION_description.sql"}

def script_text(source: String) -> String:
  match source:
    case SCon{Chr{65279}, rest}: rest
    case text: text

def parse(+name: String, +source: String) -> M.Checked(Migration):
  do M.Checked<Migration>:
    v : U32 <- numbered_parts(String.split(name, '_'))
    +stmts : Strings <- split_go(script_text(source), Plain{}, "", Nil{})
    _ : Unit <- require(Bool.not(List.is_empty(&2, String, stmts)), "empty migration")
    return Migration{v, name, source, stmts}

def before(a: Migration, b: Migration) -> Bool:
  Migration{x, _, _, _} = a
  Migration{y, _, _, _} = b
  U32.is_le(x, y)

def unique(xs: History, previous: U32) -> M.Checked(Unit):
  match xs:
    case Nil{}: Done{Unit{}}
    case Migration{+v, name, _, _} <> rest:
      do M.Checked<Unit>:
        _ : Unit <- require(U32.is_gt(v, previous), "duplicate migration version in " ++ name)
        unique(rest, v)

def ordered(xs: History) -> M.Checked(History):
  +all = List.sort(~Migration, ~before, xs)
  do M.Checked<History>:
    _ : Unit <- unique(all, 0)
    return all
