import Base
import ./model.bend as M
import ./runtime.bend as R
import ./scripts.bend as S

# Each step owns the session. Database errors retain it for ROLLBACK.
def Action(-A: Data) -> Type:
  R.Action(A)

def Action.pure(-A: Data, x: A) -> Action(A):
  R.Action.pure(A, x)

def Action.bind(-A: Data, -B: Data, a: Action(A), f: A -> Action(B)) -> Action(B):
  R.Action.bind(A, B, a, f)

def checked(-A: Data, r: M.Checked(A)) -> Action(A):
  R.Action.checked(A, r)

def execute(sqlite: String, pg: String, params: R.Row, width: U32) -> Action(R.Rows):
  R.query(sqlite, pg, params, width)

def command(sql: String) -> Action(Unit):
  R.command(sql)

def annotate(-A: Data, name: String, r: R.Outcome<A>) -> R.Outcome<A>:
  match r:
    case R.Good{db, x}: R.Good{db, x}
    case R.Bad{db, e}: R.Bad{db, name ++ ": " ++ e}
    case R.Disconnected{e}: R.Disconnected{name ++ ": " ++ e}

def statements_at(xs: S.Strings, +index: U32) -> Action(Unit):
  match xs:
    case Nil{}: Action.pure(Unit, Unit{})
    case sql <> rest:
      do Action<Unit>:
        db => IO.bind(R.Outcome<Unit>, R.Outcome<Unit>, command(sql, db), r =>
          IO.pure(R.Outcome<Unit>, annotate(Unit, "statement " ++ U32.show(index), r)))
        statements_at(rest, (index + 1 : U32))

def statements(xs: S.Strings) -> Action(Unit):
  statements_at(xs, 1)

def apply_one(m: S.Migration) -> Action(Unit):
  S.Migration{version, +name, source, sql} = m
  act = do Action<Unit>:
    statements(sql)
    _ : R.Rows <- execute(
      "INSERT INTO _bend_migrations (version, name, source) VALUES (?1, ?2, ?3)",
      "INSERT INTO _bend_migrations (version, name, source) VALUES ($1, $2, $3)",
      [Some{U32.show(version)}, Some{name}, Some{source}], 0)
    return Unit{}
  db => IO.bind(R.Outcome<Unit>, R.Outcome<Unit>, act(db), r => IO.pure(R.Outcome<Unit>, annotate(Unit, name, r)))

def apply_each(xs: S.History, count: U32) -> Action(U32):
  match xs:
    case Nil{}: Action.pure(U32, count)
    case m <> rest:
      do Action<U32>:
        apply_one(m)
        apply_each(rest, (count + 1 : U32))

# Compare complete sources, including comments, so a changed migration cannot
# pass because of a checksum collision. Applied history must be a local prefix.
def pending(rows: R.Rows, xs: S.History) -> M.Checked(S.History):
  match rows xs:
    case Nil{} ms: Done{ms}
    case row <> rs Nil{}: Fail{"database has migrations missing from the local directory"}
    case [Some{v}, Some{+n}, Some{src}] <> rs S.Migration{version, +name, source, _} <> rest:
      do M.Checked<S.History>:
        _ : Unit <- S.require(String.eq(v, U32.show(version)) && String.eq(n, name) && String.eq(src, source), "migration history differs at " ++ name ++ " (database has " ++ n ++ ")")
        pending(rs, rest)
    case _ _: Fail{"invalid row in _bend_migrations"}

def lock(db: R.Db) -> IO(R.Outcome<Unit>):
  match db:
    case R.SQLite{id}: IO.pure(R.Outcome<Unit>, R.Good{R.SQLite{id}, Unit{}})
    case R.Postgres{conn}:
      act = do Action<Unit>:
        _ : R.Rows <- execute("", "SELECT pg_advisory_xact_lock(1650814564, 1936813164)", Nil{}, 1)
        return Unit{}
      act(R.Postgres{conn})

def apply_locked(xs: S.History) -> Action(U32):
  do Action<U32>:
    lock
    command("CREATE TABLE IF NOT EXISTS _bend_migrations (version BIGINT NOT NULL PRIMARY KEY, name TEXT NOT NULL, source TEXT NOT NULL)")
    +sql : String = "SELECT CAST(version AS TEXT), name, source FROM _bend_migrations ORDER BY version"
    rows : R.Rows <- execute(sql, sql, Nil{}, 3)
    todo : S.History <- checked(S.History, pending(rows, xs))
    count : U32 <- apply_each(todo, 0)
    return count

# Begin outside the rollback handler: a failed BEGIN never gives us ownership
# of a transaction. BEGIN IMMEDIATE also serializes competing SQLite writers.
def transaction(xs: S.History) -> Action(U32):
  db => R.transact(U32, R.begin_migration, apply_locked(xs), db)

def apply(xs: S.History, db: R.Db) -> IO(R.Outcome<U32>):
  act = do Action<U32>:
    ordered : S.History <- checked(S.History, S.ordered(xs))
    transaction(ordered)
  act(db)
