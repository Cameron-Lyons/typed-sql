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

def strict_bytes(bytes: List<&2, U32>, expected: Nat, state: Enc.Utf8) -> M.Checked(Enc.Utf8):
  match bytes expected state:
    case Nil{} 0n st: Done{st}
    case byte <> rest 1n+left st:
      do M.Checked<Enc.Utf8>:
        next : Enc.Utf8 <- strict_byte(st, byte)
        strict_bytes(rest, left, next)
    case _ _ _: Fail{"incomplete file read"}

def strict_finish(state: Enc.Utf8) -> M.Checked(String):
  match state:
    case Enc.Utf8{0, _, _, _, out}: Done{String.reverse(out)}
    case _: Fail{"invalid UTF-8"}

def strict_text(bytes: List<&2, U32>, expected: Nat, state: Enc.Utf8) -> M.Checked(String):
  do M.Checked<String>:
    decoded : Enc.Utf8 <- strict_bytes(bytes, expected, state)
    strict_finish(decoded)

type Reading is Data:
  Reading{remaining: U32, decoder: Enc.Utf8}

def read_chunk(data: Result<&1, &1, U32 & String, List<&2, U32>>, +size: U32,
  remaining: U32, state: Enc.Utf8) -> M.Checked(Reading):
  match data:
    case Fail{(_, why)}: Fail{why}
    case Done{bytes}:
      do M.Checked<Reading>:
        decoded : Enc.Utf8 <- strict_bytes(bytes, U32.to_nat(size), state)
        return Reading{(remaining - size : U32), decoded}

def read_chunk_pair(pair: File & Result<&1, &1, U32 & String, List<&2, U32>>,
  size: U32, remaining: U32, state: Enc.Utf8) -> File & M.Checked(Reading):
  (file, data) = pair
  (file, read_chunk(data, size, remaining, state))

# Keep only one 64 KiB byte chunk alongside the decoded text. The UTF-8
# continuation state crosses chunk boundaries; short reads fail atomically.
def read_chunks(fuel: Nat, +path: String, progress: File & M.Checked(Reading)) -> IO(String):
  match fuel progress:
    case _ Tuple{file, Fail{why}}:
      do IO<String>:
        File.close(file)
        IO.die(String, 1, path ++ ": " ++ why)
    case _ Tuple{file, Done{Reading{0, state}}}:
      do IO<String>:
        File.close(file)
        checked(String, path, strict_finish(state))
    case 0n Tuple{file, _}:
      do IO<String>:
        File.close(file)
        IO.die(String, 1, path ++ ": incomplete file read")
    case 1n+left Tuple{file, Done{Reading{+remaining, state}}}:
      do IO<String>:
        +size : U32 = U32.min(remaining, 65536)
        pair : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(file, size)
        read_chunks(left, path, read_chunk_pair(pair, size, remaining, state))

def read_sized(path: String, f: File, size: Result<&1, &1, U32 & String, U32>) -> IO(String):
  match size:
    case Fail{e}:
      do IO<String>:
        File.close(f)
        result(String, path, Fail{e})
    case Done{+n}:
      read_chunks(1n+U32.to_nat((n / 65536 : U32)), path,
        (f, Done{Reading{n, Enc.Utf8{0, 128, 191, 0, ""}}}))

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

def canonical(+path: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/usr/bin/realpath", ["-e", "--", path], "", 65536, 10000)
    response : U32 & (String & String) <- result(U32 & (String & String), path, r)
    path_output(path, response)

def executable_status(response: U32 & (String & String)) -> Bool:
  (status, _) = response
  U32.is_eq(status, 0)

def executable_info(info: Result<&1, &1, U32 & String, Fs.Info>, +path: String) -> IO(Bool):
  match info:
    case Done{Fs.Info{Fs.Regular{}, _, _}}:
      do IO<Bool>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/usr/bin/test", ["-x", path], "", 65536, 10000)
        response : U32 & (String & String) <- result(U32 & (String & String), path, r)
        return executable_status(response)
    case _: IO.pure(Bool, False{})

# Search PATH in Bend, preserving empty entries (the current directory), and
# pass literal arguments to the small OS utilities; no shell parses user paths.
def find_command(paths: Strings, +program: String) -> IO(String):
  match paths:
    case Nil{}: IO.die(String, 1, program ++ ": executable not found in PATH")
    case dir <> rest:
      do IO<String>:
        +path : String = Fs.path.join(dir, program)
        info : Result<&1, &1, U32 & String, Fs.Info> <- Fs.stat(path)
        found : Bool <- executable_info(info, path)
        next : (Unit -> IO(String)) = Bool.pick(Unit -> IO(String), found,
          _ => canonical(path), _ => find_command(rest, program))
        next(Unit{})

def search_path(env: Result<&1, &1, U32 & String, String>) -> Strings:
  match env:
    case Done{path}: String.split(path, ':')
    case Fail{_}: ["/usr/bin", "/bin"]

def resolve(path: String, locate_command: Bool) -> IO(String):
  match locate_command:
    case False{}: canonical(path)
    case True{}:
      do IO<String>:
        env : Result<&1, &1, U32 & String, String> <- IO.get_env("PATH")
        find_command(search_path(env), path)

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
