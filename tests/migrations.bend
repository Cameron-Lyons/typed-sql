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

def check_view(r: R.Outcome<R.Rows>) -> IO(R.Db):
  match r:
    case R.Good{db, [[Some{"3"}, Some{"staged"}]]}: IO.pure(R.Db, db)
    case R.Bad{db, e}: IO.die(R.Db, 1, e)
    case _: IO.die(R.Db, 1, "view or temporary staging migration failed")

def rejected(-A: Data, r: M.Checked(A)) -> Bool:
  match r:
    case Fail{_}: True{}
    case Done{_}: False{}

def kept_sql(r: M.Checked(S.Migration), expected: String) -> Bool:
  match r:
    case Done{S.Migration{_, _, _, [stmt]}}: String.eq(stmt, expected)
    case _: False{}

def history_tests() -> IO(Unit):
  do IO<Unit>:
    +sql : String = "CREATE TABLE sample(id BIGINT)"
    +one : S.Migration <- F.checked(S.Migration, "first", S.parse("1_first.sql", sql))
    +three : S.Migration <- F.checked(S.Migration, "third", S.parse("3_third.sql", "DROP TABLE sample"))
    two : S.Migration <- F.checked(S.Migration, "inserted", S.parse("2_inserted.sql", "CREATE INDEX idx ON sample(id)"))
    renamed : S.Migration <- F.checked(S.Migration, "renamed", S.parse("1_renamed.sql", sql))
    changed : S.Migration <- F.checked(S.Migration, "changed", S.parse("1_first.sql", sql ++ " -- changed"))
    +first : R.Row = [Some{"1"}, Some{"1_first.sql"}, Some{sql}]
    third : R.Row = [Some{"3"}, Some{"3_third.sql"}, Some{"DROP TABLE sample"}]
    assert(Bool.not(rejected(S.History, Mig.pending([first], [one, three]))), "pending suffix must be accepted")
    assert(rejected(S.History, Mig.pending([first], [renamed])), "renamed migration must be rejected")
    assert(rejected(S.History, Mig.pending([first], [changed])), "comment-only migration change must be rejected")
    assert(rejected(S.History, Mig.pending([first, third], [one, two, three])), "migration inserted before applied version must be rejected")
    assert(rejected(S.History, Mig.pending([[None{}, Some{"1_first.sql"}, Some{sql}]], [one])), "NULL history fields must be rejected")
    assert(rejected(S.History, Mig.pending([[Some{"1"}, Some{"1_first.sql"}]], [one])), "short history rows must be rejected")

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
    f : R.Db <- fails(partial, "4_fail.sql: statement 2")
    +sql : String = "SELECT CAST(id AS TEXT), label FROM items ORDER BY id"
    rows : R.Outcome<R.Rows> <- R.run(f, sql, sql, Nil{}, 2)
    g : R.Db <- check_rows(rows)
    retry : R.Outcome<U32> <- Mig.apply([one, two, three], g)
    h : R.Db <- counts(retry, 1)
    bad : S.Migration <- F.checked(S.Migration, "deferred", S.parse("4_deferred.sql", "CREATE TABLE links(id BIGINT REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO links VALUES (42);"))
    deferred : R.Outcome<U32> <- Mig.apply([one, two, three, bad], h)
    i : R.Db <- fails(deferred, "foreign key")
    +fixed : S.Migration <- F.checked(S.Migration, "fixed", S.parse("4_deferred.sql", "CREATE TABLE links(id BIGINT REFERENCES items(id) DEFERRABLE INITIALLY DEFERRED); INSERT INTO links VALUES (1);"))
    corrected : R.Outcome<U32> <- Mig.apply([one, two, three, fixed], i)
    j : R.Db <- counts(corrected, 1)
    +views : S.Migration <- F.checked(S.Migration, "views", S.parse("5_views.sql", "CREATE TEMPORARY TABLE stage_items(id BIGINT, label TEXT); INSERT INTO stage_items VALUES (3, 'staged'); CREATE TEMP VIEW stage_view AS SELECT id, label FROM stage_items; INSERT INTO items SELECT id, label FROM stage_view; DROP VIEW stage_view; DROP TABLE stage_items; CREATE VIEW \"item;view\" AS SELECT id, label FROM items;"))
    staged : R.Outcome<U32> <- Mig.apply([one, two, three, fixed, views], j)
    k : R.Db <- counts(staged, 1)
    +view_sql : String = "SELECT CAST(id AS TEXT), label FROM \"item;view\" WHERE id = 3"
    from_view : R.Outcome<R.Rows> <- R.run(k, view_sql, view_sql, Nil{}, 2)
    l : R.Db <- check_view(from_view)
    failed_drop : S.Migration <- F.checked(S.Migration, "failed drop", S.parse("6_drop.sql", "DROP VIEW \"item;view\"; INSERT INTO items VALUES (1, 'duplicate');"))
    dropped : R.Outcome<U32> <- Mig.apply([one, two, three, fixed, views, failed_drop], l)
    m : R.Db <- fails(dropped, "6_drop.sql: statement 2")
    restored : R.Outcome<R.Rows> <- R.run(m, view_sql, view_sql, Nil{}, 2)
    n : R.Db <- check_view(restored)
    drop : S.Migration <- F.checked(S.Migration, "drop", S.parse("6_drop.sql", "DROP VIEW \"item;view\";"))
    finished : R.Outcome<U32> <- Mig.apply([one, two, three, fixed, views, drop], n)
    o : R.Db <- counts(finished, 1)
    R.close(o)
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
    +view_rename : String = "ALTER VIEW old_name RENAME TO new_name"
    assert(kept_sql(S.parse("1_view.sql", view_rename), view_rename), "view DDL must be accepted")
    +temp : String = "CREATE TEMP/* modifiers */TABLE scratch(id BIGINT)"
    assert(kept_sql(S.parse("1_temp.sql", temp), temp), "temporary table with comments must be accepted")
    +quote_edges : String = "INSERT INTO t VALUES ('a'''';b', \"a\"\";b\")"
    assert(kept_sql(S.parse("1_quotes.sql", quote_edges ++ "; -- end"), quote_edges), "doubled quote boundaries changed")
    +cast : String = "INSERT INTO t VALUES (1::bigint)"
    assert(kept_sql(S.parse("1_cast.sql", cast), cast), "double colon cast was treated as a parameter")
    +block_edges : String = "INSERT/***/INTO t VALUES (1) /* /x **/"
    assert(kept_sql(S.parse("1_blocks.sql", block_edges), block_edges), "block delimiter boundaries changed")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES ('a''")), "escaped quote does not close a literal")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES (1):")), "trailing colon must be rejected")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES (1) -- comment\r")), "trailing CR in a line comment must be rejected")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES (1) /* /* nested */")), "nested block must be rejected")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES (1) /* open*")), "pending block close must be rejected")
    assert(rejected(S.Migration, S.parse("1_bad.sql", "INSERT INTO t VALUES ('" ++ SCon{Chr{0}, "')"})), "NUL inside a quoted token must be rejected")
    assert(kept_sql(S.parse("1_bom.sql", SCon{Chr{65279}, rename}), rename), "UTF-8 BOM before the first statement")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "COMMIT;")), "transaction control must be rejected")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "INSERT INTO t VALUES (1); /* separator */ COMMIT")), "a supported statement hid a transaction command")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE UNIQUE thing")), "expected UNIQUE INDEX")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE TABLE_2 x")), "expected a complete TABLE keyword")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE TEMPORARY_TABLE x")), "expected a complete TEMPORARY keyword")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE TEMP INDEX x ON t(id)")), "temporary modifier requires table or view")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "CREATE VIEW \"odd;\"\"name\" AS SELECT ';''literal'; COMMIT")), "quoted view names cannot hide transaction commands")
    assert(rejected(S.Migration, S.parse("001_bad.sql", "INSERT INTO t VALUES (:p)")), "unbound migration parameter")
    assert(kept_sql(S.parse("004294967295_last.sql", rename), rename), "maximum migration version with leading zeros")
    assert(rejected(S.Migration, S.parse("4294967296_large.sql", "DROP TABLE x")), "version overflow")
    assert(rejected(S.Migration, S.parse("1x_malformed.sql", "DROP TABLE x")), "non-decimal migration version")
    assert(rejected(S.Migration, S.parse("000_zero.sql", "DROP TABLE x")), "zero migration version")
    assert(rejected(S.Migration, S.parse("1_empty.sql", "/* empty */")), "empty migration")
    history_tests()
    args : List<String> <- IO.args()
    run(args)
