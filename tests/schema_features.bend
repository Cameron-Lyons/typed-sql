import Base
import ../schema.bend as S
import ../model.bend as M
import ../lexer.bend as L

def unwrap(-A: Data, r: M.Checked(A)) -> IO(A):
  match r:
    case Fail{msg}: IO.die(A, 1, msg)
    case Done{x}: IO.pure(A, x)

def ensure(ok: Bool, why: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, why)

def rejected(result: M.Checked(M.Schema), sql: String) -> IO(Unit):
  match result:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, "unexpected schema acceptance: " ++ sql)

def rejects(xs: L.Tokens) -> IO(Unit):
  match xs:
    case Nil{}: IO.pure(Unit, Unit{})
    case +sql <> t:
      do IO<Unit>:
        rejected(S.parse(sql), sql)
        rejects(t)

def nonnull(fields: M.Fields) -> IO(Unit):
  match fields:
    case [M.Field{"id", M.SqlInt{}, False{}}, M.Field{"active", M.SqlBool{}, False{}}, M.Field{"title", M.SqlText{}, False{}}, M.Field{"memo", M.SqlText{}, True{}}]:
      IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "default or primary key changed field types")

def main() -> IO(Unit):
  do IO<Unit>:
    +schema : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE books (id INTEGER DEFAULT 42, active BOOL NOT NULL DEFAULT TRUE, title TEXT NOT NULL DEFAULT ('don''t, split; this'), memo TEXT DEFAULT NULL, CONSTRAINT books_pk PRIMARY KEY (id), UNIQUE (title, active)); CREATE INDEX books_title ON books(title DESC, id ASC);"))
    fields : M.Fields <- unwrap(M.Fields, S.find_table(schema, "books"))
    nonnull(fields)
    defaults : L.Tokens <- unwrap(L.Tokens, S.default_columns(schema, "books"))
    ensure(String.eq(String.join(defaults, ","), "id,active,title,memo"), "default columns are missing or reordered")
    refs : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE children (id INTEGER PRIMARY KEY, parent BIGINT REFERENCES parents(id) ON DELETE CASCADE ON UPDATE NO ACTION, code TEXT NOT NULL, tenant BIGINT NOT NULL, CONSTRAINT parent_code FOREIGN KEY (code, tenant) REFERENCES parents(code, tenant)); CREATE TABLE parents (id BIGINT NOT NULL PRIMARY KEY, tenant BIGINT NOT NULL, code TEXT NOT NULL, UNIQUE (tenant, code));"))
    indexed : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE parent (code TEXT NOT NULL); CREATE UNIQUE INDEX IF NOT EXISTS parent_code ON parent (code DESC); CREATE TABLE child (code TEXT REFERENCES parent (code) ON DELETE SET NULL ON UPDATE RESTRICT);"))
    self : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE nodes (id INTEGER CONSTRAINT nodes_pk PRIMARY KEY, parent INTEGER CONSTRAINT nodes_parent REFERENCES nodes(id), label TEXT CONSTRAINT nodes_label UNIQUE);"))
    composite : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE pairs (a INTEGER NOT NULL, b BIGINT NOT NULL, PRIMARY KEY(a,b));"))
    signed : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE limits (lo BIGINT DEFAULT (-9223372036854775808), hi BIGINT DEFAULT +0009223372036854775807, zero INTEGER DEFAULT -0);"))
    narrow : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE narrow (lo INT DEFAULT -2147483648, hi INTEGER DEFAULT +0002147483647, absent INTEGER DEFAULT NULL);"))
    local_names : M.Schema <- unwrap(M.Schema, S.parse("CREATE TABLE one (id INTEGER CONSTRAINT required NOT NULL); CREATE TABLE two (id INTEGER CONSTRAINT required NOT NULL);"))
    rejects(["CREATE TABLE t (x TEXT DEFAULT 1)",
      "CREATE TABLE t (x BOOL DEFAULT 1)", "CREATE TABLE t (x INT DEFAULT TRUE)",
      "CREATE TABLE t (x INT DEFAULT '1')", "CREATE TABLE t (x BIGINT DEFAULT 9223372036854775808)",
      "CREATE TABLE t (x BIGINT DEFAULT -9223372036854775809)", "CREATE TABLE t (x TEXT NOT NULL DEFAULT NULL)",
      "CREATE TABLE t (x INT DEFAULT 2147483648)", "CREATE TABLE t (x INTEGER DEFAULT -2147483649)",
      "CREATE TABLE t (x INTEGER DEFAULT +0002147483648)",
      "CREATE TABLE t (x INTEGER DEFAULT NULL, PRIMARY KEY(x))",
      "CREATE TABLE t (x INTEGER DEFAULT 1 DEFAULT 2)", "CREATE TABLE t (x TEXT DEFAULT :value)",
      "CREATE TABLE t (x TEXT DEFAULT upper('x'))", "CREATE TABLE t (x TEXT DEFAULT ('a', 'b'))",
      "CREATE TABLE t (x INT, PRIMARY KEY(x))", "CREATE TABLE t (x INTEGER NULL, PRIMARY KEY(x))",
      "CREATE TABLE t (x INTEGER, y INTEGER, PRIMARY KEY(x,y))", "CREATE TABLE t (x INTEGER PRIMARY KEY, PRIMARY KEY(x))",
      "CREATE TABLE t (x TEXT, UNIQUE(missing))", "CREATE TABLE t (x TEXT, UNIQUE(x,x))",
      "CREATE TABLE t (x TEXT, UNIQUE())", "CREATE TABLE t (x TEXT, UNIQUE(x), y TEXT)",
      "CREATE TABLE t (x TEXT CONSTRAINT same UNIQUE, y TEXT CONSTRAINT same UNIQUE)",
      "CREATE TABLE clash (id INTEGER CONSTRAINT clash PRIMARY KEY)",
      "CREATE TABLE clash (id TEXT CONSTRAINT clash UNIQUE)",
      "CREATE TABLE a (id INTEGER CONSTRAINT same PRIMARY KEY); CREATE TABLE b (id INTEGER CONSTRAINT same PRIMARY KEY)",
      "CREATE TABLE a (id TEXT CONSTRAINT same UNIQUE); CREATE TABLE b (id TEXT CONSTRAINT same UNIQUE)",
      "CREATE TABLE a (id INTEGER, CONSTRAINT key_name PRIMARY KEY(id)); CREATE TABLE key_name (id INT)",
      "CREATE TABLE a (id TEXT CONSTRAINT key_name UNIQUE); CREATE INDEX key_name ON a(id)",
      "CREATE TABLE a (id TEXT); CREATE INDEX key_name ON a(id); CREATE TABLE b (id TEXT CONSTRAINT key_name UNIQUE)",
      "CREATE TABLE t (x TEXT CONSTRAINT trailing)", "CREATE TABLE t (x TEXT CONSTRAINT a CONSTRAINT b UNIQUE)",
      "CREATE TABLE t (x INT REFERENCES absent(id))", "CREATE TABLE t (x INT REFERENCES t(x))",
      "CREATE TABLE p (x TEXT UNIQUE); CREATE TABLE c (x INT REFERENCES p(x))",
      "CREATE TABLE p (x INT UNIQUE); CREATE TABLE c (x INT REFERENCES p(missing))",
      "CREATE TABLE p (x INT UNIQUE); CREATE TABLE c (x INT, FOREIGN KEY(missing) REFERENCES p(x))",
      "CREATE TABLE p (x INT, y INT, UNIQUE(x,y)); CREATE TABLE c (x INT REFERENCES p(x,y))",
      "CREATE TABLE p (x INT UNIQUE); CREATE TABLE c (x INT REFERENCES p(x) ON DELETE CASCADE ON DELETE RESTRICT)",
      "CREATE TABLE t (x INT REFERENCES t(x) ON FETCH CASCADE)",
      "CREATE TABLE t (x INT); CREATE INDEX t ON t(x)", "CREATE INDEX missing ON t(x)",
      "CREATE TABLE t (x INT); CREATE INDEX i ON t(missing)", "CREATE TABLE t (x INT); CREATE INDEX i ON t()",
      "CREATE TABLE t (x INT); CREATE INDEX i ON t(x,x)", "CREATE TABLE t (x INT); CREATE INDEX i ON t(x NULLS FIRST)",
      "CREATE TABLE t (x INT); CREATE INDEX i ON t(x); CREATE INDEX i ON t(x)",
      "CREATE TABLE t (x INT); CREATE INDEX i ON t(x) WHERE x > 0", "CREATE TABLE t (x INT))",
      "CREATE TABLE t (x INT", "CREATE TABLE t (é TEXT)", "CREATE TABLE t (x INT, FOREIGN KEY(x) REFERENCES t(x),)"])
    IO.print("schema feature tests passed")
