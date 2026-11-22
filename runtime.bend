# Database sessions and text-format parameter binding for generated queries.
import Base
import bend-kit-sqlite@0.1.0.1/sqlite.bend as S
import bend-kit-postgres@0.3.1.1/postgres.bend as Pg
import bend-kit-postgres@0.3.1.1/codec.bend as Codec
import bend-kit-bytes@0.3.3.1/bytes.bend as Bytes
import bend-kit-encoding@0.5.0.1/encoding.bend as Enc

def Cell() -> Data:
  Maybe<&2, String>

def Row() -> Data:
  List<&2, Cell>

def Rows() -> Data:
  List<&2, Row>

type Db is Type:
  SQLite{db: U32}
  Postgres{conn: Pg.Conn}

# Bad returns the live connection, so its owner can roll back a transaction.
# The Postgres driver closes the connection on a transport/protocol failure.
type Outcome<-A: Data> is Type:
  Good{db: Db, value: A}
  Bad{db: Db, message: String}
  Disconnected{message: String}

# Actions thread the affine session through queries and stop at the first error.
# Wrap a generated call as `db => q_name(db, args)` to compose it here.
def Action(-A: Data) -> Type:
  Db -> IO(Outcome<A>)

def Action.pure(-A: Data, value: A) -> Action(A):
  db => IO.pure(Outcome<A>, Good{db, value})

def Action.next(-A: Data, -B: Data, result: Outcome<A>, next: A -> Action(B)) -> IO(Outcome<B>):
  match result:
    case Good{db, value}: next(value, db)
    case Bad{db, reason}: IO.pure(Outcome<B>, Bad{db, reason})
    case Disconnected{reason}: IO.pure(Outcome<B>, Disconnected{reason})

def Action.bind(-A: Data, -B: Data, action: Action(A), next: A -> Action(B)) -> Action(B):
  db => IO.bind(Outcome<A>, Outcome<B>, action(db), result => Action.next(A, B, result, next))

def Action.fail(-A: Data, message: String) -> Action(A):
  db => IO.pure(Outcome<A>, Bad{db, message})

def Action.checked(-A: Data, result: Result<&2, &2, String, A>) -> Action(A):
  match result:
    case Done{value}: Action.pure(A, value)
    case Fail{message}: Action.fail(A, message)

def sqlite_message(e: U32 & String) -> String:
  (code, message) = e
  "SQLite " ++ U32.show(code) ++ ": " ++ message

def pg_bytes(s: String) -> String:
  Bytes.to_string(Enc.utf8.encode(s))

def pg_message(err: Pg.Err) -> String:
  Pg.Err{code, message} = err
  "Postgres " ++ code ++ ": " ++ Enc.utf8.decode(Bytes.from_string(message))

def pg_failure(err: Pg.Failure) -> String:
  match err:
    case Pg.IoFail{code, why}: "Postgres I/O " ++ U32.show(code) ++ ": " ++ why
    case Pg.Closed{}: "Postgres connection closed"
    case Pg.Malformed{}: "invalid Postgres protocol response"
    case Pg.NoTls{}: "Postgres server refused TLS"
    case Pg.Auth{why}: "Postgres authentication failed: " ++ why
    case Pg.Rejected{e}: pg_message(e)

def close(db: Db) -> IO(Unit):
  match db:
    case SQLite{id}: IO.try(Unit, S.db.close(id))
    case Postgres{conn}: Pg.close(conn)

def SqlIO(-A: Type) -> Type:
  IO(Result<&1, &1, U32 & String, A>)

def SqlIO.pure(-A: Type, value: A) -> SqlIO(A):
  IO.pure(Result<&1, &1, U32 & String, A>, Done{value})

def SqlIO.next(-A: Type, -B: Type, r: Result<&1, &1, U32 & String, A>, next: A -> SqlIO(B)) -> SqlIO(B):
  match r:
    case Done{x}: next(x)
    case Fail{e}: IO.pure(Result<&1, &1, U32 & String, B>, Fail{e})

def SqlIO.bind(-A: Type, -B: Type, action: SqlIO(A), next: A -> SqlIO(B)) -> SqlIO(B):
  do IO<Result<&1, &1, U32 & String, B>>:
    r : Result<&1, &1, U32 & String, A> <- action
    SqlIO.next(A, B, r, next)

def bind_cell(c: Cell, stmt: U32, index: U32) -> SqlIO(Unit):
  match c:
    case None{}: S.stmt.bind.null(stmt, index)
    case Some{text}: S.stmt.bind.text(stmt, index, text)

# The driver checks parameter and column indexes but exposes no count effects.
# A probe just past the expected end must return SQLITE_RANGE (25).
def expect_range(-A: Type, result: Result<&1, &1, U32 & String, A>, message: String) -> Result<&1, &1, U32 & String, Unit>:
  match result:
    case Fail{(25, _)}: Done{Unit{}}
    case Fail{error}: Fail{error}
    case Done{_}: Fail{(20, message)}

def bind_complete(stmt: U32, index: U32) -> SqlIO(Unit):
  do IO<Result<&1, &1, U32 & String, Unit>>:
    result : Result<&1, &1, U32 & String, Unit> <- S.stmt.bind.null(stmt, index)
    return expect_range(Unit, result, "missing SQLite query parameter")

def bind_params(params: Row, +stmt: U32, +index: U32) -> SqlIO(Unit):
  match params:
    case Nil{}: bind_complete(stmt, index)
    case cell <> rest:
      do SqlIO<Unit>:
        bind_cell(cell, stmt, index)
        bind_params(rest, stmt, (index + 1 : U32))

# Generated SQLite projections return text or NULL. Reading any other storage
# class is a type error, including a BLOB whose bytes happen to spell a number.
def read_kind(kind: U32, stmt: U32, index: U32) -> SqlIO(Cell):
  match kind:
    case 5: SqlIO.pure(Cell, None{})
    case 3:
      do SqlIO<Cell>:
        text : String <- S.stmt.column.text(stmt, index)
        return Some{text}
    case _:
      IO.pure(Result<&1, &1, U32 & String, Cell>, Fail{(20, "unexpected SQLite storage class in a typed result")})

def read_row(remaining: Nat, +stmt: U32, +index: U32) -> SqlIO(Row):
  match remaining:
    case 0n: SqlIO.pure(Row, Nil{})
    case 1n+tail:
      do SqlIO<Row>:
        kind : U32 <- S.stmt.column.kind(stmt, index)
        cell : Cell <- read_kind(kind, stmt, index)
        rest : Row <- read_row(tail, stmt, (index + 1 : U32))
        return cell <> rest

type Output is Data:
  Read{width: Nat}
  Discard{}

# The first row provides the result shape. With no rows, the SQLite driver has
# no column metadata to inspect. Width zero is the command/unchecked-row mode.
def check_width(ready: Bool, output: Output, stmt: U32) -> SqlIO(Unit):
  match ready output:
    case True{} Read{1n+width}:
      do IO<Result<&1, &1, U32 & String, Unit>>:
        result : Result<&1, &1, U32 & String, U32> <- S.stmt.column.kind(stmt, U32.from_nat(1n+width))
        return expect_range(U32, result, "unexpected SQLite result column count")
    case _ _: SqlIO.pure(Unit, Unit{})

def read_rows(fuel: Nat, row_ready: Bool, +stmt: U32, output: Output, rows: Rows) -> SqlIO(Rows):
  match fuel row_ready output:
    case _ False{} _: SqlIO.pure(Rows, List.reverse(&2, Row, rows))
    case 0n True{} _: IO.pure(Result<&1, &1, U32 & String, Rows>, Fail{(18, "too many result rows")})
    case 1n+remaining True{} Discard{}:
      do SqlIO<Rows>:
        ready : Bool <- S.stmt.step(stmt)
        read_rows(remaining, ready, stmt, Discard{}, rows)
    case 1n+remaining True{} Read{+width}:
      do SqlIO<Rows>:
        row : Row <- read_row(width, stmt, 0)
        ready : Bool <- S.stmt.step(stmt)
        read_rows(remaining, ready, stmt, Read{width}, row <> rows)

def execute_stmt(+stmt: U32, params: Row, +output: Output) -> SqlIO(Rows):
  do SqlIO<Rows>:
    bind_params(params, stmt, 1)
    +ready : Bool <- S.stmt.step(stmt)
    check_width(ready, output, stmt)
    read_rows(Nat.mul(65536n, 65536n), ready, stmt, output, Nil{})

def sqlite_finished(r: Result<&1, &1, U32 & String, Rows>, finalized: Result<&1, &1, U32 & String, Unit>, db: U32) -> Outcome<Rows>:
  match r finalized:
    case Fail{e} _: Bad{SQLite{db}, sqlite_message(e)}
    case Done{rows} Fail{e}: Bad{SQLite{db}, sqlite_message(e)}
    case Done{rows} Done{_}: Good{SQLite{db}, rows}

def sqlite_prepared(r: Result<&1, &1, U32 & String, U32>, db: U32, params: Row, output: Output) -> IO(Outcome<Rows>):
  match r:
    case Fail{e}: IO.pure(Outcome<Rows>, Bad{SQLite{db}, sqlite_message(e)})
    case Done{+stmt}:
      do IO<Outcome<Rows>>:
        result : Result<&1, &1, U32 & String, Rows> <- execute_stmt(stmt, params, output)
        finalized : Result<&1, &1, U32 & String, Unit> <- S.stmt.finalize(stmt)
        return sqlite_finished(result, finalized, db)

def pg_param(cell: Cell) -> Maybe<&1, Bytes.Bytes>:
  match cell:
    case None{}: None{}
    case Some{s}: Some{Enc.utf8.encode(s)}

def pg_params(params: Row) -> List<&1, Maybe<&1, Bytes.Bytes>>:
  match params:
    case Nil{}: Nil{}
    case cell <> rest: pg_param(cell) <> pg_params(rest)

def pg_cell(cell: Maybe<&1, Bytes.Bytes>) -> Cell:
  match cell:
    case None{}: None{}
    case Some{bytes}: Some{Enc.utf8.decode(bytes)}

def pg_row(cells: List<&1, Maybe<&1, Bytes.Bytes>>) -> Row:
  match cells:
    case Nil{}: Nil{}
    case cell <> rest: pg_cell(cell) <> pg_row(rest)

def pg_rows(rows: List<&1, List<&1, Maybe<&1, Bytes.Bytes>>>, acc: Rows) -> Rows:
  match rows:
    case Nil{}: List.reverse(&2, Row, acc)
    case row <> rest: pg_rows(rest, pg_row(row) <> acc)

def pg_return_rows(valid: Bool, conn: Pg.Conn, rows: List<&1, List<&1, Maybe<&1, Bytes.Bytes>>>) -> Outcome<Rows>:
  match valid:
    case True{}: Good{Postgres{conn}, pg_rows(rows, Nil{})}
    case False{}: Bad{Postgres{conn}, "unexpected Postgres result column count"}

def pg_finished(r: Result<&1, &1, Pg.Failure, Pg.Conn & Pg.Reply>, output: Output) -> Outcome<Rows>:
  match r output:
    case Fail{e} _: Disconnected{pg_failure(e)}
    case Done{(conn, Pg.Failed{e})} _: Bad{Postgres{conn}, pg_message(e)}
    case Done{(conn, Pg.Rows{_, _, _})} Discard{}: Good{Postgres{conn}, Nil{}}
    case Done{(conn, Pg.Rows{fields, rows, _})} Read{+width}:
      valid = Nat.is_eq(width, 0n) || Nat.is_eq(width, List.length(&1, Codec.Field, fields))
      pg_return_rows(valid, conn, rows)

def execute(db: Db, sqlite_sql: String, pg_sql: String, params: Row, output: Output) -> IO(Outcome<Rows>):
  match db:
    case SQLite{+id}:
      do IO<Outcome<Rows>>:
        prepared : Result<&1, &1, U32 & String, U32> <- S.stmt.prepare(id, sqlite_sql)
        sqlite_prepared(prepared, id, params, output)
    case Postgres{conn}:
      do IO<Outcome<Rows>>:
        result : Result<&1, &1, Pg.Failure, Pg.Conn & Pg.Reply> <- Pg.query(conn, pg_bytes(pg_sql), pg_params(params))
        return pg_finished(result, output)

def run(db: Db, sqlite_sql: String, pg_sql: String, params: Row, width: U32) -> IO(Outcome<Rows>):
  execute(db, sqlite_sql, pg_sql, params, Read{U32.to_nat(width)})

def discarded(r: Outcome<Rows>) -> Outcome<Unit>:
  match r:
    case Good{db, _}: Good{db, Unit{}}
    case Bad{db, why}: Bad{db, why}
    case Disconnected{why}: Disconnected{why}

# Migration statements may have RETURNING. Drain them without decoding cells.
def discard(db: Db, +sql: String) -> IO(Outcome<Unit>):
  do IO<Outcome<Unit>>:
    r : Outcome<Rows> <- execute(db, sql, sql, Nil{}, Discard{})
    return discarded(r)

def query(sqlite_sql: String, postgres_sql: String, params: Row, width: U32) -> Action(Rows):
  db => run(db, sqlite_sql, postgres_sql, params, width)

def command(sql: String) -> Action(Unit):
  db => discard(db, sql)

def pg_begin(idle: Bool, conn: Pg.Conn, context: String) -> IO(Outcome<Rows>):
  match idle:
    # A migrator waiting for the lock needs a fresh snapshot to read history.
    case True{}: run(Postgres{conn}, "", "BEGIN ISOLATION LEVEL READ COMMITTED", Nil{}, 0)
    case False{}: IO.pure(Outcome<Rows>, Bad{Postgres{conn}, context ++ " requires an idle connection"})

def begin(db: Db) -> IO(Outcome<Rows>):
  match db:
    case SQLite{id}: run(SQLite{id}, "BEGIN", "", Nil{}, 0)
    case Postgres{Pg.Conn{tls, sock, rd, key, ms, +status}}:
      pg_begin(U32.is_eq(status, 73), Pg.Conn{tls, sock, rd, key, ms, status}, "transaction")

# PostgreSQL accepts a nested BEGIN with a warning. Check ReadyForQuery's
# transaction status before letting the runner take ownership of a transaction.
def begin_migration(db: Db) -> IO(Outcome<Rows>):
  match db:
    case SQLite{id}: run(SQLite{id}, "BEGIN IMMEDIATE", "", Nil{}, 0)
    case Postgres{Pg.Conn{tls, sock, rd, key, ms, +status}}:
      pg_begin(U32.is_eq(status, 73), Pg.Conn{tls, sock, rd, key, ms, status}, "migration")

def rolled_back(-A: Data, reason: String, result: Outcome<Rows>) -> Outcome<A>:
  match result:
    case Good{db, _}: Bad{db, reason}
    case Bad{db, extra}: Bad{db, reason ++ " (rollback: " ++ extra ++ ")"}
    case Disconnected{extra}: Disconnected{reason ++ " (rollback: " ++ extra ++ ")"}

def rollback(-A: Data, db: Db, reason: String) -> IO(Outcome<A>):
  do IO<Outcome<A>>:
    result : Outcome<Rows> <- run(db, "ROLLBACK", "ROLLBACK", Nil{}, 0)
    return rolled_back(A, reason, result)

def committed(-A: Data, value: A, result: Outcome<Rows>) -> IO(Outcome<A>):
  match result:
    case Good{db, _}: IO.pure(Outcome<A>, Good{db, value})
    # A deferred constraint can fail at COMMIT and leave the transaction open.
    case Bad{db, reason}: rollback(A, db, reason)
    case Disconnected{reason}: IO.pure(Outcome<A>, Disconnected{reason})

def commit(-A: Data, db: Db, value: A) -> IO(Outcome<A>):
  do IO<Outcome<A>>:
    result : Outcome<Rows> <- run(db, "COMMIT", "COMMIT", Nil{}, 0)
    committed(A, value, result)

# PostgreSQL COMMIT in an aborted transaction succeeds with a ROLLBACK tag.
# Do not report that as success if a callback swallowed the original failure.
def pg_commit(-A: Data, status: U32, conn: Pg.Conn, value: A) -> IO(Outcome<A>):
  match status:
    case 84: commit(A, Postgres{conn}, value)
    case 69: rollback(A, Postgres{conn}, "transaction was aborted before commit")
    case _: IO.pure(Outcome<A>, Bad{Postgres{conn}, "transaction ended before commit"})

def commit_owned(-A: Data, db: Db, value: A) -> IO(Outcome<A>):
  match db:
    case SQLite{id}: commit(A, SQLite{id}, value)
    case Postgres{Pg.Conn{tls, sock, rd, key, ms, +status}}:
      pg_commit(A, status, Pg.Conn{tls, sock, rd, key, ms, status}, value)

def transaction_finished(-A: Data, result: Outcome<A>) -> IO(Outcome<A>):
  match result:
    case Good{db, value}: commit_owned(A, db, value)
    case Bad{db, reason}: rollback(A, db, reason)
    case Disconnected{reason}: IO.pure(Outcome<A>, Disconnected{reason})

def transaction_started(-A: Data, result: Outcome<Rows>, action: Action(A)) -> IO(Outcome<A>):
  match result:
    case Good{db, _}:
      do IO<Outcome<A>>:
        result : Outcome<A> <- action(db)
        transaction_finished(A, result)
    # A failed BEGIN does not grant ownership of an existing transaction.
    case Bad{db, reason}: IO.pure(Outcome<A>, Bad{db, reason})
    case Disconnected{reason}: IO.pure(Outcome<A>, Disconnected{reason})

def transact(-A: Data, start: Action(Rows), action: Action(A), db: Db) -> IO(Outcome<A>):
  do IO<Outcome<A>>:
    result : Outcome<Rows> <- start(db)
    transaction_started(A, result, action)

# The action must leave transaction control to this wrapper. A successful action
# commits; a failed action or commit rolls back. A failed BEGIN leaves db alone.
def transaction(-A: Data, action: Action(A), db: Db) -> IO(Outcome<A>):
  transact(A, begin, action, db)

def configured(r: Outcome<Rows>) -> IO(Result<&1, &1, String, Db>):
  match r:
    case Good{db, _}: IO.pure(Result<&1, &1, String, Db>, Done{db})
    case Bad{db, error}:
      do IO<Result<&1, &1, String, Db>>:
        close(db)
        return Fail{error}
    case Disconnected{error}: IO.pure(Result<&1, &1, String, Db>, Fail{error})

# The protocol transports SQL, parameters and results as UTF-8, including
# when the server stores its database in another encoding.
def pg_opened(r: Result<&1, &1, Pg.Failure, Pg.Conn>) -> IO(Result<&1, &1, String, Db>):
  match r:
    case Fail{e}: IO.pure(Result<&1, &1, String, Db>, Fail{pg_failure(e)})
    case Done{conn}:
      do IO<Result<&1, &1, String, Db>>:
        r : Outcome<Rows> <- run(Postgres{conn}, "", "SET client_encoding TO 'UTF8'", Nil{}, 0)
        configured(r)

def open_postgres(cfg: Pg.Config) -> IO(Result<&1, &1, String, Db>):
  Pg.Config{host, port, tls, user, pass, db, ms} = cfg
  do IO<Result<&1, &1, String, Db>>:
    r : Result<&1, &1, Pg.Failure, Pg.Conn> <- Pg.connect(Pg.Config{host, port, tls, pg_bytes(user), pg_bytes(pass), pg_bytes(db), ms})
    pg_opened(r)

# Foreign keys are per connection in SQLite. Enable them before any transaction.
def sqlite_opened(r: Result<&1, &1, U32 & String, U32>) -> IO(Result<&1, &1, String, Db>):
  match r:
    case Fail{e}: IO.pure(Result<&1, &1, String, Db>, Fail{sqlite_message(e)})
    case Done{db}:
      do IO<Result<&1, &1, String, Db>>:
        r : Outcome<Rows> <- run(SQLite{db}, "PRAGMA foreign_keys = ON", "", Nil{}, 0)
        configured(r)

def open_sqlite(path: String) -> IO(Result<&1, &1, String, Db>):
  do IO<Result<&1, &1, String, Db>>:
    r : Result<&1, &1, U32 & String, U32> <- S.db.open(path)
    sqlite_opened(r)
