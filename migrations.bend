import Base
import ./model.bend as M
import ./runtime.bend as R
import ./scripts.bend as S

# Each step owns the session. Database errors retain it for ROLLBACK.
def Action(-A: Data) -> Type:
  R.Db -> IO(R.Outcome<A>)

def Action.pure(-A: Data, x: A) -> Action(A):
  db => IO.pure(R.Outcome<A>, R.Good{db, x})

def next(-A: Data, -B: Data, r: R.Outcome<A>, f: A -> Action(B)) -> IO(R.Outcome<B>):
  match r:
    case R.Good{db, x}: f(x, db)
    case R.Bad{db, e}: IO.pure(R.Outcome<B>, R.Bad{db, e})
    case R.Disconnected{e}: IO.pure(R.Outcome<B>, R.Disconnected{e})

def Action.bind(-A: Data, -B: Data, a: Action(A), f: A -> Action(B)) -> Action(B):
  db => IO.bind(R.Outcome<A>, R.Outcome<B>, a(db), r => next(A, B, r, f))

def checked(-A: Data, r: M.Checked(A)) -> Action(A):
  match r:
    case Done{x}: Action.pure(A, x)
    case Fail{e}: db => IO.pure(R.Outcome<A>, R.Bad{db, e})

def execute(sqlite: String, pg: String, params: R.Row, width: U32) -> Action(R.Rows):
  db => R.run(db, sqlite, pg, params, width)

def command(sql: String) -> Action(Unit):
  db => R.discard(db, sql)

def statements(xs: S.Strings) -> Action(Unit):
  match xs:
    case Nil{}: Action.pure(Unit, Unit{})
    case sql <> rest:
      do Action<Unit>:
        command(sql)
        statements(rest)

def annotate(-A: Data, name: String, r: R.Outcome<A>) -> R.Outcome<A>:
  match r:
    case R.Good{db, x}: R.Good{db, x}
    case R.Bad{db, e}: R.Bad{db, name ++ ": " ++ e}
    case R.Disconnected{e}: R.Disconnected{name ++ ": " ++ e}

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
    command("COMMIT")
    return count

def rolled_back(why: String, r: R.Outcome<R.Rows>) -> R.Outcome<U32>:
  match r:
    case R.Good{db, _}: R.Bad{db, why}
    case R.Bad{db, e}: R.Bad{db, why ++ " (rollback: " ++ e ++ ")"}
    case R.Disconnected{e}: R.Disconnected{why ++ " (rollback: " ++ e ++ ")"}

def finish(r: R.Outcome<U32>) -> IO(R.Outcome<U32>):
  match r:
    case R.Good{db, n}: IO.pure(R.Outcome<U32>, R.Good{db, n})
    case R.Disconnected{e}: IO.pure(R.Outcome<U32>, R.Disconnected{e})
    case R.Bad{db, why}:
      do IO<R.Outcome<U32>>:
        rollback : R.Outcome<R.Rows> <- R.run(db, "ROLLBACK", "ROLLBACK", Nil{}, 0)
        return rolled_back(why, rollback)

# Begin outside the rollback handler: a failed BEGIN never gives us ownership
# of a transaction. BEGIN IMMEDIATE also serializes competing SQLite writers.
def transaction(xs: S.History) -> Action(U32):
  do Action<U32>:
    _ : R.Rows <- R.begin_migration
    db => IO.bind(R.Outcome<U32>, R.Outcome<U32>, apply_locked(xs, db), finish)

def apply(xs: S.History, db: R.Db) -> IO(R.Outcome<U32>):
  act = do Action<U32>:
    ordered : S.History <- checked(S.History, S.ordered(xs))
    transaction(ordered)
  act(db)
