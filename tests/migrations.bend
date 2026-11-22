import Base
import ../files.bend as F
import ../model.bend as M
import ../runtime.bend as R
import ../scripts.bend as S
import ../migrations.bend as Mig

def assert(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, message)

def counts(r: R.Outcome<U32>, expected: U32) -> IO(R.Db):
  match r:
    case R.Good{db, n}:
      do IO<R.Db>:
        assert(U32.is_eq(n, expected), "wrong number applied")
        return db
    case R.Bad{db, e}: IO.die(R.Db, 1, e)
    case R.Disconnected{e}: IO.die(R.Db, 1, e)

def fails(r: R.Outcome<U32>, part: String) -> IO(R.Db):
  match r:
    case R.Bad{db, +e}:
      do IO<R.Db>:
        assert(String.contains(e, part), "unexpected error: " ++ e)
        return db
    case R.Disconnected{e}: IO.die(R.Db, 1, e)
    case R.Good{db, n}: IO.die(R.Db, 1, "expected migration failure")

def check_rows(r: R.Outcome<R.Rows>) -> IO(R.Db):
  match r:
    case R.Good{db, [[Some{"1"}, Some{"a;'b"}]]}: IO.pure(R.Db, db)
    case R.Bad{db, e}: IO.die(R.Db, 1, e)
    case _: IO.die(R.Db, 1, "the failed batch changed the database")

def rejected(-A: Data, r: M.Checked(A)) -> Bool:
  match r:
    case Fail{_}: True{}
    case Done{_}: False{}

def exercise(db: R.Db) -> IO(Unit):
  do IO<Unit>:
    +one : S.Migration <- F.checked(S.Migration, "create", S.parse("1_create.sql", "CREATE TABLE items(id BIGINT PRIMARY KEY, label TEXT);"))
    +two : S.Migration <- F.checked(S.Migration, "seed", S.parse("2_seed.sql", "-- ;ignored\n INSERT INTO items VALUES (1, 'a;''b'); /* ;ignored */"))
    +changed : S.Migration <- F.checked(S.Migration, "changed", S.parse("2_seed.sql", "INSERT INTO items VALUES (1, 'other');"))
    +three : S.Migration <- F.checked(S.Migration, "third", S.parse("3_more.sql", "INSERT INTO items VALUES (2, 'pending');"))
    four : S.Migration <- F.checked(S.Migration, "fourth", S.parse("4_fail.sql", "INSERT INTO items VALUES (3, 'first'); INSERT INTO items VALUES (1, 'duplicate');"))
    first : R.Outcome<U32> <- Mig.apply([two, one], db)
    a : R.Db <- counts(first, 2)
    again : R.Outcome<U32> <- Mig.apply([one, two], a)
    b : R.Db <- counts(again, 0)
    drift : R.Outcome<U32> <- Mig.apply([one, changed], b)
    c : R.Db <- fails(drift, "differs")
    missing : R.Outcome<U32> <- Mig.apply([one], c)
    d : R.Db <- fails(missing, "missing")
    dupe : R.Outcome<U32> <- Mig.apply([one, two, two], d)
    e : R.Db <- fails(dupe, "duplicate migration version")
    partial : R.Outcome<U32> <- Mig.apply([one, two, three, four], e)
    f : R.Db <- fails(partial, "4_fail.sql")
    +sql : String = "SELECT CAST(id AS TEXT), label FROM items ORDER BY id"
    rows : R.Outcome<R.Rows> <- R.run(f, sql, sql, Nil{}, 2)
    g : R.Db <- check_rows(rows)
    retry : R.Outcome<U32> <- Mig.apply([one, two, three], g)
    h : R.Db <- counts(retry, 1)
    R.close(h)
    IO.print("migration tests passed")

def connected(r: Result<&1, &1, String, R.Db>) -> IO(Unit):
  match r:
    case Done{db}: exercise(db)
    case Fail{e}: IO.die(Unit, 1, e)

def main() -> IO(Unit):
  do IO<Unit>:
    assert(rejected(S.Migration, S.parse("001_bad.sql", "COMMIT;")), "transaction control must be rejected")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "INSERT INTO t VALUES (:p)")), "unbound migration parameter")
    assert(rejected(S.Migration, S.parse("4294967296_large.sql", "DROP TABLE x")), "version overflow")
    assert(rejected(S.Migration, S.parse("1_empty.sql", "/* empty */")), "empty migration")
    r : Result<&1, &1, String, R.Db> <- R.open_sqlite(":memory:")
    connected(r)
