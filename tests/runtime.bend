# Run without arguments for SQLite, or with a local Postgres port, user and db.
import Base
import ../runtime.bend as R
import bend-kit-postgres@0.3.1.1/postgres.bend as Pg

def rows_equal(rows: R.Rows) -> Bool:
  match rows:
    case [[Some{lo}, Some{name}, None{}], [Some{hi}, Some{z}, Some{empty}]]:
      String.eq(lo, "-9223372036854775808") && String.eq(name, "Zoë '😀'; --") &&
        String.eq(hi, "9223372036854775807") && String.eq(z, "z") && String.eq(empty, "")
    case _: False{}

def assert_rows(ok: Bool, db: R.Db) -> IO(R.Db):
  match ok:
    case True{}: IO.pure(R.Db, db)
    case False{}:
      do IO<R.Db>:
        R.close(db)
        IO.die(R.Db, 1, "unexpected rows")

def success(result: R.Outcome<R.Rows>, inspect: Bool) -> IO(R.Db):
  match result:
    case R.Good{db, rows}: assert_rows(Bool.not(inspect) || rows_equal(rows), db)
    case R.Bad{db, error}:
      do IO<R.Db>:
        R.close(db)
        IO.die(R.Db, 1, error)
    case R.Disconnected{error}: IO.die(R.Db, 1, error)

def rejected(result: R.Outcome<R.Rows>) -> IO(R.Db):
  match result:
    case R.Bad{db, error}: IO.pure(R.Db, db)
    case R.Good{db, _}: assert_rows(False{}, db)
    case R.Disconnected{error}: IO.die(R.Db, 1, error)

def storage_classes(db: R.Db) -> IO(R.Db):
  match db:
    case R.Postgres{conn}: IO.pure(R.Db, R.Postgres{conn})
    case R.SQLite{id}:
      do IO<R.Db>:
        blob : R.Outcome<R.Rows> <- R.run(R.SQLite{id}, "SELECT X'31'", "", Nil{}, 1)
        d1 : R.Db <- rejected(blob)
        real : R.Outcome<R.Rows> <- R.run(d1, "SELECT 1.5", "", Nil{}, 1)
        d2 : R.Db <- rejected(real)
        integer : R.Outcome<R.Rows> <- R.run(d2, "SELECT 1", "", Nil{}, 1)
        rejected(integer)

def shape_checks(db: R.Db) -> IO(R.Db):
  do IO<R.Db>:
    missing : R.Outcome<R.Rows> <- R.run(db, "SELECT ?1", "SELECT $1::text", Nil{}, 1)
    a : R.Db <- rejected(missing)
    # A missing nullable value must fail before the statement changes the table.
    missing_write : R.Outcome<R.Rows> <- R.run(a, "INSERT INTO test_runtime(id, name) VALUES (0, ?1)", "INSERT INTO test_runtime(id, name) VALUES (0, $1)", Nil{}, 0)
    unwritten : R.Db <- rejected(missing_write)
    extra : R.Outcome<R.Rows> <- R.run(unwritten, "SELECT ?1", "SELECT $1::text", [Some{"one"}, Some{"two"}], 1)
    b : R.Db <- rejected(extra)
    short : R.Outcome<R.Rows> <- R.run(b, "SELECT 'one', 'two'", "SELECT 'one', 'two'", Nil{}, 1)
    c : R.Db <- rejected(short)
    wide : R.Outcome<R.Rows> <- R.run(c, "SELECT 'one'", "SELECT 'one'", Nil{}, 2)
    rejected(wide)

def action_value(result: R.Outcome<U32>, expected: U32) -> IO(R.Db):
  match result:
    case R.Good{db, value}: assert_rows(U32.is_eq(value, expected), db)
    case R.Bad{db, error}:
      do IO<R.Db>:
        R.close(db)
        IO.die(R.Db, 1, error)
    case R.Disconnected{error}: IO.die(R.Db, 1, error)

def action_failed(result: R.Outcome<U32>, part: String) -> IO(R.Db):
  match result:
    case R.Bad{db, error}: assert_rows(String.contains(String.to_lower(error), part), db)
    case R.Good{db, _}: assert_rows(False{}, db)
    case R.Disconnected{error}: IO.die(R.Db, 1, error)

def counted(result: R.Outcome<R.Rows>, expected: String) -> IO(R.Db):
  match result:
    case R.Good{db, [[Some{count}]]}: assert_rows(String.eq(count, expected), db)
    case R.Good{db, _}: assert_rows(False{}, db)
    case R.Bad{db, error}:
      do IO<R.Db>:
        R.close(db)
        IO.die(R.Db, 1, error)
    case R.Disconnected{error}: IO.die(R.Db, 1, error)

def count_rows(db: R.Db, expected: String) -> IO(R.Db):
  do IO<R.Db>:
    +sql : String = "SELECT CAST(COUNT(*) AS TEXT) FROM test_transactions"
    result : R.Outcome<R.Rows> <- R.run(db, sql, sql, Nil{}, 1)
    counted(result, expected)

# Deliberately hide a database failure to check PostgreSQL's aborted status.
def swallowed(result: R.Outcome<R.Rows>) -> R.Outcome<U32>:
  match result:
    case R.Good{db, _}: R.Good{db, 1}
    case R.Bad{db, _}: R.Good{db, 1}
    case R.Disconnected{error}: R.Disconnected{error}

def aborted(db: R.Db) -> IO(R.Db):
  match db:
    case R.SQLite{id}: IO.pure(R.Db, R.SQLite{id})
    case R.Postgres{conn}:
      act = do R.Action<U32>:
        R.command("INSERT INTO test_transactions(id) VALUES (2)")
        db => do IO<R.Outcome<U32>>:
          +sql : String = "INSERT INTO test_transactions(id) VALUES (1)"
          r : R.Outcome<R.Rows> <- R.run(db, sql, sql, Nil{}, 0)
          return swallowed(r)
      do IO<R.Db>:
        result : R.Outcome<U32> <- R.transaction(U32, act, R.Postgres{conn})
        clean : R.Db <- action_failed(result, "aborted")
        count_rows(clean, "1")

def transactions(db: R.Db) -> IO(R.Db):
  do IO<R.Db>:
    +ddl : String = "CREATE TEMPORARY TABLE test_transactions(id BIGINT PRIMARY KEY, parent BIGINT REFERENCES test_transactions(id) DEFERRABLE INITIALLY DEFERRED)"
    created : R.Outcome<R.Rows> <- R.run(db, ddl, ddl, Nil{}, 0)
    a : R.Db <- success(created, False{})
    committed : R.Outcome<U32> <- R.transaction(U32, do R.Action<U32>:
      R.command("INSERT INTO test_transactions(id) VALUES (1)")
      return 37, a)
    b : R.Db <- action_value(committed, 37)
    c : R.Db <- count_rows(b, "1")
    failed : R.Outcome<U32> <- R.transaction(U32, do R.Action<U32>:
      R.command("INSERT INTO test_transactions(id) VALUES (2)")
      R.Action.fail(U32, "business rule"), c)
    d : R.Db <- action_failed(failed, "business rule")
    e : R.Db <- count_rows(d, "1")
    duplicate : R.Outcome<U32> <- R.transaction(U32, do R.Action<U32>:
      R.command("INSERT INTO test_transactions(id) VALUES (2)")
      R.command("INSERT INTO test_transactions(id) VALUES (1)")
      R.command("INSERT INTO test_transactions(id) VALUES (3)")
      return 0, e)
    f : R.Db <- action_failed(duplicate, "unique")
    g : R.Db <- count_rows(f, "1")
    deferred : R.Outcome<U32> <- R.transaction(U32, do R.Action<U32>:
      R.command("INSERT INTO test_transactions(id, parent) VALUES (2, 99)")
      return 0, g)
    h : R.Db <- action_failed(deferred, "foreign key")
    i : R.Db <- count_rows(h, "1")
    outer : R.Outcome<R.Rows> <- R.begin(i)
    j : R.Db <- success(outer, False{})
    +insert : String = "INSERT INTO test_transactions(id) VALUES (2)"
    changed : R.Outcome<R.Rows> <- R.run(j, insert, insert, Nil{}, 0)
    k : R.Db <- success(changed, False{})
    nested : R.Outcome<U32> <- R.transaction(U32, R.Action.pure(U32, 42), k)
    l : R.Db <- action_failed(nested, "transaction")
    m : R.Db <- count_rows(l, "2")
    rolled : R.Outcome<R.Rows> <- R.run(m, "ROLLBACK", "ROLLBACK", Nil{}, 0)
    n : R.Db <- success(rolled, False{})
    o : R.Db <- count_rows(n, "1")
    aborted(o)

def outer_transaction(db: R.Db) -> IO(R.Db):
  do IO<R.Db>:
    +change : String = "UPDATE test_runtime SET name = 'uncommitted'"
    opened : R.Outcome<R.Rows> <- R.run(db, "BEGIN", "BEGIN", Nil{}, 0)
    d1 : R.Db <- success(opened, False{})
    changed : R.Outcome<R.Rows> <- R.run(d1, change, change, Nil{}, 0)
    d2 : R.Db <- success(changed, False{})
    nested : R.Outcome<R.Rows> <- R.begin_migration(d2)
    d3 : R.Db <- rejected(nested)
    rolled : R.Outcome<R.Rows> <- R.run(d3, "ROLLBACK", "ROLLBACK", Nil{}, 0)
    success(rolled, False{})

def exercise(db: R.Db) -> IO(Unit):
  +ddl : String = "CREATE TEMPORARY TABLE test_runtime (id BIGINT PRIMARY KEY, name TEXT, note TEXT, parent BIGINT REFERENCES test_runtime(id))"
  +sqlite_insert : String = "INSERT INTO test_runtime (id, name, note) VALUES (?1, ?2, ?3)"
  +pg_insert : String = "INSERT INTO test_runtime (id, name, note) VALUES ($1, $2, $3)"
  +first : R.Row = [Some{"-9223372036854775808"}, Some{"Zoë '😀'; --"}, None{}]
  +second : R.Row = [Some{"9223372036854775807"}, Some{"z"}, Some{""}]
  do IO<Unit>:
    a : R.Outcome<R.Rows> <- R.run(db, ddl, ddl, Nil{}, 0)
    db1 : R.Db <- success(a, False{})
    b : R.Outcome<R.Rows> <- R.run(db1, sqlite_insert, pg_insert, first, 0)
    db2 : R.Db <- success(b, False{})
    c : R.Outcome<R.Rows> <- R.run(db2, sqlite_insert, pg_insert, first, 0)
    db3 : R.Db <- rejected(c)
    +bad_fk : String = "UPDATE test_runtime SET parent = 0"
    fk : R.Outcome<R.Rows> <- R.run(db3, bad_fk, bad_fk, Nil{}, 0)
    valid : R.Db <- rejected(fk)
    d : R.Outcome<R.Rows> <- R.run(valid, sqlite_insert, pg_insert, second, 0)
    db4 : R.Db <- success(d, False{})
    dbtx : R.Db <- outer_transaction(db4)
    dbshape : R.Db <- shape_checks(dbtx)
    dbactions : R.Db <- transactions(dbshape)
    clean : R.Db <- storage_classes(dbactions)
    e : R.Outcome<R.Rows> <- R.run(clean, "SELECT CAST(id AS TEXT), name, note FROM test_runtime ORDER BY id", "SELECT id, name, note FROM test_runtime ORDER BY id", Nil{}, 3)
    db5 : R.Db <- success(e, True{})
    R.close(db5)
    IO.print("runtime tests passed")

def opened(r: Result<&1, &1, String, R.Db>) -> IO(Unit):
  match r:
    case Done{db}: exercise(db)
    case Fail{why}: IO.die(Unit, 1, why)

def run(args: List<String>) -> IO(Unit):
  match args:
    case [_]:
      do IO<Unit>:
        r : Result<&1, &1, String, R.Db> <- R.open_sqlite(":memory:")
        opened(r)
    case [_, port, user, db]:
      do IO<Unit>:
        r : Result<&1, &1, String, R.Db> <- R.open_postgres(Pg.Config{"127.0.0.1", Maybe.default(&2, U32, U32.read(port), 5432), False{}, user, "", db, 10000})
        opened(r)
    case _: IO.die(Unit, 1, "usage: runtime [LOCAL_PG_PORT USER DATABASE]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
