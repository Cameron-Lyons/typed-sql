import Base
import bend-kit-files@0.4.0.1/files.bend as Fs
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

# Reject malformed bytes before the UTF-8 decoder can replace them. The
# migration journal must distinguish a literal U+FFFD from an invalid file.
def strict_byte(state: Enc.Utf8, +byte: U32) -> M.Checked(Enc.Utf8):
  match state:
    case Enc.Utf8{0, _, _, _, out}:
      +ascii = U32.is_lt(byte, 128)
      valid = ascii || (U32.is_ge(byte, 194) && U32.is_le(byte, 244))
      Bool.pick(M.Checked(Enc.Utf8), valid, Done{Enc.utf8.lead(byte, out, ascii)}, Fail{"invalid UTF-8"})
    case Enc.Utf8{need, lo, hi, cp, out}:
      valid = U32.is_ge(byte, lo) && U32.is_le(byte, hi)
      Bool.pick(M.Checked(Enc.Utf8), valid, Done{Enc.utf8.cont.in(need, cp, byte, out, True{})}, Fail{"invalid UTF-8"})

def strict_text(bytes: List<&2, U32>, expected: Nat, state: Enc.Utf8) -> M.Checked(String):
  match bytes expected state:
    case Nil{} 0n Enc.Utf8{0, _, _, _, out}: Done{String.reverse(out)}
    case Nil{} 0n _: Fail{"invalid UTF-8"}
    case byte <> rest 1n+left st:
      do M.Checked<String>:
        next : Enc.Utf8 <- strict_byte(st, byte)
        strict_text(rest, left, next)
    case _ _ _: Fail{"incomplete file read"}

def read_done(+path: String, size: U32, pair: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(String):
  (f, data) = pair
  do IO<String>:
    File.close(f)
    bytes : List<&2, U32> <- result(List<&2, U32>, path, data)
    checked(String, path, strict_text(bytes, U32.to_nat(size), Enc.Utf8{0, 128, 191, 0, ""}))

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

def is_regular(info: Fs.Info) -> Bool:
  match info:
    case Fs.Info{Fs.Regular{}, _, _}: True{}
    case _: False{}

def regular_file(+path: String) -> IO(Bool):
  do IO<Bool>:
    metadata : Result<&1, &1, U32 & String, Fs.Info> <- Fs.stat(path)
    info : Fs.Info <- result(Fs.Info, path, metadata)
    return is_regular(info)

def regular_entries(names: Strings, +dir: String, +acc: Strings) -> IO(Strings):
  match names:
    case Nil{}: IO.pure(Strings, List.reverse(&2, String, acc))
    case +name <> rest:
      do IO<Strings>:
        regular : Bool <- regular_file(Fs.path.join(dir, name))
        regular_entries(rest, dir, Bool.pick(Strings, regular, name <> acc, acc))

def sql_files(+dir: String) -> IO(Strings):
  do IO<Strings>:
    r : Result<&1, &1, U32 & String, Strings> <- Fs.list_dir(dir)
    names : Strings <- result(Strings, dir, r)
    regular_entries(List.filter(~String, ~sql_file, names), dir, Nil{})

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

def name_tail(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{+c, rest}:
      (Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '_') || Char.is_eq(c, '-')) && name_tail(rest)

def module_name(s: String) -> Bool:
  match s:
    case SNil{}: False{}
    case SCon{+c, rest}: (Char.is_alpha(c) || Char.is_eq(c, '_')) && name_tail(rest)

def valid_output(+path: String) -> Bool:
  name = Fs.path.file_name(path)
  String.ends_with(path, ".bend") && module_name(String.reverse(String.drop(String.reverse(name), 5n)))

def import_component(component: String) -> Bool:
  +name = component
  String.eq(name, "..") || module_name(name)

def import_prefix(here: String, there: String) -> M.Checked(String):
  +parts = relative(segments(here), segments(there))
  +rel = String.join(parts, "/")
  start = Bool.pick(String, String.eq(rel, "..") || String.starts_with(rel, "../"), "", "./")
  prefix = Bool.pick(String, String.is_empty(rel), "./", start ++ rel ++ "/")
  Bool.pick(M.Checked(String), List.all(~&2, ~String, ~import_component, parts), Done{prefix},
    Fail{"path to runtime contains a directory name unsupported by Bend imports"})

# Keep symlinks and ".." intact until the operating system resolves the directory.
def output_parent(reversed: String) -> String:
  match reversed:
    case SNil{}: "."
    case SCon{Chr{47}, rest}: String.reverse(SCon{Chr{47}, rest})
    case SCon{_, rest}: output_parent(rest)

def path_output(path: String, response: U32 & (String & String)) -> IO(String):
  match response:
    case (0, (out, _)): IO.pure(String, String.reverse(String.drop(String.reverse(out), 1n)))
    case (_, (_, err)): IO.die(String, 1, path ++ ": could not resolve path " ++ String.trim_end(err))

def resolve(+path: String, locate_command: Bool) -> IO(String):
  # Bare executables are located by the shell just as they were at invocation.
  # The path is always a separate argument, including names containing quotes.
  script = Bool.pick(String, locate_command,
    "p=$(command -v -- \"$1\") || exit 1; command -p realpath -- \"$p\"",
    "command -p realpath -- \"$1\"")
  do IO<String>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/sh", ["-c", script, "typed-sql", path], "", 65536, 10000)
    response : U32 & (String & String) <- result(U32 & (String & String), path, r)
    path_output(path, response)

def default_library(+program: String) -> IO(String):
  do IO<String>:
    path : String <- resolve(program, Bool.not(String.contains(program, "/") || String.ends_with(program, ".bend")))
    return Fs.path.parent(path)

def check_library_file(+dir: String, +name: String) -> IO(Unit):
  do IO<Unit>:
    +path : String = Fs.path.join(dir, name)
    regular : Bool <- regular_file(path)
    checked(Unit, path, Bool.pick(M.Checked(Unit), regular, Done{Unit{}}, Fail{"expected a library file"}))

def library_prefix(+out: String, lib: String) -> IO(String):
  do IO<String>:
    +here : String <- resolve(output_parent(String.reverse(out)), False{})
    +there : String <- resolve(lib, False{})
    +name : String = Fs.path.file_name(out)
    overlaps : Bool = String.eq(here, there) && (String.eq(name, "runtime.bend") || String.eq(name, "decode.bend"))
    checked(Unit, out, Bool.pick(M.Checked(Unit), overlaps, Fail{"output would replace its own runtime or decoder"}, Done{Unit{}}))
    check_library_file(there, "runtime.bend")
    check_library_file(there, "decode.bend")
    checked(String, out, import_prefix(here, there))
