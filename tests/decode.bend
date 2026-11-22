import Base
import ../decode.bend as D

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
    IO.print("decoder checks passed")
