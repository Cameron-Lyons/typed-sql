import Base
import ../decode.bend as D
import ../runtime.bend as R

def check(ok: Bool, name: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, name)

def integer_is(result: D.Checked(D.I64), want: String) -> Bool:
  match result:
    case Done{x}: String.eq(D.write_int(x), want)
    case Fail{_}: False{}

def roundtrip(+text: String) -> Bool:
  integer_is(D.read_int(text), text)

def rejected(-A: Data, result: D.Checked(A)) -> Bool:
  match result:
    case Done{_}: False{}
    case Fail{_}: True{}

def bool_is(result: D.Checked(Bool), want: Bool) -> Bool:
  match result want:
    case Done{True{}} True{}: True{}
    case Done{False{}} False{}: True{}
    case _ _: False{}

def null_result(result: D.Checked(Maybe<&2, Bool>)) -> Bool:
  match result:
    case Done{None{}}: True{}
    case _: False{}

def string_row(row: R.Row) -> D.Checked(String):
  match row:
    case [Some{text}]: Done{text}
    case _: Fail{"invalid row"}

def input_rows(n: Nat, acc: R.Rows) -> R.Rows:
  match n:
    case 0n: acc
    case 1n+p: input_rows(p, [Some{"middle"}] <> acc)

def expected_tail(values: List<&2, String>, n: Nat) -> Bool:
  match values n:
    case ["last"] 0n: True{}
    case "middle" <> t 1n+p: expected_tail(t, p)
    case _ _: False{}

def decoded_batch(result: D.Checked(List<&2, String>), n: Nat) -> Bool:
  match result:
    case Done{"first" <> t}: expected_tail(t, n)
    case _: False{}

def main() -> IO(Unit):
  do IO<Unit>:
    check(roundtrip("-9223372036854775808") && roundtrip("9223372036854775807") && roundtrip("0"), "signed 64-bit endpoints")
    check(rejected(D.I64, D.read_int("-9223372036854775809")) && rejected(D.I64, D.read_int("9223372036854775808")), "integer overflow")
    check(rejected(D.I64, D.read_int("12x")) && rejected(D.I64, D.read_int("")), "malformed integer")
    check(bool_is(D.read_bool("0"), False{}) && bool_is(D.read_bool("1"), True{}), "SQLite booleans")
    check(bool_is(D.read_bool("f"), False{}) && bool_is(D.read_bool("t"), True{}), "PostgreSQL booleans")
    check(rejected(Bool, D.read_bool("2")), "invalid boolean")
    check(rejected(String, D.required(String, D.read_text, "name", None{})), "required NULL")
    check(null_result(D.nullable(Bool, D.read_bool, "enabled", None{})), "nullable NULL")
    check(rejected(Maybe<&2, Bool>, D.nullable(Bool, D.read_bool, "enabled", Some{"broken"})), "malformed non-NULL value in nullable column")
    rows : R.Rows = [Some{"first"}] <> input_rows(20000n, [[Some{"last"}]])
    check(decoded_batch(D.read_rows(~String, ~string_row, rows), 20000n), "large result set preserves row order")
    check(rejected(List<&2, String>, D.read_rows(~String, ~string_row, [[Some{"ok"}], [None{}]])), "failure after a valid row")
    IO.print("decoder checks passed")
