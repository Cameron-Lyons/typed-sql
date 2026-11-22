import Base
import bend-kit-int@0.2.0.0/int.bend as Int
import ./runtime.bend as R

def I64() -> Data:
  Int.I64

def write_int(value: I64) -> String:
  Int.I64.show(value)

# Reuse the text codec: Bend 2.0.40's native backend exceeds its arity limit
# when specializing the dependency's bit-level I64.is_neg implementation.
def nonnegative(value: I64) -> Bool:
  Bool.not(String.starts_with(Int.I64.show(value), "-"))

def write_text(value: String) -> String:
  value

def write_bool(value: Bool) -> String:
  match value:
    case False{}: "0"
    case True{}: "1"

def Checked(-A: Data) -> Data:
  Result<&2, &2, String, A>

def read_text(text: String) -> Checked(String):
  Done{text}

def read_bool(text: String) -> Checked(Bool):
  match text:
    case "1": Done{True{}}
    case "t": Done{True{}}
    case "0": Done{False{}}
    case "f": Done{False{}}
    case _: Fail{"expected a boolean"}

def integer_result(value: Maybe<&2, I64>) -> Checked(I64):
  match value:
    case Some{x}: Done{x}
    case None{}: Fail{"expected a signed 64-bit integer"}

def read_int(text: String) -> Checked(I64):
  integer_result(Int.I64.read(text))

def named(-A: Data, name: String, result: Checked(A)) -> Checked(A):
  match result:
    case Fail{err}: Fail{name ++ ": " ++ err}
    case Done{x}: Done{x}

def required(-A: Data, parse: String -> Checked(A), name: String, cell: R.Cell) -> Checked(A):
  match cell:
    case None{}: Fail{name ++ ": unexpected NULL"}
    case Some{s}: named(A, name, parse(s))

def nullable(-A: Data, parse: String -> Checked(A), name: String, cell: R.Cell) -> Checked(Maybe<&2, A>):
  match cell:
    case None{}: Done{None{}}
    case Some{s}:
      do Result<&2, &2, String, Maybe<&2, A>>:
        x : A <- named(A, name, parse(s))
        return Some{x}

def prepend(-A: Data, result: Checked(A), acc: List<&2, A>) -> Checked(List<&2, A>):
  match result:
    case Fail{err}: Fail{err}
    case Done{x}: Done{x <> acc}

# Tail recursion also keeps large result sets off the JavaScript call stack.
def read_rows_into(~A: Data, ~read_row: R.Row -> Checked(A), rows: R.Rows, result: Checked(List<&2, A>)) -> Checked(List<&2, A>):
  match rows result:
    case _ Fail{err}: Fail{err}
    case Nil{} Done{acc}: Done{List.reverse(&2, A, acc)}
    case row <> tail Done{acc}:
      read_rows_into(~A, ~read_row, tail, prepend(A, read_row(row), acc))

def read_rows(~A: Data, ~read_row: R.Row -> Checked(A), rows: R.Rows) -> Checked(List<&2, A>):
  read_rows_into(~A, ~read_row, rows, Done{Nil{}})

def decoded(-A: Data, db: R.Db, name: String, result: Checked(A)) -> R.Outcome<A>:
  match result:
    case Fail{err}: R.Bad{db, name ++ ": " ++ err}
    case Done{value}: R.Good{db, value}

def select(~A: Data, ~read_row: R.Row -> Checked(A), name: String, result: R.Outcome<R.Rows>) -> R.Outcome<List<&2, A>>:
  match result:
    case R.Disconnected{err}: R.Disconnected{name ++ ": " ++ err}
    case R.Bad{db, err}: R.Bad{db, name ++ ": " ++ err}
    case R.Good{db, rows}: decoded(List<&2, A>, db, name, read_rows(~A, ~read_row, rows))

def command(name: String, result: R.Outcome<R.Rows>) -> R.Outcome<Unit>:
  match result:
    case R.Disconnected{err}: R.Disconnected{name ++ ": " ++ err}
    case R.Bad{db, err}: R.Bad{db, name ++ ": " ++ err}
    case R.Good{db, Nil{}}: R.Good{db, Unit{}}
    case R.Good{db, Con{_, _}}: R.Bad{db, name ++ ": command unexpectedly returned rows"}
