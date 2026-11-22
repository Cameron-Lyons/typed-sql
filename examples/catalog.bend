import Base
import ../runtime.bend as R
import ./queries.bend as Q

def display(rows: List<&2, Q.Row_find_book>) -> IO(Unit):
  match rows:
    case Nil{}: IO.print("No matching book.")
    case Q.Row_find_book{title, author, printed} <> rest:
      do IO<Unit>:
        IO.print(title ++ " by " ++ Maybe.default(&2, String, author, "unknown"))
        IO.print("In print: " ++ Bool.show(printed))

def fetched(r: R.Outcome<List<&2, Q.Row_find_book>>) -> IO(Unit):
  match r:
    case R.Good{db, rows}:
      do IO<Unit>:
        R.close(db)
        display(rows)
    case R.Bad{db, msg}:
      do IO<Unit>:
        R.close(db)
        IO.die(Unit, 1, msg)
    case R.Disconnected{msg}: IO.die(Unit, 1, msg)

def opened(r: Result<&1, &1, String, R.Db>, title: String) -> IO(Unit):
  match r:
    case Fail{why}: IO.die(Unit, 1, why)
    case Done{db}:
      do IO<Unit>:
        rows : R.Outcome<List<&2, Q.Row_find_book>> <- Q.q_find_book(db, title)
        fetched(rows)

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> path <> title <> Nil{}:
      do IO<Unit>:
        r : Result<&1, &1, String, R.Db> <- R.open_sqlite(path)
        opened(r, title)
    case _: IO.die(Unit, 2, "usage: catalog DATABASE TITLE")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
