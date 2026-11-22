import Base
import ../lexer.bend as L
import ../model.bend as M

def equal(a: L.Tokens, b: L.Tokens) -> Bool:
  match a b:
    case Nil{} Nil{}: True{}
    case x <> xs y <> ys: String.eq(x, y) && equal(xs, ys)
    case _ _: False{}

def assert(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, message)

def token_result(result: M.Checked(L.Tokens), expected: L.Tokens, source: String) -> IO(Unit):
  match result:
    case Done{actual}: assert(equal(actual, expected), "wrong tokens: " ++ String.quote(source))
    case Fail{why}: IO.die(Unit, 1, "rejected " ++ String.quote(source) ++ ": " ++ why)

def tokens(+source: String, expected: L.Tokens) -> IO(Unit):
  token_result(L.tokenize(source), expected, source)

def error_result(result: M.Checked(L.Tokens), expected: String, source: String) -> IO(Unit):
  match result:
    case Fail{+why}: assert(String.contains(why, expected), "wrong error for " ++ String.quote(source) ++ ": " ++ why)
    case Done{_}: IO.die(Unit, 1, "unexpectedly accepted " ++ String.quote(source))

def rejects(+source: String, expected: String) -> IO(Unit):
  error_result(L.tokenize(source), expected, source)

def nul_states(prefixes: L.Tokens) -> IO(Unit):
  match prefixes:
    case Nil{}: IO.pure(Unit, Unit{})
    case prefix <> rest:
      do IO<Unit>:
        rejects(prefix ++ SCon{Chr{0}, "x"}, "NUL in SQL")
        nul_states(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    tokens("", Nil{})
    tokens("SELECT ID, :Name FROM Books;", ["select", "id", ",", ":name", "from", "books", ";"])
    tokens("x/**/y--ignored", ["x", "y"])
    tokens("--", Nil{})
    tokens("---", Nil{})
    tokens("/*a**/x", ["x"])
    tokens("/**/*", ["*"])
    tokens("-- x\r\ny", ["y"])
    tokens("-- x\ny", ["y"])
    tokens("'don''t; -- /*'", ["'don''t; -- /*'"])
    tokens("'' '''' 'é🐈'", ["''", "''''", "'é🐈'"])
    tokens("'x'--comment", ["'x'"])
    tokens("'x'/*comment*/y", ["'x'", "y"])
    tokens("'a\rb\nc'", ["'a\rb\nc'"])
    tokens("- / < > !", ["-", "/", "<", ">", "!"])
    tokens("-", ["-"])
    tokens("/", ["/"])
    tokens("<", ["<"])
    tokens(">", [">"])
    tokens("!", ["!"])
    tokens("a-", ["a", "-"])
    tokens("a<=b>=c<>d!=e", ["a", "<=", "b", ">=", "c", "<>", "d", "!=", "e"])
    tokens("<<= >>= !!= -+ /-", ["<", "<=", ">", ">=", "!", "!=", "-", "+", "/", "-"])
    tokens(": :x ::a", [":", ":x", ":", ":a"])
    tokens(SCon{Chr{65279}, "SELECT x"}, ["select", "x"])
    tokens("x " ++ SCon{Chr{65279}, "y"}, ["x", SCon{Chr{65279}, ""}, "y"])
    rejects("'", "unterminated string")
    rejects("'''", "unterminated string")
    rejects("'x\\y'", "backslashes")
    rejects("/*", "unterminated block")
    rejects("/*x*", "unterminated block")
    rejects("/*x/", "unterminated block")
    rejects("/*/*/", "nested block")
    rejects("/*a//*x*/", "nested block")
    rejects("-- x\r", "LF or CRLF")
    rejects("-- x\ry", "LF or CRLF")
    nul_states(["", "x", "-", "/", "<", ">", "!", "'", "''", "--", "--\r", "/*", "/*/", "/**"])
    IO.print("lexer tests passed")
