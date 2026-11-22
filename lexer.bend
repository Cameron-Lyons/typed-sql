import Base
import ./model.bend as M

def Tokens() -> Data:
  List<&2, String>

def Groups() -> Data:
  List<&2, Tokens>

def letter(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_eq(c, Chr{95})

def word_char(+c: Char) -> Bool:
  letter(c) || Char.is_digit(c)

def identifier_tail(s: String, remaining: Nat) -> Bool:
  match s remaining:
    case SNil{} _: True{}
    case SCon{_, _} 0n: False{}
    case SCon{c, t} 1n+n: word_char(c) && identifier_tail(t, n)

def identifier(s: String) -> Bool:
  match s:
    case SNil{}: False{}
    case SCon{c, t}: letter(c) && identifier_tail(t, 62n)

def digits(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{c, t}: Char.is_digit(c) && digits(t)

def significant(s: String) -> String:
  match s:
    case SCon{Chr{48}, t}: significant(t)
    case _: s

def integer_literal(+s: String, negative: Bool) -> Bool:
  +magnitude = significant(s)
  +n = String.length(magnitude)
  limit = Bool.pick(String, negative, "9223372036854775808", "9223372036854775807")
  Bool.not(String.is_empty(s)) && digits(magnitude) && (Nat.is_lt(n, 19n) || (Nat.is_eq(n, 19n) && String.is_le(magnitude, limit)))

def flush(buf: String, acc: Tokens) -> Tokens:
  match buf:
    case SNil{}: acc
    case SCon{c, t}: String.reverse(SCon{c, t}) <> acc

type Mode is Data:
  Normal{word: String}
  Literal{reversed: String}
  LiteralQuote{reversed: String}
  Pending{first: Char}
  LineComment{}
  LineCR{}
  BlockComment{}
  BlockSlash{}
  BlockStar{}

def ordinary_tokens(c: Char, buf: String, acc: Tokens, space: Bool, part: Bool) -> Tokens:
  match space part:
    case True{} _: flush(buf, acc)
    case _ True{}: acc
    case _ _: SCon{c, ""} <> flush(buf, acc)

type ScanState is Data:
  ScanState{mode: Mode, tokens: Tokens}

def normal_kind(+c: Char) -> Nat:
  pending = Char.is_eq(c, '-') || Char.is_eq(c, '/') || Char.is_eq(c, '<') || Char.is_eq(c, '>') || Char.is_eq(c, '!')
  Bool.pick(Nat, Char.is_eq(c, Chr{39}), 1n,
    Bool.pick(Nat, Char.is_eq(c, ':'), 2n, Bool.pick(Nat, pending, 3n, 0n)))

def normal_case(kind: Nat, +c: Char, +buf: String, acc: Tokens) -> M.Checked(ScanState):
  match kind:
    case 1n: Done{ScanState{Literal{"'"}, flush(buf, acc)}}
    case 2n: Done{ScanState{Normal{":"}, flush(buf, acc)}}
    case 3n: Done{ScanState{Pending{c}, flush(buf, acc)}}
    case _:
      +part = word_char(c)
      next = Bool.pick(String, part, SCon{Char.to_lower(c), buf}, "")
      Done{ScanState{Normal{next}, ordinary_tokens(c, buf, acc, Char.is_space(c), part)}}

def normal_char(+c: Char, buf: String, acc: Tokens) -> M.Checked(ScanState):
  normal_case(normal_kind(c), c, buf, acc)

def pending_case(kind: Nat, first: Char, c: Char, acc: Tokens) -> M.Checked(ScanState):
  match kind:
    case 1n: Done{ScanState{LineComment{}, acc}}
    case 2n: Done{ScanState{BlockComment{}, acc}}
    case 3n: Done{ScanState{Normal{""}, SCon{first, SCon{c, ""}} <> acc}}
    case _: normal_char(c, "", SCon{first, ""} <> acc)

def pending_char(+first: Char, +c: Char, acc: Tokens) -> M.Checked(ScanState):
  line = Char.is_eq(first, '-') && Char.is_eq(c, '-')
  block = Char.is_eq(first, '/') && Char.is_eq(c, '*')
  pair = (Char.is_eq(first, '<') && (Char.is_eq(c, '=') || Char.is_eq(c, '>'))) || ((Char.is_eq(first, '>') || Char.is_eq(first, '!')) && Char.is_eq(c, '='))
  kind = Bool.pick(Nat, line, 1n, Bool.pick(Nat, block, 2n, Bool.pick(Nat, pair, 3n, 0n)))
  pending_case(kind, first, c, acc)

def literal_case(kind: Nat, c: Char, buf: String, acc: Tokens) -> M.Checked(ScanState):
  match kind:
    case 1n: Done{ScanState{LiteralQuote{SCon{c, buf}}, acc}}
    case 2n: Fail{"backslashes in string literals are not supported; use a parameter"}
    case _: Done{ScanState{Literal{SCon{c, buf}}, acc}}

def literal_char(+c: Char, buf: String, acc: Tokens) -> M.Checked(ScanState):
  kind = Bool.pick(Nat, Char.is_eq(c, Chr{39}), 1n, Bool.pick(Nat, Char.is_eq(c, Chr{92}), 2n, 0n))
  literal_case(kind, c, buf, acc)

def literal_quote(doubled: Bool, c: Char, buf: String, acc: Tokens) -> M.Checked(ScanState):
  match doubled:
    case True{}: Done{ScanState{Literal{SCon{c, buf}}, acc}}
    case False{}: normal_char(c, "", String.reverse(buf) <> acc)

def line_char(+c: Char, acc: Tokens) -> M.Checked(ScanState):
  mode = Bool.pick(Mode, Char.is_eq(c, Chr{10}), Normal{""},
    Bool.pick(Mode, Char.is_eq(c, Chr{13}), LineCR{}, LineComment{}))
  Done{ScanState{mode, acc}}

def line_cr(newline: Bool, acc: Tokens) -> M.Checked(ScanState):
  match newline:
    case True{}: Done{ScanState{Normal{""}, acc}}
    case False{}: Fail{"use LF or CRLF to end a SQL line comment"}

def block_char(+c: Char, acc: Tokens) -> M.Checked(ScanState):
  mode = Bool.pick(Mode, Char.is_eq(c, '*'), BlockStar{},
    Bool.pick(Mode, Char.is_eq(c, '/'), BlockSlash{}, BlockComment{}))
  Done{ScanState{mode, acc}}

def block_slash(nested: Bool, c: Char, acc: Tokens) -> M.Checked(ScanState):
  match nested:
    case True{}: Fail{"nested block comments are not portable"}
    case False{}: block_char(c, acc)

def block_star(closed: Bool, c: Char, acc: Tokens) -> M.Checked(ScanState):
  match closed:
    case True{}: Done{ScanState{Normal{""}, acc}}
    case False{}: block_char(c, acc)

# Carry one pending character in the state instead of matching nested source
# strings against all modes. Every step consumes exactly one source character.
def scan_step(mode: Mode, +c: Char, acc: Tokens) -> M.Checked(ScanState):
  match mode:
    case Normal{buf}: normal_char(c, buf, acc)
    case Pending{first}: pending_char(first, c, acc)
    case Literal{buf}: literal_char(c, buf, acc)
    case LiteralQuote{buf}: literal_quote(Char.is_eq(c, Chr{39}), c, buf, acc)
    case LineComment{}: line_char(c, acc)
    case LineCR{}: line_cr(Char.is_eq(c, Chr{10}), acc)
    case BlockComment{}: block_char(c, acc)
    case BlockSlash{}: block_slash(Char.is_eq(c, '*'), c, acc)
    case BlockStar{}: block_star(Char.is_eq(c, '/'), c, acc)

def scan_nonzero(nul: Bool, c: Char, state: ScanState) -> M.Checked(ScanState):
  match nul:
    case True{}: Fail{"NUL in SQL"}
    case False{}:
      ScanState{mode, acc} = state
      scan_step(mode, c, acc)

def scan_finish(mode: Mode, acc: Tokens) -> M.Checked(Tokens):
  match mode:
    case Normal{buf}: Done{List.reverse(&2, String, flush(buf, acc))}
    case Pending{first}: Done{List.reverse(&2, String, SCon{first, ""} <> acc)}
    case LiteralQuote{buf}: Done{List.reverse(&2, String, String.reverse(buf) <> acc)}
    case Literal{_}: Fail{"unterminated string literal"}
    case LineComment{}: Done{List.reverse(&2, String, acc)}
    case LineCR{}: Fail{"use LF or CRLF to end a SQL line comment"}
    case _: Fail{"unterminated block comment"}

def scan_done(state: ScanState) -> M.Checked(Tokens):
  ScanState{mode, acc} = state
  scan_finish(mode, acc)

def scan_chars(s: String, state: ScanState) -> M.Checked(Tokens):
  match s:
    case SNil{}: scan_done(state)
    case SCon{+c, tail}:
      do M.Checked<Tokens>:
        next : ScanState <- scan_nonzero(Char.is_eq(c, Chr{0}), c, state)
        scan_chars(tail, next)

def scan(s: String, mode: Mode, acc: Tokens) -> M.Checked(Tokens):
  scan_chars(s, ScanState{mode, acc})

def tokenize(sql: String) -> M.Checked(Tokens):
  match sql:
    case SCon{Chr{65279}, t}: scan(t, Normal{""}, Nil{})
    case _: scan(sql, Normal{""}, Nil{})

type Split is Data:
  Split{before: Tokens, after: Tokens, found: Bool}

def split_at(ts: Tokens, +sep: String, +acc: Tokens) -> Split:
  match ts:
    case Nil{}: Split{List.reverse(&2, String, acc), Nil{}, False{}}
    case +h <> +t:
      next = Bool.pick(Unit -> Split, String.eq(h, sep),
        _ => Split{List.reverse(&2, String, acc), t, True{}},
        _ => split_at(t, sep, h <> acc))
      next(Unit{})

def groups(ts: Tokens, +sep: String, +acc: Tokens, +parts: Groups) -> Groups:
  match ts:
    case Nil{}: List.reverse(&2, Tokens, List.reverse(&2, String, acc) <> parts)
    case +h <> +t:
      next = Bool.pick(Unit -> Groups, String.eq(h, sep),
        _ => groups(t, sep, Nil{}, List.reverse(&2, String, acc) <> parts),
        _ => groups(t, sep, h <> acc, parts))
      next(Unit{})

def chunks(ts: Tokens, sep: String) -> Groups:
  groups(ts, sep, Nil{}, Nil{})

# Split only at the current nesting level, rejecting unmatched parentheses.
# Literal tokens are opaque, so punctuation inside a string is never a delimiter.
def balanced_groups(ts: Tokens, +sep: String, depth: Nat, +acc: Tokens, +parts: Groups) -> M.Checked(Groups):
  match ts depth:
    case Nil{} 0n: Done{List.reverse(&2, Tokens, List.reverse(&2, String, acc) <> parts)}
    case Nil{} _: Fail{"unclosed parenthesis"}
    case "(" <> t n: balanced_groups(t, sep, 1n+n, "(" <> acc, parts)
    case ")" <> _ 0n: Fail{"unexpected closing parenthesis"}
    case ")" <> t 1n+n: balanced_groups(t, sep, n, ")" <> acc, parts)
    case +h <> +t +n:
      next = Bool.pick(Unit -> M.Checked(Groups), Nat.is_eq(n, 0n) && String.eq(h, sep),
        _ => balanced_groups(t, sep, n, Nil{}, List.reverse(&2, String, acc) <> parts),
        _ => balanced_groups(t, sep, n, h <> acc, parts))
      next(Unit{})

def balanced_chunks(ts: Tokens, sep: String) -> M.Checked(Groups):
  balanced_groups(ts, sep, 0n, Nil{}, Nil{})
