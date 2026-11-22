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

def read_queries(names: F.Strings, +dir: String, +tables: M.Schema) -> IO(Queries):
  match names:
    case Nil{}: IO.pure(Queries, Nil{})
    case +name <> rest:
      do IO<Queries>:
        +path : String = Fs.path.join(dir, name)
        sql : String <- F.read(path)
        q : M.Query <- F.checked(M.Query, path, C.query(tables, F.stem(name), sql))
        tail : Queries <- read_queries(rest, dir, tables)
        return q <> tail

def load_queries(+schema: String, +dir: String) -> IO(Queries):
  do IO<Queries>:
    ddl : String <- F.read(schema)
    tables : M.Schema <- F.checked(M.Schema, schema, C.schema(ddl))
    +names : F.Strings <- F.sql_files(dir)
    F.checked(Unit, dir, S.require(Bool.not(List.is_empty(&2, String, names)), "no .sql query files"))
    read_queries(names, dir, tables)

def check_cmd(schema: String, dir: String) -> IO(Unit):
  do IO<Unit>:
    qs : Queries <- load_queries(schema, dir)
    IO.print("Checked " ++ Nat.show(List.length(&2, M.Query, qs)) ++ " queries.")

def generate_cmd(schema: String, dir: String, +out: String, lib: String) -> IO(Unit):
  do IO<Unit>:
    F.checked(Unit, out, S.require(String.ends_with(out, ".bend"), "expected a .bend output file"))
    qs : Queries <- load_queries(schema, dir)
    cwd : String <- IO.try(String, IO.get_env("PWD"))
    +prefix : String <- F.checked(String, out, F.library_dir(cwd, lib, out))
    F.replace(out, G.emit(qs, prefix ++ "runtime.bend", prefix ++ "decode.bend"))
    IO.print("Generated " ++ out)

def read_migrations(names: F.Strings, +dir: String) -> IO(S.History):
  match names:
    case Nil{}: IO.pure(S.History, Nil{})
    case +name <> tail:
      do IO<S.History>:
        +path : String = Fs.path.join(dir, name)
        source : String <- F.read(path)
        m : S.Migration <- F.checked(S.Migration, path, S.parse(name, source))
        more : S.History <- read_migrations(tail, dir)
        return m <> more

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
    ms : S.History <- read_migrations(names, dir)
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

def pg_open() -> IO(Result<&1, &1, String, R.Db>):
  do IO<Result<&1, &1, String, R.Db>>:
    host : String <- env("PGHOST", "localhost")
    +user : String <- env("PGUSER", "postgres")
    database : String <- env("PGDATABASE", user)
    password : String <- env("PGPASSWORD", "")
    number : String <- env("PGPORT", "5432")
    +port : U32 <- F.checked(U32, "PGPORT", S.decimal(number, 0))
    F.checked(Unit, "PGPORT", S.require(U32.is_gt(port, 0) && U32.is_le(port, 65535), "expected a TCP port from 1 to 65535"))
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
    case path <> "generate" <> schema <> dir <> out <> Nil{}: generate_cmd(schema, dir, out, Fs.path.parent(path))
    case _ <> "generate" <> schema <> dir <> out <> lib <> Nil{}: generate_cmd(schema, dir, out, lib)
    case _ <> "migrate" <> "sqlite" <> path <> dir <> Nil{}: migrate(dir, R.open_sqlite(path))
    case _ <> "migrate" <> "postgres" <> dir <> Nil{}: migrate(dir, pg_open)
    case _: IO.die(Unit, 2, usage)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
