import Base
import bend-kit-files@0.4.0.1/files.bend as Fs
import bend-kit-encoding@0.5.0.1/encoding.bend as Enc
import ../files.bend as F
import ../model.bend as M

def ensure(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, message)

def rejected(r: M.Checked(String)) -> Bool:
  match r:
    case Fail{_}: True{}
    case Done{_}: False{}

def utf8(bytes: List<&2, U32>, size: Nat) -> M.Checked(String):
  F.strict_text(bytes, size, Enc.Utf8{0, 128, 191, 0, ""})

def decoded(r: M.Checked(String), expected: String) -> Bool:
  match r:
    case Done{s}: String.eq(s, expected)
    case Fail{_}: False{}

def main() -> IO(Unit):
  do IO<Unit>:
    ensure(decoded(utf8([65, 195, 169, 240, 159, 144, 136], 7n), "Aé🐈"), "valid UTF-8")
    ensure(decoded(utf8([239, 191, 189], 3n), "�"), "literal replacement character")
    ensure(rejected(utf8([192, 175], 2n)), "overlong UTF-8")
    ensure(rejected(utf8([237, 160, 128], 3n)), "UTF-8 surrogate")
    ensure(rejected(utf8([244, 144, 128, 128], 4n)), "out-of-range codepoint")
    ensure(rejected(utf8([128], 1n)), "stray continuation")
    ensure(rejected(utf8([240, 159], 2n)), "truncated codepoint")
    ensure(rejected(utf8([65], 2n)), "short file read")
    ensure(rejected(utf8([65, 66], 1n)), "oversized file read")
    ensure(decoded(utf8(Nil{}, 0n), ""), "empty input")
    +dir : String <- IO.try(String, Fs.temp_dir())
    +path : String = Fs.path.join(dir, "utf8.txt")
    # The first four-byte character straddles a 64 KiB read boundary.
    +source : String = String.repeat(String.repeat("x", 65535n) ++ "🐈", 17n)
    F.replace(path, source)
    actual : String <- F.read(path)
    ensure(String.eq(source, actual), "chunked UTF-8 round trip")
    F.replace(path, "")
    empty : String <- F.read(path)
    ensure(String.is_empty(empty), "empty file")
    IO.try(Unit, Fs.remove(path))
    IO.try(Unit, Fs.remove(dir))
    IO.print("file tests passed")
