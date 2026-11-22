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

def create_allowed(kind: String, s: String) -> Bool:
  match kind:
    case "TABLE": True{}
    case "INDEX": True{}
    case "UNIQUE": String.eq(first_word(after_word(s, "UNIQUE")), "INDEX")
    case _: False{}

def table_or_index(+s: String) -> Bool:
  String.eq(s, "TABLE") || String.eq(s, "INDEX")

def allowed(first: String, +s: String) -> Bool:
  match first:
    case "CREATE":
      +tail = after_word(s, "CREATE")
      create_allowed(first_word(tail), tail)
    case "ALTER": table_or_index(first_word(after_word(s, "ALTER")))
    case "DROP": table_or_index(first_word(after_word(s, "DROP")))
    case "INSERT": True{}
    case "UPDATE": True{}
    case "DELETE": True{}
    case _: False{}

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

# A single- or double-quoted token uses SQL doubled quotes.
def split_go(s: String, mode: Mode, buf: String, acc: Strings) -> M.Checked(Strings):
  match s mode:
    case SNil{} InQuote{_}: Fail{"unterminated quoted token in migration"}
    case SNil{} BlockComment{}: Fail{"unterminated block comment in migration"}
    case SNil{} _:
      do M.Checked<Strings>:
        stmts : Strings <- finish_stmt(buf, acc)
        return List.reverse(&2, String, stmts)
    case SCon{Chr{0}, _} _: Fail{"NUL in migration"}
    case SCon{Chr{10}, t} LineComment{}: split_go(t, Plain{}, SCon{Chr{10}, buf}, acc)
    case SCon{Chr{13}, SCon{Chr{10}, t}} LineComment{}: split_go(t, Plain{}, SCon{Chr{10}, SCon{Chr{13}, buf}}, acc)
    case SCon{Chr{13}, _} LineComment{}: Fail{"use LF or CRLF to end a SQL line comment"}
    case SCon{c, t} LineComment{}: split_go(t, LineComment{}, SCon{c, buf}, acc)
    case SCon{Chr{42}, SCon{Chr{47}, t}} BlockComment{}: split_go(t, Plain{}, SCon{Chr{47}, SCon{Chr{42}, buf}}, acc)
    case SCon{Chr{47}, SCon{Chr{42}, _}} BlockComment{}: Fail{"nested block comments are unsupported"}
    case SCon{c, t} BlockComment{}: split_go(t, BlockComment{}, SCon{c, buf}, acc)
    case SCon{Chr{39}, SCon{Chr{39}, t}} InQuote{39}:
      split_go(t, InQuote{39}, SCon{Chr{39}, SCon{Chr{39}, buf}}, acc)
    case SCon{Chr{34}, SCon{Chr{34}, t}} InQuote{34}:
      split_go(t, InQuote{34}, SCon{Chr{34}, SCon{Chr{34}, buf}}, acc)
    case SCon{Chr{92}, _} InQuote{39}: Fail{"backslash escapes in migration literals are unsupported"}
    case SCon{Chr{+c}, t} InQuote{+q}:
      split_go(t, Bool.pick(Mode, U32.is_eq(c, q), Plain{}, InQuote{q}), SCon{Chr{c}, buf}, acc)
    case SCon{Chr{45}, SCon{Chr{45}, t}} Plain{}: split_go(t, LineComment{}, SCon{Chr{45}, SCon{Chr{45}, buf}}, acc)
    case SCon{Chr{47}, SCon{Chr{42}, t}} Plain{}: split_go(t, BlockComment{}, SCon{Chr{42}, SCon{Chr{47}, buf}}, acc)
    case SCon{Chr{39}, t} Plain{}: split_go(t, InQuote{39}, SCon{Chr{39}, buf}, acc)
    case SCon{Chr{34}, t} Plain{}: split_go(t, InQuote{34}, SCon{Chr{34}, buf}, acc)
    case SCon{Chr{59}, t} Plain{}:
      do M.Checked<Strings>:
        next : Strings <- finish_stmt(buf, acc)
        split_go(t, Plain{}, "", next)
    case SCon{Chr{58}, SCon{Chr{58}, t}} Plain{}: split_go(t, Plain{}, SCon{Chr{58}, SCon{Chr{58}, buf}}, acc)
    case SCon{Chr{58}, _} Plain{}: Fail{"parameters are unsupported in migrations"}
    case SCon{Chr{63}, _} Plain{}: Fail{"parameters are unsupported in migrations"}
    case SCon{Chr{64}, _} Plain{}: Fail{"parameters are unsupported in migrations"}
    case SCon{Chr{36}, _} Plain{}: Fail{"dollar quoting and parameters are unsupported in migrations"}
    case SCon{Chr{91}, _} Plain{}: Fail{"use double quotes for migration identifiers"}
    case SCon{Chr{96}, _} Plain{}: Fail{"use double quotes for migration identifiers"}
    case SCon{c, t} Plain{}: split_go(t, Plain{}, SCon{c, buf}, acc)

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
