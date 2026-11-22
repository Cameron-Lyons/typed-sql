import Base
import ./model.bend as M
import ./lexer.bend as L
import ./schema.bend as S

def same_kind(a: M.SqlType, b: M.SqlType) -> Bool:
  match a b:
    case M.SqlInt{} M.SqlInt{}: True{}
    case M.SqlBool{} M.SqlBool{}: True{}
    case M.SqlText{} M.SqlText{}: True{}
    case _ _: False{}

# Repeated parameter names share one slot. A non-null use anywhere makes the
# parameter required, and all uses must agree on the underlying SQL type.
def parameter(fs: M.Fields, +name: String, +kind: M.SqlType, +nullable: Bool) -> M.Checked(M.Fields):
  match fs:
    case Nil{}: Done{[M.Field{name, kind, nullable}]}
    case M.Field{+n, +k, +null} <> +t:
      action = Bool.pick(Unit -> M.Checked(M.Fields), String.eq(n, name),
        _ => do M.Checked<M.Fields>:
          S.require(same_kind(k, kind), "incompatible uses of parameter :" ++ name)
          return M.Field{n, k, null && nullable} <> t,
        _ => do M.Checked<M.Fields>:
          rest : M.Fields <- parameter(t, name, kind, nullable)
          return M.Field{n, k, null} <> rest)
      action(Unit{})

def digits(s: String) -> Bool:
  match s:
    case SNil{}: True{}
    case SCon{c, t}: Char.is_digit(c) && digits(t)

def integer_literal(+s: String, negative: Bool) -> Bool:
  +n = String.length(s)
  limit = Bool.pick(String, negative, "9223372036854775808", "9223372036854775807")
  Bool.not(String.is_empty(s)) && digits(s) && (Nat.is_lt(n, 19n) || (Nat.is_eq(n, 19n) && String.is_le(s, limit)))

def literal(kind: M.SqlType, +value: String, negative: Bool) -> Bool:
  match kind:
    case M.SqlInt{}: integer_literal(value, negative)
    case M.SqlText{}: Bool.not(negative) && String.starts_with(value, "'")
    case M.SqlBool{}: Bool.not(negative) && (String.eq(value, "true") || String.eq(value, "false"))

def value(tokens: L.Tokens, field: M.Field, params: M.Fields) -> M.Checked(M.Fields):
  match tokens field:
    case SCon{Chr{58}, +param} <> Nil{} M.Field{_, k, null}:
      do M.Checked<M.Fields>:
        S.require(L.identifier(param), "invalid parameter name: " ++ param)
        parameter(params, param, k, null)
    case "null" <> Nil{} M.Field{n, _, nullable}:
      do M.Checked<M.Fields>:
        S.require(nullable, "NULL is not allowed for " ++ n)
        return params
    case raw <> Nil{} M.Field{n, k, _}:
      do M.Checked<M.Fields>:
        S.require(literal(k, raw, False{}), "expected a typed literal or :parameter for " ++ n)
        return params
    case "-" <> raw <> Nil{} M.Field{n, k, _}:
      do M.Checked<M.Fields>:
        S.require(literal(k, raw, True{}), "invalid negative literal for " ++ n)
        return params
    case _ _: Fail{"expected one literal or :parameter"}

def lookup_value(+fields: M.Fields, name: String, tokens: L.Tokens, params: M.Fields) -> M.Checked(M.Fields):
  do M.Checked<M.Fields>:
    f : M.Field <- S.lookup(fields, name)
    value(tokens, f, params)

def predicate(ts: L.Tokens, fs: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match ts:
    case col <> "is" <> "null" <> Nil{}:
      do M.Checked<M.Fields>:
        f : M.Field <- S.lookup(fs, col)
        return params
    case col <> "is" <> "not" <> "null" <> Nil{}:
      do M.Checked<M.Fields>:
        f : M.Field <- S.lookup(fs, col)
        return params
    case col <> op <> +rest:
      do M.Checked<M.Fields>:
        S.require(List.contains(~String, ~String.eq, ["=", "<>", "!=", "<", "<=", ">", ">="], op), "unsupported WHERE operator")
        S.require(Bool.not(List.contains(~String, ~String.eq, rest, "null")), "compare NULL using IS [NOT] NULL")
        lookup_value(fs, col, rest, params)
    case _: Fail{"expected a column comparison in WHERE"}

def predicates(conditions: L.Groups, +fs: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match conditions:
    case Nil{}: Done{params}
    case p <> t:
      do M.Checked<M.Fields>:
        next : M.Fields <- predicate(p, fs, params)
        predicates(t, fs, next)

def where_tail(ts: L.Tokens, fs: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match ts:
    case Nil{}: Done{params}
    case "where" <> rest: predicates(L.chunks(rest, "and"), fs, params)
    case h <> _: Fail{"unsupported query clause: " ++ h}

# PostgreSQL otherwise infers the wire type of a repeated parameter from
# its first use, which may be an INT column even when another is BIGINT.
def placeholder(index: U32, kind: M.SqlType, sqlite: Bool) -> String:
  match kind sqlite:
    case _ True{}: "?" ++ U32.show(index)
    case M.SqlInt{} False{}: "$" ++ U32.show(index) ++ "::bigint"
    case _ False{}: "$" ++ U32.show(index)

def slot(fs: M.Fields, +name: String, +index: U32, +sqlite: Bool) -> String:
  match fs:
    case Nil{}: "invalid_parameter"
    case M.Field{n, k, _} <> t:
      choose = Bool.pick(Unit -> String, String.eq(n, name), _ => placeholder(index, k, sqlite), _ => slot(t, name, (index + 1 : U32), sqlite))
      choose(Unit{})

def sql_token(+token: String, +params: M.Fields, sqlite: Bool) -> String:
  match token:
    case SCon{Chr{58}, name}: slot(params, name, 1, sqlite)
    case _: token

def sql(ts: L.Tokens, +params: M.Fields, +sqlite: Bool) -> String:
  match ts:
    case Nil{}: ""
    case h <> Nil{}: sql_token(h, params, sqlite)
    case h <> t: sql_token(h, params, sqlite) ++ " " ++ sql(t, params, sqlite)
