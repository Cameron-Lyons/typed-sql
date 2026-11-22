# Build once, then run the binary with a parameter count and iteration count.
import Base
import ../checker.bend as C
import ../model.bend as M
import ../generate.bend as G

def unwrap(-A: Data, r: M.Checked(A)) -> IO(A):
  match r:
    case Done{x}: IO.pure(A, x)
    case Fail{why}: IO.die(A, 1, why)

def conditions(n: Nat, +index: U32) -> List<&2, String>:
  match n:
    case 0n: Nil{}
    case 1n+rest: ("id >= :p" ++ U32.show(index)) <> conditions(rest, (index + 1 : U32))

def repeat(n: Nat, +schema: M.Schema, +sql: String, total: Nat) -> IO(Nat):
  match n:
    case 0n: IO.pure(Nat, total)
    case 1n+rest:
      do IO<Nat>:
        query : M.Query <- unwrap(M.Query, C.query(schema, "bench", sql))
        size : Nat = String.length(G.emit([query], "./runtime.bend", "./decode.bend"))
        repeat(rest, schema, sql, Nat.add(total, size))

def positive(value: Maybe<&2, U32>) -> IO(U32):
  match value:
    case Some{0}: IO.die(U32, 2, "benchmark counts must be positive")
    case Some{n}: IO.pure(U32, n)
    case None{}: IO.die(U32, 2, "expected unsigned benchmark count")

def bench(+count: U32, +iterations: U32) -> IO(Unit):
  do IO<Unit>:
    schema : M.Schema = [M.Table{"items", [M.Field{"id", M.SqlInt{}, False{}}], Nil{}, [["id"]]}]
    sql : String = "SELECT id FROM items WHERE " ++ String.join(conditions(U32.to_nat(count), 1), " AND ")
    started : Nat <- IO.now()
    bytes : Nat <- repeat(U32.to_nat(iterations), schema, sql, 0n)
    ended : Nat <- IO.now()
    IO.print("parameters=" ++ U32.show(count) ++ " iterations=" ++ U32.show(iterations)
      ++ " elapsed_ms=" ++ Nat.show(Nat.sub(ended, started)) ++ " generated_characters=" ++ Nat.show(bytes))

def dispatch(args: List<String>) -> IO(Unit):
  match args:
    case _ <> a <> b <> Nil{}:
      do IO<Unit>:
        count : U32 <- positive(U32.read(a))
        iterations : U32 <- positive(U32.read(b))
        bench(count, iterations)
    case _: bench(256, 20)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    dispatch(args)
