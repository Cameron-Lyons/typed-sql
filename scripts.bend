import Base
import ./model.bend as M

def Strings() -> Data:
  List<&2, String>

type Migration is Data:
  Migration{version: U32, name: String, source: String, statements: Strings}

def History() -> Data:
  List<&2, Migration>

# Outside quotes, collect the first keywords of a statement for admission.
def first_word(s: String) -> String:
  match s:
    case SNil{}: ""
    case SCon{+c, t}:
      take = Bool.pick(Unit -> String, Char.is_alpha(c),
        _ => SCon{Char.to_upper(c), first_word(t)}, _ => "")
      take(Unit{})

def allowed_words(first: String, second: String) -> Bool:
  match first second:
    case "CREATE" "TABLE": True{}
    case "CREATE" "INDEX": True{}
    case "CREATE" "UNIQUE": True{}
    case "ALTER" "TABLE": True{}
    case "DROP" "TABLE": True{}
    case "DROP" "INDEX": True{}
    case "INSERT" _: True{}
    case "UPDATE" _: True{}
    case "DELETE" _: True{}
    case _ _: False{}

def allowed(+s: String) -> Bool:
  +first = first_word(s)
  allowed_words(first, first_word(String.trim_start(String.drop(s, String.length(first)))))

def finish_checked(empty: Bool, ok: Bool, sql: String, acc: Strings) -> M.Checked(Strings):
  match empty ok:
    case True{} _: Done{acc}
    case _ True{}: Done{sql <> acc}
    case _ _: Fail{"unsupported migration statement starting with " ++ first_word(sql)}

def finish_stmt(buf: String, acc: Strings) -> M.Checked(Strings):
  +sql = String.trim(String.reverse(buf))
  finish_checked(String.is_empty(sql), allowed(sql), sql, acc)

type Mode is Data:
  Plain{}
  InQuote{delimiter: U32}
  LineComment{}
  BlockComment{}

# A single- or double-quoted token uses SQL doubled quotes. Strip comments
# with a separating space so identifiers and keywords cannot run together.
def split_go(s: String, mode: Mode, buf: String, acc: Strings) -> M.Checked(Strings):
  match s mode:
    case SNil{} InQuote{_}: Fail{"unterminated quoted token in migration"}
    case SNil{} BlockComment{}: Fail{"unterminated block comment in migration"}
    case SNil{} _:
      do M.Checked<Strings>:
        stmts : Strings <- finish_stmt(buf, acc)
        return List.reverse(&2, String, stmts)
    case SCon{Chr{0}, _} _: Fail{"NUL in migration"}
    case SCon{Chr{10}, t} LineComment{}: split_go(t, Plain{}, buf, acc)
    case SCon{Chr{13}, SCon{Chr{10}, t}} LineComment{}: split_go(t, Plain{}, buf, acc)
    case SCon{Chr{13}, _} LineComment{}: Fail{"use LF or CRLF to end a SQL line comment"}
    case SCon{_, t} LineComment{}: split_go(t, LineComment{}, buf, acc)
    case SCon{Chr{42}, SCon{Chr{47}, t}} BlockComment{}: split_go(t, Plain{}, buf, acc)
    case SCon{Chr{47}, SCon{Chr{42}, _}} BlockComment{}: Fail{"nested block comments are unsupported"}
    case SCon{_, t} BlockComment{}: split_go(t, BlockComment{}, buf, acc)
    case SCon{Chr{39}, SCon{Chr{39}, t}} InQuote{39}:
      split_go(t, InQuote{39}, SCon{Chr{39}, SCon{Chr{39}, buf}}, acc)
    case SCon{Chr{34}, SCon{Chr{34}, t}} InQuote{34}:
      split_go(t, InQuote{34}, SCon{Chr{34}, SCon{Chr{34}, buf}}, acc)
    case SCon{Chr{92}, _} InQuote{39}: Fail{"backslash escapes in migration literals are unsupported"}
    case SCon{Chr{+c}, t} InQuote{+q}:
      split_go(t, Bool.pick(Mode, U32.is_eq(c, q), Plain{}, InQuote{q}), SCon{Chr{c}, buf}, acc)
    case SCon{Chr{45}, SCon{Chr{45}, t}} Plain{}: split_go(t, LineComment{}, SCon{Chr{32}, buf}, acc)
    case SCon{Chr{47}, SCon{Chr{42}, t}} Plain{}: split_go(t, BlockComment{}, SCon{Chr{32}, buf}, acc)
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

def require(ok: Bool, reason: String) -> M.Checked(Unit):
  match ok:
    case True{}: Done{Unit{}}
    case False{}: Fail{reason}

def decimal(s: String, +acc: U32) -> M.Checked(U32):
  match s:
    case SNil{}: Done{acc}
    case SCon{Chr{+c}, rest}:
      +d = (c - 48 : U32)
      do M.Checked<U32>:
        _ : Unit <- require(U32.is_le(d, 9) && U32.is_le(acc, U32.div((4294967295 - d : U32), 10)), "invalid migration version")
        decimal(rest, (acc * 10 + d : U32))

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
        +v : U32 <- decimal(prefix, 0)
        _ : Unit <- require(U32.is_gt(v, 0), "migration versions start at 1")
        return v
    case _: Fail{"expected VERSION_description.sql"}

def parse(+name: String, +source: String) -> M.Checked(Migration):
  do M.Checked<Migration>:
    v : U32 <- numbered_parts(String.split(name, '_'))
    +stmts : Strings <- split_go(source, Plain{}, "", Nil{})
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
