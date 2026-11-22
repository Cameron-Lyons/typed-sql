import Base
import bend-kit-files@0.4.0.1/files.bend as Fs
import bend-kit-postgres@0.3.1.1/postgres.bend as Pg
import ./checker.bend as C
import ./generate.bend as G
import ./model.bend as M
import ./runtime.bend as R
import ./files.bend as F
import ./scripts.bend as S
import ./migrations.bend as Mig

def Queries() -> Data:
  List<&2, M.Query>

def read_queries(~A: Data, ~collect: A -> String -> C.Plan -> A,
  names: F.Strings, +dir: String, +tables: M.Schema, acc: A) -> IO(A):
  match names:
    case Nil{}: IO.pure(A, acc)
    case +filename <> rest:
      do IO<A>:
        +path : String = Fs.path.join(dir, filename)
        +name : String = F.stem(filename)
        sql : String <- F.read(path)
        plan : C.Plan <- F.checked(C.Plan, path, C.analyze(tables, name, sql))
        read_queries(~A, ~collect, rest, dir, tables, collect(acc, name, plan))

def load_queries(~A: Data, ~collect: A -> String -> C.Plan -> A,
  +schema: String, +dir: String, initial: A) -> IO(A):
  do IO<A>:
    ddl : String <- F.read(schema)
    tables : M.Schema <- F.checked(M.Schema, schema, C.schema(ddl))
    +names : F.Strings <- F.sql_files(dir)
    F.checked(Unit, dir, S.require(Bool.not(List.is_empty(&2, String, names)), "no .sql query files"))
    read_queries(~A, ~collect, names, dir, tables, initial)

def count_query(n: Nat, name: String, plan: C.Plan) -> Nat:
  Succ{n}

def collect_query(acc: Queries, name: String, plan: C.Plan) -> Queries:
  C.checked(name, plan) <> acc

def check_cmd(schema: String, dir: String) -> IO(Unit):
  do IO<Unit>:
    count : Nat <- load_queries(~Nat, ~count_query, schema, dir, 0n)
    IO.print("Checked " ++ Nat.show(count) ++ " queries.")

def generate_cmd(schema: String, dir: String, +out: String, library: IO(String)) -> IO(Unit):
  do IO<Unit>:
    F.checked(Unit, out, S.require(F.valid_output(out), "expected an importable .bend output filename"))
    reversed : Queries <- load_queries(~Queries, ~collect_query, schema, dir, Nil{})
    qs : Queries = List.reverse(&2, M.Query, reversed)
    lib : String <- library
    +prefix : String <- F.library_prefix(out, lib)
    F.replace(out, G.emit(qs, prefix ++ "runtime.bend", prefix ++ "decode.bend"))
    IO.print("Generated " ++ out)

def read_migrations(names: F.Strings, +dir: String, acc: S.History) -> IO(S.History):
  match names:
    case Nil{}: IO.pure(S.History, acc)
    case +name <> tail:
      do IO<S.History>:
        +path : String = Fs.path.join(dir, name)
        source : String <- F.read(path)
        m : S.Migration <- F.checked(S.Migration, path, S.parse(name, source))
        read_migrations(tail, dir, m <> acc)

def migrated(r: R.Outcome<U32>) -> IO(Unit):
  match r:
    case R.Good{db, n}:
      do IO<Unit>:
        R.close(db)
        IO.print("Applied " ++ U32.show(n) ++ " migrations.")
    case R.Bad{db, why}:
      do IO<Unit>:
        R.close(db)
        IO.die(Unit, 1, why)
    case R.Disconnected{why}: IO.die(Unit, 1, why)

def with_db(r: Result<&1, &1, String, R.Db>, ms: S.History) -> IO(Unit):
  match r:
    case Fail{why}: IO.die(Unit, 1, why)
    case Done{db}:
      do IO<Unit>:
        result : R.Outcome<U32> <- Mig.apply(ms, db)
        migrated(result)

def migrate(+dir: String, open_db: IO(Result<&1, &1, String, R.Db>)) -> IO(Unit):
  do IO<Unit>:
    names : F.Strings <- F.sql_files(dir)
    ms : S.History <- read_migrations(names, dir, Nil{})
    r : Result<&1, &1, String, R.Db> <- open_db
    with_db(r, ms)

def env_value(r: Result<&1, &1, U32 & String, String>, fallback: String) -> String:
  match r:
    case Done{s}: s
    case Fail{_}: fallback

def env(key: String, fallback: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(key)
    return env_value(r, fallback)

def ssl_mode(mode: String) -> M.Checked(Bool):
  match mode:
    case "verify-full": Done{True{}}
    case "disable": Done{False{}}
    case _: Fail{"expected verify-full or disable"}

def tcp_port(parsed: Maybe<&2, U32>) -> M.Checked(U32):
  match parsed:
    case Some{+n}: Bool.pick(M.Checked(U32), U32.is_gt(n, 0) && U32.is_le(n, 65535),
      Done{n}, Fail{"expected a TCP port from 1 to 65535"})
    case None{}: Fail{"expected a TCP port from 1 to 65535"}

def pg_open() -> IO(Result<&1, &1, String, R.Db>):
  do IO<Result<&1, &1, String, R.Db>>:
    host : String <- env("PGHOST", "localhost")
    +user : String <- env("PGUSER", "postgres")
    database : String <- env("PGDATABASE", user)
    password : String <- env("PGPASSWORD", "")
    number : String <- env("PGPORT", "5432")
    port : U32 <- F.checked(U32, "PGPORT", tcp_port(U32.read(number)))
    mode : String <- env("PGSSLMODE", "verify-full")
    tls : Bool <- F.checked(Bool, "PGSSLMODE", ssl_mode(mode))
    R.open_postgres(Pg.Config{host, port, tls, user, password, database, 10000})

def usage() -> String:
  "typed-sql check SCHEMA.sql QUERY_DIR\n"
    ++ "typed-sql generate SCHEMA.sql QUERY_DIR OUTPUT.bend [LIB_DIR]\n"
    ++ "typed-sql migrate sqlite DATABASE MIGRATION_DIR\n"
    ++ "typed-sql migrate postgres MIGRATION_DIR"

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--help" <> Nil{}: IO.print(usage)
    case _ <> "help" <> Nil{}: IO.print(usage)
    case _ <> "check" <> schema <> dir <> Nil{}: check_cmd(schema, dir)
    case path <> "generate" <> schema <> dir <> out <> Nil{}: generate_cmd(schema, dir, out, F.default_library(path))
    case _ <> "generate" <> schema <> dir <> out <> lib <> Nil{}: generate_cmd(schema, dir, out, IO.pure(String, lib))
    case _ <> "migrate" <> "sqlite" <> path <> dir <> Nil{}: migrate(dir, R.open_sqlite(path))
    case _ <> "migrate" <> "postgres" <> dir <> Nil{}: migrate(dir, pg_open)
    case _: IO.die(Unit, 2, usage)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
