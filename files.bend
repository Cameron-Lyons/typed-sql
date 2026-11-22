import Base
import bend-kit-files@0.4.0.1/files.bend as Fs
import bend-kit-bytes@0.3.3.1/bytes.bend as Bytes
import bend-kit-encoding@0.5.0.1/encoding.bend as Enc
import ./model.bend as M

def Strings() -> Data:
  List<&2, String>

def checked(-A: Data, path: String, r: M.Checked(A)) -> IO(A):
  match r:
    case Done{x}: IO.pure(A, x)
    case Fail{msg}: IO.die(A, 1, path ++ ": " ++ msg)

def result(-A: Type, path: String, r: Result<&1, &1, U32 & String, A>) -> IO(A):
  match r:
    case Done{x}: IO.pure(A, x)
    case Fail{(_, msg)}: IO.die(A, 1, path ++ ": " ++ msg)

def octets(bytes: List<&2, U32>, reversed: String) -> String:
  match bytes:
    case Nil{}: String.reverse(reversed)
    case b <> rest: octets(rest, SCon{Chr{b}, reversed})

# A lossy UTF-8 read would make different migration files appear identical.
def strict_text(+raw: String, expected: U32) -> M.Checked(String):
  +txt = Enc.utf8.decode(Bytes.from_string(raw))
  valid = String.eq(raw, Bytes.to_string(Enc.utf8.encode(txt)))
  complete = Nat.is_eq(String.length(raw), U32.to_nat(expected))
  Bool.pick(M.Checked(String), complete,
    Bool.pick(M.Checked(String), valid, Done{txt}, Fail{"invalid UTF-8"}),
    Fail{"incomplete file read"})

def read_done(+path: String, size: U32, pair: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(String):
  (f, data) = pair
  do IO<String>:
    File.close(f)
    bytes : List<&2, U32> <- result(List<&2, U32>, path, data)
    checked(String, path, strict_text(octets(bytes, ""), size))

def read_sized(path: String, f: File, size: Result<&1, &1, U32 & String, U32>) -> IO(String):
  match size:
    case Fail{e}:
      do IO<String>:
        File.close(f)
        result(String, path, Fail{e})
    case Done{+n}:
      do IO<String>:
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, n)
        read_done(path, n, pair)

def sized(path: String, pair: File & Result<&1, &1, U32 & String, U32>) -> IO(String):
  (f, size) = pair
  read_sized(path, f, size)

def read(+path: String) -> IO(String):
  do IO<String>:
    opened : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    f : File <- result(File, path, opened)
    pair : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
    sized(path, pair)

def sql_file(name: String) -> Bool:
  String.ends_with(name, ".sql")

def sql_files(+dir: String) -> IO(Strings):
  do IO<Strings>:
    r : Result<&1, &1, U32 & String, Strings> <- Fs.list_dir(dir)
    names : Strings <- result(Strings, dir, r)
    return List.filter(~String, ~sql_file, names)

def write_result(+tmp: String, +out: String, r: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match r:
    case Done{_}: IO.pure(Unit, Unit{})
    case Fail{e}:
      do IO<Unit>:
        _ : Result<&1, &1, U32 & String, Unit> <- Fs.remove(tmp)
        result(Unit, out, Fail{e})

def written(tmp: String, out: String, pair: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (file, wr) = pair
  do IO<Unit>:
    File.close(file)
    write_result(tmp, out, wr)

# Create the temporary file exclusively in the destination directory. Readers
# see the previous complete module until the successful rename.
def replace(+out: String, contents: String) -> IO(Unit):
  do IO<Unit>:
    salt : U32 <- IO.try(U32, IO.random_u32())
    +tmp : String = out ++ ".tmp." ++ U32.show(salt)
    opened : Result<&1, &1, U32 & String, File> <- File.open(tmp, "x")
    f : File <- result(File, tmp, opened)
    pair : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, contents)
    written(tmp, out, pair)
    moved : Result<&1, &1, U32 & String, Unit> <- Fs.rename(tmp, out)
    write_result(tmp, out, moved)

def stem(name: String) -> String:
  String.reverse(String.drop(String.reverse(name), 4n))

def full(+cwd: String, p: String) -> String:
  Fs.path.normalize(Fs.path.join(cwd, p))

def segments(path: String) -> Strings:
  List.filter(~String, ~(s => Bool.not(String.is_empty(s))), String.split(path, '/'))

def relative(from: Strings, to: Strings) -> Strings:
  match from to:
    case Nil{} rest: rest
    case a <> xs Nil{}: List.replicate(String, Succ{List.length(&2, String, xs)}, "..")
    case a <> +xs +b <> +ys:
      tail = Bool.pick(Unit -> Strings, String.eq(a, b),
        _ => relative(xs, ys),
        _ => List.append(&2, String, List.replicate(String, Succ{List.length(&2, String, xs)}, ".."), b <> ys))
      tail(Unit{})

def import_characters(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{+c, rest}:
      (Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '/') || Char.is_eq(c, '_') || Char.is_eq(c, '-') || Char.is_eq(c, '.')) && import_characters(rest)

def library_dir(+cwd: String, lib: String, output: String) -> M.Checked(String):
  here = segments(Fs.path.parent(full(cwd, output)))
  there = segments(full(cwd, lib))
  +rel = String.join(relative(here, there), "/")
  start = Bool.pick(String, String.eq(rel, "..") || String.starts_with(rel, "../"), "", "./")
  prefix = Bool.pick(String, String.is_empty(rel), "./", start ++ rel ++ "/")
  Bool.pick(M.Checked(String), import_characters(rel), Done{prefix}, Fail{"path to runtime contains characters unsupported by Bend imports"})
