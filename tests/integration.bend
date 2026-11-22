# Generate fixtures first; run from the repository root.
# No arguments: SQLite. PORT USER DATABASE: PostgreSQL session-local tables.
import Base
import bend-kit-int@0.2.0.0/int.bend as Int
import bend-kit-postgres@0.3.1.1/postgres.bend as Pg
import ../decode.bend as D
import ../files.bend as F
import ../migrations.bend as Mig
import ../runtime.bend as R
import ../scripts.bend as S
import ./fixtures/generated.bend as Q

def integer(n: U32) -> D.I64:
  Int.I64.from_u32(n)

# Read integer test inputs at runtime: Bend 2.0.40's native compiler cannot
# specialize several 64-bit Word constants in the same call (arity > 247).
def numbers(args: List<&2, String>) -> D.Checked(List<&2, D.I64>):
  match args:
    case Nil{}: Done{Nil{}}
    case text <> rest:
      do Result<&2, &2, String, List<&2, D.I64>>:
        value : D.I64 <- D.read_int(text)
        tail : List<&2, D.I64> <- numbers(rest)
        return value <> tail

def number(values: List<&2, D.I64>, index: Nat) -> D.I64:
  match values index:
    case value <> _ 0n: value
    case _ <> rest 1n+tail: number(rest, tail)
    case Nil{} _: integer(0)

def equal_int(value: D.I64, expected: U32) -> Bool:
  String.eq(D.write_int(value), U32.show(expected))

def ensure(ok: Bool, message: String) -> R.Action(Unit):
  R.Action.checked(Unit, Bool.pick(D.Checked(Unit), ok, Done{Unit{}}, Fail{message}))

def category(rows: List<&2, Q.Row_add_category>) -> Bool:
  match rows:
    case [Q.Row_add_category{id, label}]: equal_int(id, 1) && String.eq(label, "general")
    case _: False{}

def batch_row(row: Q.Row_add_batch, expected_id: U32, expected_title: String) -> Bool:
  match row:
    case Q.Row_add_batch{id, small, category, title, None{}, True{}, stock}:
      equal_int(id, expected_id) && equal_int(small, 7) && equal_int(category, 1) &&
        String.eq(title, expected_title) && equal_int(stock, 0)
    case _: False{}

def batch_has(rows: List<&2, Q.Row_add_batch>, +id: U32, +title: String) -> Bool:
  match rows:
    case Nil{}: False{}
    case row <> rest: batch_row(row, id, title) || batch_has(rest, id, title)

def batch(+rows: List<&2, Q.Row_add_batch>) -> Bool:
  Nat.is_eq(List.length(&2, Q.Row_add_batch, rows), 3n) &&
    batch_has(rows, 10, "Alpha10") && batch_has(rows, 2, "Alpha2") && batch_has(rows, 2147483648, "AlphaWide")

def defaults(rows: List<&2, Q.Row_add_default>) -> Bool:
  match rows:
    case [Q.Row_add_default{id, small, category, title, None{}, True{}, stock}]:
      equal_int(id, 3) && equal_int(small, 8) && equal_int(category, 1) &&
        String.eq(title, "untitled") && equal_int(stock, 0)
    case _: False{}

def distinct(rows: List<&2, Q.Row_distinct_stock>) -> Bool:
  match rows:
    case [Q.Row_distinct_stock{a, True{}}, Q.Row_distinct_stock{b, True{}}, Q.Row_distinct_stock{c, True{}}]:
      equal_int(a, 10) && equal_int(b, 2) && equal_int(c, 0)
    case _: False{}

def page(rows: List<&2, Q.Row_page_items>) -> Bool:
  match rows:
    case [Q.Row_page_items{a, title_a, None{}, True{}}, Q.Row_page_items{b, title_b, None{}, True{}}]:
      equal_int(a, 3) && String.eq(title_a, "untitled") && equal_int(b, 10) && String.eq(title_b, "Alpha10")
    case _: False{}

def matching(rows: List<&2, Q.Row_matching_items>) -> Bool:
  match rows:
    case [Q.Row_matching_items{a, title_a}, Q.Row_matching_items{b, title_b}]:
      equal_int(a, 10) && String.eq(title_a, "Alpha10") && equal_int(b, 2) && String.eq(title_b, "Alpha2")
    case _: False{}

def mixed(rows: List<&2, Q.Row_mixed_width>) -> Bool:
  match rows:
    case [Q.Row_mixed_width{id, small}]: equal_int(id, 2147483648) && equal_int(small, 7)
    case _: False{}

def updated(rows: List<&2, Q.Row_update_note>) -> Bool:
  match rows:
    case [Q.Row_update_note{id, Some{note}}]: equal_int(id, 2) && String.is_empty(note)
    case _: False{}

def found_empty(rows: List<&2, Q.Row_find_note>) -> Bool:
  match rows:
    case [Q.Row_find_note{id, Some{note}}]: equal_int(id, 2) && String.is_empty(note)
    case _: False{}

def removed(rows: List<&2, Q.Row_remove_outside>) -> Bool:
  match rows:
    case [Q.Row_remove_outside{id}]: equal_int(id, 2147483648)
    case _: False{}

# A rejected dynamic bound is checked before SQL and leaves a usable session.
def pagination_error(expected: Bool, db: R.Db, message: String) -> R.Outcome<Unit>:
  match expected:
    case True{}: R.Good{db, Unit{}}
    case False{}: R.Bad{db, "wrong pagination failure: " ++ message}

def rejected_page(result: R.Outcome<List<&2, Q.Row_page_items>>) -> R.Outcome<Unit>:
  match result:
    case R.Bad{db, +message}: pagination_error(String.contains(message, "nonnegative"), db, message)
    case R.Good{db, _}: R.Bad{db, "accepted a negative pagination parameter"}
    case R.Disconnected{why}: R.Disconnected{why}

# Stage calls with several I64 arguments outside Action lambdas. This keeps
# Bend's native closure specialization from expanding their Word(64n) inputs.
def page_bound(values: List<&2, D.I64>, count: D.I64, offset: D.I64, db: R.Db) -> IO(R.Outcome<List<&2, Q.Row_page_items>>):
  match values:
    case [zero, _, _, _, _, _, _, excluded, _, maximum, _]:
      Q.q_page_items(db, zero, maximum, "Alpha%", excluded, count, offset)
    case _: IO.pure(R.Outcome<List<&2, Q.Row_page_items>>, R.Bad{db, "invalid numeric fixtures"})

def negative_page(values: List<&2, D.I64>, count: D.I64, offset: D.I64, db: R.Db) -> IO(R.Outcome<Unit>):
  do IO<R.Outcome<Unit>>:
    result : R.Outcome<List<&2, Q.Row_page_items>> <- page_bound(values, count, offset, db)
    return rejected_page(result)

def add_batch(values: List<&2, D.I64>, db: R.Db) -> IO(R.Outcome<List<&2, Q.Row_add_batch>>):
  match values:
    case [_, _, second, _, small, _, first, _, third, _, _]:
      Q.q_add_batch(db, first, small, "Alpha10", None{}, second, "Alpha2", third, "AlphaWide")
    case _: IO.pure(R.Outcome<List<&2, Q.Row_add_batch>>, R.Bad{db, "invalid numeric fixtures"})

def seed(+values: List<&2, D.I64>) -> R.Action(Unit):
  do R.Action<Unit>:
    categories : List<&2, Q.Row_add_category> <- Q.q_add_category
    ensure(category(categories), "DEFAULT VALUES and category decoding")
    items : List<&2, Q.Row_add_batch> <- add_batch(values)
    ensure(batch(items), "multi-row insert, default values, NULL and repeated bindings")
    added : List<&2, Q.Row_add_default> <- db => Q.q_add_default(db, number(values, 3n), number(values, 5n))
    ensure(defaults(added), "omitted defaulted columns")
    _ : List<&2, Q.Row_update_stock> <- db => Q.q_update_stock(db, number(values, 2n), number(values, 6n))
    _ : List<&2, Q.Row_update_stock> <- db => Q.q_update_stock(db, number(values, 6n), number(values, 2n))
    _ : List<&2, Q.Row_update_stock> <- db => Q.q_update_stock(db, number(values, 2n), number(values, 8n))
    return Unit{}

def ordering(+values: List<&2, D.I64>) -> R.Action(Unit):
  do R.Action<Unit>:
    stocks : List<&2, Q.Row_distinct_stock> <- Q.q_distinct_stock
    ensure(distinct(stocks), "DISTINCT must remove duplicates and preserve numeric ordering")
    paged : List<&2, Q.Row_page_items> <- db => page_bound(values, number(values, 2n), number(values, 1n), db)
    ensure(page(paged), "boolean precedence, BETWEEN, LIKE, numeric ORDER BY, LIMIT/OFFSET")
    negative_page(values, number(values, 10n), number(values, 0n))
    negative_page(values, number(values, 1n), number(values, 10n))
    zero : List<&2, Q.Row_page_items> <- db => page_bound(values, number(values, 0n), number(values, 0n), db)
    ensure(List.is_empty(&2, Q.Row_page_items, zero), "LIMIT zero")

def filtering(+values: List<&2, D.I64>) -> R.Action(Unit):
  do R.Action<Unit>:
    selected : List<&2, Q.Row_matching_items> <- db => Q.q_matching_items(db, number(values, 2n), number(values, 6n), "Alpha%")
    ensure(matching(selected), "NOT with parenthesized IN and LIKE predicates")
    wide : List<&2, Q.Row_mixed_width> <- db => Q.q_mixed_width(db, number(values, 8n))
    ensure(mixed(wide), "one binding shared by INTEGER and BIGINT predicates")

def mutations(+values: List<&2, D.I64>) -> R.Action(Unit):
  do R.Action<Unit>:
    changed : List<&2, Q.Row_update_note> <- db => Q.q_update_note(db, Some{""}, number(values, 2n))
    ensure(updated(changed), "UPDATE RETURNING and repeated parameter")
    empty : List<&2, Q.Row_find_note> <- db => Q.q_find_note(db, Some{""})
    ensure(found_empty(empty), "empty string differs from SQL NULL")
    nulls : List<&2, Q.Row_find_note> <- db => Q.q_find_note(db, None{})
    ensure(List.is_empty(&2, Q.Row_find_note, nulls), "nullable parameter preserves SQL NULL comparison semantics")
    gone : List<&2, Q.Row_remove_outside> <- db => Q.q_remove_outside(db, number(values, 0n), number(values, 7n))
    ensure(removed(gone), "DELETE NOT BETWEEN RETURNING")

def queries(+values: List<&2, D.I64>) -> R.Action(Unit):
  do R.Action<Unit>:
    seed(values)
    ordering(values)
    filtering(values)
    mutations(values)

def finished(result: R.Outcome<Unit>) -> IO(Unit):
  match result:
    case R.Good{db, _}:
      do IO<Unit>:
        R.close(db)
        IO.print("generated integration tests passed")
    case R.Bad{db, why}:
      do IO<Unit>:
        R.close(db)
        IO.die(Unit, 1, why)
    case R.Disconnected{why}: IO.die(Unit, 1, why)

def migrated(result: R.Outcome<U32>, values: List<&2, D.I64>) -> IO(Unit):
  match result:
    case R.Good{db, _}:
      do IO<Unit>:
        result : R.Outcome<Unit> <- R.transaction(Unit, queries(values), db)
        finished(result)
    case R.Bad{db, why}:
      do IO<Unit>:
        R.close(db)
        IO.die(Unit, 1, why)
    case R.Disconnected{why}: IO.die(Unit, 1, why)

def exercise(db: R.Db) -> IO(Unit):
  do IO<Unit>:
    raw : String <- F.read("tests/fixtures/numbers.txt")
    +values : List<&2, D.I64> <- F.checked(List<&2, D.I64>, "numeric fixtures", numbers(String.split(String.trim(raw), Chr{10})))
    F.checked(Unit, "numeric fixtures", S.require(Nat.is_eq(List.length(&2, D.I64, values), 11n), "expected eleven numeric fixtures"))
    source : String <- F.read("tests/fixtures/schema.sql")
    migration : S.Migration <- F.checked(S.Migration, "fixture schema", S.parse("001_fixture.sql", source))
    result : R.Outcome<U32> <- Mig.apply([migration], db)
    migrated(result, values)

def scoped(result: R.Outcome<R.Rows>) -> IO(Unit):
  match result:
    case R.Good{db, _}: exercise(db)
    case R.Bad{db, why}:
      do IO<Unit>:
        R.close(db)
        IO.die(Unit, 1, why)
    case R.Disconnected{why}: IO.die(Unit, 1, why)

def scope(db: R.Db) -> IO(Unit):
  match db:
    case R.SQLite{id}: exercise(R.SQLite{id})
    case R.Postgres{conn}:
      do IO<Unit>:
        result : R.Outcome<R.Rows> <- R.run(R.Postgres{conn}, "", "SET search_path TO pg_temp", Nil{}, 0)
        scoped(result)

def connected(result: Result<&1, &1, String, R.Db>) -> IO(Unit):
  match result:
    case Done{db}: scope(db)
    case Fail{why}: IO.die(Unit, 1, why)

def run(args: List<String>) -> IO(Unit):
  match args:
    case [_]:
      do IO<Unit>:
        result : Result<&1, &1, String, R.Db> <- R.open_sqlite(":memory:")
        connected(result)
    case [_, port, user, database]:
      do IO<Unit>:
        result : Result<&1, &1, String, R.Db> <- R.open_postgres(Pg.Config{"127.0.0.1",
          Maybe.default(&2, U32, U32.read(port), 5432), False{}, user, "", database, 10000})
        connected(result)
    case _: IO.die(Unit, 1, "usage: integration [LOCAL_PG_PORT USER DATABASE]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
