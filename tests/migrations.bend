import Base
import ../files.bend as F
import ../model.bend as M
import ../runtime.bend as R
import ../scripts.bend as S
import ../migrations.bend as Mig
import bend-kit-postgres@0.3.1.1/postgres.bend as Pg

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
        assert(String.contains(String.to_lower(e), part), "unexpected error: " ++ e)
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

def kept_sql(r: M.Checked(S.Migration), expected: String) -> Bool:
  match r:
    case Done{S.Migration{_, _, _, [stmt]}}: String.eq(stmt, expected)
    case _: False{}

def exercise(db: R.Db) -> IO(Unit):
  do IO<Unit>:
    +one : S.Migration <- F.checked(S.Migration, "create", S.parse("1_create.sql", "CREATE/* ;ignored */TABLE items(id BIGINT PRIMARY KEY, label TEXT);"))
    +two : S.Migration <- F.checked(S.Migration, "seed", S.parse("2_seed.sql", "-- ;ignored\n INSERT INTO items VALUES (1, 'a;''b') RETURNING id; /* ;ignored */"))
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
    bad : S.Migration <- F.checked(S.Migration, "deferred", S.parse("4_deferred.sql", "CREATE TABLE links(id BIGINT REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO links VALUES (42);"))
    deferred : R.Outcome<U32> <- Mig.apply([one, two, three, bad], h)
    i : R.Db <- fails(deferred, "foreign key")
    fixed : S.Migration <- F.checked(S.Migration, "fixed", S.parse("4_deferred.sql", "CREATE TABLE links(id BIGINT REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO links VALUES (1);"))
    corrected : R.Outcome<U32> <- Mig.apply([one, two, three, fixed], i)
    j : R.Db <- counts(corrected, 1)
    R.close(j)
    IO.print("migration tests passed")

def connected(r: Result<&1, &1, String, R.Db>) -> IO(Unit):
  match r:
    case Done{db}: exercise(db)
    case Fail{e}: IO.die(Unit, 1, e)

def scoped(r: R.Outcome<R.Rows>) -> IO(Unit):
  match r:
    case R.Good{db, _}: exercise(db)
    case R.Bad{db, e}: IO.die(Unit, 1, e)
    case R.Disconnected{e}: IO.die(Unit, 1, e)

# Create the PostgreSQL journal and test tables in this session's temp schema.
def pg_connected(r: Result<&1, &1, String, R.Db>) -> IO(Unit):
  match r:
    case Fail{e}: IO.die(Unit, 1, e)
    case Done{db}:
      do IO<Unit>:
        scope : R.Outcome<R.Rows> <- R.run(db, "", "SET search_path TO pg_temp", Nil{}, 0)
        scoped(scope)

def run(args: List<String>) -> IO(Unit):
  match args:
    case [_]:
      do IO<Unit>:
        r : Result<&1, &1, String, R.Db> <- R.open_sqlite(":memory:")
        connected(r)
    case [_, port, user, db]:
      do IO<Unit>:
        r : Result<&1, &1, String, R.Db> <- R.open_postgres(Pg.Config{"127.0.0.1", Maybe.default(&2, U32, U32.read(port), 5432), False{}, user, "", db, 10000})
        pg_connected(r)
    case _: IO.die(Unit, 1, "usage: migrations [LOCAL_PG_PORT USER DATABASE]")

def main() -> IO(Unit):
  do IO<Unit>:
    +continued : String = "INSERT INTO t VALUES ('first'-- comment with ;\r\n'second')"
    assert(kept_sql(S.parse("1_comments.sql", "/* header */" ++ continued ++ "; -- trailing"), continued), "inline SQL comments and newlines changed")
    +rename : String = "ALTER INDEX old_name RENAME TO new_name"
    assert(kept_sql(S.parse("1_rename.sql", rename), rename), "index DDL must be accepted")
    assert(kept_sql(S.parse("1_bom.sql", SCon{Chr{65279}, rename}), rename), "UTF-8 BOM before the first statement")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "COMMIT;")), "transaction control must be rejected")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "INSERT INTO t VALUES (1); /* separator */ COMMIT")), "a supported statement hid a transaction command")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE UNIQUE thing")), "expected UNIQUE INDEX")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE TABLE_2 x")), "expected a complete TABLE keyword")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "INSERT INTO t VALUES (:p)")), "unbound migration parameter")
    assert(kept_sql(S.parse("004294967295_last.sql", rename), rename), "maximum migration version with leading zeros")
    assert(rejected(S.Migration, S.parse("4294967296_large.sql", "DROP TABLE x")), "version overflow")
    assert(rejected(S.Migration, S.parse("1x_malformed.sql", "DROP TABLE x")), "non-decimal migration version")
    assert(rejected(S.Migration, S.parse("000_zero.sql", "DROP TABLE x")), "zero migration version")
    assert(rejected(S.Migration, S.parse("1_empty.sql", "/* empty */")), "empty migration")
    args : List<String> <- IO.args()
    run(args)
