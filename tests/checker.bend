import Base
import ../checker.bend as C
import ../model.bend as M

def ensure(ok: Bool, label: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, label)

def unwrap(-A: Data, r: M.Checked(A)) -> IO(A):
  match r:
    case Fail{msg}: IO.die(A, 1, msg)
    case Done{x}: IO.pure(A, x)

def rejection(-A: Data, r: M.Checked(A), +source: String) -> IO(Unit):
  match r:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, "unexpectedly accepted " ++ source)

def reject_queries(xs: List<&2, String>, +s: M.Schema) -> IO(Unit):
  match xs:
    case Nil{}: IO.pure(Unit, Unit{})
    case +q <> t:
      do IO<Unit>:
        rejection(M.Query, C.query(s, "bad", q), q)
        reject_queries(t, s)

def reject_schemas(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}: IO.pure(Unit, Unit{})
    case +ddl <> t:
      do IO<Unit>:
        rejection(M.Schema, C.schema(ddl), ddl)
        reject_schemas(t)

def selected(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{"fetch", sqlite, pg, M.Field{"key", M.SqlInt{}, False{}} <> Nil{},
      M.Field{"user_id", M.SqlInt{}, False{}} <> M.Field{"memo", M.SqlText{}, True{}} <> Nil{}, Nil{}}:
      do IO<Unit>:
        ensure(String.eq(sqlite, "select CASE typeof(id) WHEN 'integer' THEN CAST(id AS TEXT) WHEN 'null' THEN NULL ELSE X'' END AS \"user_id\", memo AS \"memo\" from users where id >= ?1 and id != ?1"), "SQLite SQL")
        ensure(String.eq(pg, "select \"id\" AS \"user_id\", \"memo\" AS \"memo\" from users where id >= $1::bigint and id != $1::bigint"), "Postgres SQL")
    case _: IO.die(Unit, 1, "incorrect SELECT types")

def inserted(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{_, _, _, M.Field{"i", M.SqlInt{}, False{}} <> M.Field{"msg", M.SqlText{}, True{}} <> Nil{},
      M.Field{"id", M.SqlInt{}, False{}} <> M.Field{"memo", M.SqlText{}, True{}} <> M.Field{"active", M.SqlBool{}, False{}} <> Nil{}, Nil{}}:
      IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "incorrect INSERT types")

def updated(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{_, sqlite, _, M.Field{"enabled", M.SqlBool{}, False{}} <> M.Field{"id", M.SqlInt{}, False{}} <> Nil{}, Nil{}, Nil{}}:
      ensure(String.contains(sqlite, "'don''t; :fake -- /*'"), "SQL literal changed")
    case _: IO.die(Unit, 1, "incorrect UPDATE types")

def deleted(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{_, _, _, Nil{}, M.Field{"gone", M.SqlBool{}, False{}} <> Nil{}, Nil{}}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "incorrect DELETE types")

def page(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{_, sqlite, pg, [M.Field{"id", M.SqlInt{}, False{}}],
      [M.Field{"memo", M.SqlInt{}, False{}}, M.Field{"note", M.SqlText{}, True{}}], Nil{}}:
      +order : String = "order by \"users\".\"id\" desc nulls first, \"users\".\"memo\" asc nulls first, \"users\".\"active\" asc nulls last limit 10 offset 2"
      do IO<Unit>:
        ensure(String.ends_with(sqlite, order), "SQLite must sort on the stored column")
        ensure(String.ends_with(pg, order), "PostgreSQL pagination or NULL order")
    case _: IO.die(Unit, 1, "incorrect paged SELECT types")

def expanded(q: M.Query) -> IO(Unit):
  match q:
    case M.Query{_, _, _, Nil{}, [M.Field{"extra", M.SqlInt{}, False{}},
      M.Field{"id", M.SqlInt{}, False{}}, M.Field{"memo", M.SqlText{}, True{}}, M.Field{"active", M.SqlBool{}, False{}}], Nil{}}:
      IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "wildcard changed column order or types")

def main() -> IO(Unit):
  do IO<Unit>:
    +s : M.Schema <- unwrap(M.Schema, C.schema(SCon{Chr{65279}, "/* fixture */ CREATE TABLE Users(id INTEGER PRIMARY KEY, memo TEXT, active BOOLEAN NOT NULL); CREATE TABLE flags (value BIGINT);"}))
    read : M.Query <- unwrap(M.Query, C.query(s, "fetch", "SELECT ID AS user_id, memo FROM Users WHERE id >= :key AND id != :key; -- one"))
    selected(read)
    ins : M.Query <- unwrap(M.Query, C.query(s, "add", "INSERT INTO users(id, memo, active) VALUES (:i, :msg, FALSE) RETURNING *;"))
    inserted(ins)
    upd : M.Query <- unwrap(M.Query, C.query(s, "change", "UPDATE users SET active = :enabled, memo = 'don''t; :fake -- /*' WHERE id = :id AND memo IS NOT NULL"))
    updated(upd)
    del : M.Query <- unwrap(M.Query, C.query(s, "remove", "DELETE FROM users WHERE id = -9223372036854775808 RETURNING active AS gone"))
    deleted(del)
    paged : M.Query <- unwrap(M.Query, C.query(s, "page", "SELECT id AS memo, memo AS note FROM users WHERE id >= :id ORDER BY memo DESC, note NULLS FIRST, active LIMIT +10 OFFSET 2"))
    page(paged)
    star : M.Query <- unwrap(M.Query, C.query(s, "star", SCon{Chr{65279}, "UPDATE users SET id = +0009223372036854775807 WHERE id = -0009223372036854775808 RETURNING id AS extra, *"}))
    expanded(star)
    reject_queries(["SELECT * FROM users -- LF required\r WHERE id = 1",
      "SELECT missing FROM users", "SELECT * FROM missing", "SELECT * FROM users JOIN flags",
      "SELECT * FROM users WHERE memo = :id AND id = :id", "SELECT * FROM users WHERE missing = :id",
      "SELECT id, id FROM users", "SELECT active AS id, id FROM users", "SELECT * FROM users; DELETE FROM users",
      "INSERT INTO users (id, active) VALUES (:id)", "INSERT INTO users (active) VALUES (TRUE)",
      "INSERT INTO users (id, id, active) VALUES (:id, :id, TRUE)", "DELETE FROM users WHERE active = 'true'",
      "UPDATE users SET memo = :x, memo = 'x'", "UPDATE users SET active = NULL",
      "UPDATE users SET memo = 'unterminated", "SELECT * FROM users WHERE id = 9223372036854775808",
      "SELECT * FROM users WHERE id = -9223372036854775809", "SELECT * FROM users WHERE id = :",
      "SELECT * FROM users WHERE id = : foo", "SELECT * FROM users WHERE id = NULL",
      "SELECT id, * FROM users", "SELECT *, * FROM users", "SELECT * FROM users ORDER BY",
      "SELECT * FROM users ORDER BY absent", "SELECT * FROM users ORDER id", "SELECT * FROM users ORDER BY 1",
      "SELECT * FROM users ORDER BY id DESC ASC", "SELECT * FROM users ORDER BY id NULLS low",
      "SELECT * FROM users ORDER BY id,", "SELECT * FROM users ORDER BY id WHERE active = TRUE",
      "SELECT * FROM users ORDER BY :field", "SELECT * FROM users LIMIT 1 ORDER BY id",
      "SELECT * FROM users LIMIT", "SELECT * FROM users LIMIT -1",
      "SELECT * FROM users LIMIT 0009223372036854775808", "SELECT * FROM users LIMIT 1 OFFSET -1",
      "SELECT * FROM users LIMIT 5, 6", "SELECT * FROM users OFFSET 1",
      "UPDATE users SET active = +TRUE", "DELETE FROM users WHERE id = -0009223372036854775809"], s)
    reject_schemas(["CREATE TABLE x (ctid TEXT)", "CREATE TABLE sqlite_reserved (a TEXT)",
      "CREATE TABLE x (" ++ String.repeat("x", 64n) ++ " TEXT)", "CREATE TABLE x (id INTEGER, ID TEXT)", "CREATE TABLE x (a TEXT); CREATE TABLE X(a INT)",
      "CREATE TABLE t (id UUID)", "CREATE TABLE t ()", "CREATE TABLE t (id TEXT PRIMARY KEY)",
      "CREATE TABLE t (a INTEGER PRIMARY KEY, b INTEGER PRIMARY KEY)", "DROP TABLE t", "/* open"])
    IO.print("checker tests passed")
