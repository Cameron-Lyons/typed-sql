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

def flush(buf: String, acc: Tokens) -> Tokens:
  match buf:
    case SNil{}: acc
    case SCon{c, t}: String.reverse(SCon{c, t}) <> acc

type Mode is Data:
  Normal{word: String}
  Literal{reversed: String}
  LineComment{}
  BlockComment{}

def ordinary_tokens(c: Char, buf: String, acc: Tokens, space: Bool, part: Bool) -> Tokens:
  match space part:
    case True{} _: flush(buf, acc)
    case _ True{}: acc
    case _ _: SCon{c, ""} <> flush(buf, acc)

def scan(s: String, mode: Mode, acc: Tokens) -> M.Checked(Tokens):
  match s mode:
    case SNil{} Literal{_}: Fail{"unterminated string literal"}
    case SNil{} BlockComment{}: Fail{"unterminated block comment"}
    case SNil{} Normal{buf}: Done{List.reverse(&2, String, flush(buf, acc))}
    case SNil{} LineComment{}: Done{List.reverse(&2, String, acc)}
    case SCon{Chr{0}, _} _: Fail{"NUL in SQL"}
    case SCon{Chr{45}, SCon{Chr{45}, t}} Normal{buf}: scan(t, LineComment{}, flush(buf, acc))
    case SCon{Chr{47}, SCon{Chr{42}, t}} Normal{buf}: scan(t, BlockComment{}, flush(buf, acc))
    case SCon{Chr{47}, SCon{Chr{42}, _}} BlockComment{}: Fail{"nested block comments are not portable"}
    case SCon{Chr{42}, SCon{Chr{47}, t}} BlockComment{}: scan(t, Normal{""}, acc)
    case SCon{Chr{13}, SCon{Chr{10}, t}} LineComment{}: scan(t, Normal{""}, acc)
    case SCon{Chr{13}, _} LineComment{}: Fail{"use LF or CRLF to end a SQL line comment"}
    case SCon{Chr{10}, t} LineComment{}: scan(t, Normal{""}, acc)
    case SCon{_, t} LineComment{}: scan(t, LineComment{}, acc)
    case SCon{_, t} BlockComment{}: scan(t, BlockComment{}, acc)
    case SCon{Chr{39}, t} Normal{buf}: scan(t, Literal{"'"}, flush(buf, acc))
    case SCon{Chr{39}, SCon{Chr{39}, t}} Literal{buf}: scan(t, Literal{"''" ++ buf}, acc)
    case SCon{Chr{39}, t} Literal{buf}: scan(t, Normal{""}, String.reverse("'" ++ buf) <> acc)
    case SCon{Chr{92}, _} Literal{_}: Fail{"backslashes in string literals are not supported; use a parameter"}
    case SCon{c, t} Literal{buf}: scan(t, Literal{SCon{c, buf}}, acc)
    case SCon{Chr{58}, t} Normal{buf}: scan(t, Normal{":"}, flush(buf, acc))
    case SCon{Chr{60}, SCon{Chr{61}, t}} Normal{buf}: scan(t, Normal{""}, "<=" <> flush(buf, acc))
    case SCon{Chr{62}, SCon{Chr{61}, t}} Normal{buf}: scan(t, Normal{""}, ">=" <> flush(buf, acc))
    case SCon{Chr{60}, SCon{Chr{62}, t}} Normal{buf}: scan(t, Normal{""}, "<>" <> flush(buf, acc))
    case SCon{Chr{33}, SCon{Chr{61}, t}} Normal{buf}: scan(t, Normal{""}, "!=" <> flush(buf, acc))
    case SCon{+c, t} Normal{+buf}:
      +part = word_char(c)
      next = Bool.pick(String, part, SCon{Char.to_lower(c), buf}, "")
      scan(t, Normal{next}, ordinary_tokens(c, buf, acc, Char.is_space(c), part))

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
