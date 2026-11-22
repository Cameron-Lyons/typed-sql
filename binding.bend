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

# Accumulate uses in reverse in constant time. Finalization validates shared
# names once, tightens nullability, and restores first-use binding order.
def parameter(fs: M.Fields, name: String, kind: M.SqlType, nullable: Bool) -> M.Checked(M.Fields):
  Done{M.Field{name, kind, nullable} <> fs}

def ParameterIndex() -> Data:
  Map<&2, Maybe<&2, M.Field>>

type Parameters is Data:
  Parameters{index: ParameterIndex, order: L.Tokens}

def merge_parameter(previous: Maybe<&2, M.Field>, +name: String, +kind: M.SqlType, nullable: Bool, index: ParameterIndex, order: L.Tokens) -> M.Checked(Parameters):
  match previous:
    case None{}:
      Done{Parameters{Map.set(&2, Maybe<&2, M.Field>, index, name, Some{M.Field{name, kind, nullable}}), name <> order}}
    case Some{M.Field{_, old_kind, old_null}}:
      do M.Checked<Parameters>:
        S.require(same_kind(old_kind, kind), "incompatible uses of parameter :" ++ name)
        return Parameters{Map.set(&2, Maybe<&2, M.Field>, index, name, Some{M.Field{name, kind, old_null && nullable}}), order}

def add_parameter(field: M.Field, state: Parameters) -> M.Checked(Parameters):
  M.Field{+name, kind, nullable} = field
  Parameters{+index, order} = state
  previous = Pair.snd(ParameterIndex, Maybe<&2, M.Field>, Map.get(Maybe<&2, M.Field>, None{}, index, name))
  merge_parameter(previous, name, kind, nullable, index, order)

def collect_parameters(uses: M.Fields, state: Parameters) -> M.Checked(Parameters):
  match uses:
    case Nil{}: Done{state}
    case f <> rest:
      do M.Checked<Parameters>:
        next : Parameters <- add_parameter(f, state)
        collect_parameters(rest, next)

def known_parameter(found: Maybe<&2, M.Field>) -> M.Checked(M.Field):
  match found:
    case Some{f}: Done{f}
    case None{}: Fail{"missing inferred parameter"}

def parameter_fields(order: L.Tokens, +index: ParameterIndex) -> M.Checked(M.Fields):
  match order:
    case Nil{}: Done{Nil{}}
    case name <> rest:
      found = Pair.snd(ParameterIndex, Maybe<&2, M.Field>, Map.get(Maybe<&2, M.Field>, None{}, index, name))
      do M.Checked<M.Fields>:
        field : M.Field <- known_parameter(found)
        tail : M.Fields <- parameter_fields(rest, index)
        return field <> tail

def finish_parameters(state: Parameters) -> M.Checked(M.Fields):
  Parameters{index, order} = state
  parameter_fields(List.reverse(&2, String, order), index)

def finalize_parameters(uses: M.Fields) -> M.Checked(M.Fields):
  do M.Checked<M.Fields>:
    state : Parameters <- collect_parameters(List.reverse(&2, M.Field, uses), Parameters{MTip{}, Nil{}})
    finish_parameters(state)

def integer_literal(s: String, negative: Bool) -> Bool:
  L.integer_literal(s, negative)

def literal(kind: M.SqlType, +value: String, negative: Bool) -> Bool:
  match kind:
    case M.SqlInt{}: integer_literal(value, negative)
    case M.SqlText{}: Bool.not(negative) && String.starts_with(value, "'")
    case M.SqlBool{}: Bool.not(negative) && (String.eq(value, "true") || String.eq(value, "false"))

def value_single(+raw: String, field: M.Field, params: M.Fields) -> M.Checked(M.Fields):
  match raw:
    case SCon{Chr{58}, +param}:
      M.Field{_, k, null} = field
      do M.Checked<M.Fields>:
        S.require(L.identifier(param), "invalid parameter name: " ++ param)
        parameter(params, param, k, null)
    case _:
      M.Field{+n, k, nullable} = field
      null = String.eq(raw, "null")
      do M.Checked<M.Fields>:
        S.require(Bool.pick(Bool, null, nullable, literal(k, raw, False{})), "expected a typed literal or :parameter for " ++ n)
        return params

def signed_value(raw: String, field: M.Field, negative: Bool, params: M.Fields) -> M.Checked(M.Fields):
  M.Field{n, kind, _} = field
  do M.Checked<M.Fields>:
    S.require(same_kind(kind, M.SqlInt{}) && integer_literal(raw, negative), "invalid signed integer for " ++ n)
    return params

def value_pair(+sign: String, raw: String, field: M.Field, params: M.Fields) -> M.Checked(M.Fields):
  do M.Checked<M.Fields>:
    S.require(String.eq(sign, "+") || String.eq(sign, "-"), "expected one literal or :parameter")
    signed_value(raw, field, String.eq(sign, "-"), params)

def value(tokens: L.Tokens, field: M.Field, params: M.Fields) -> M.Checked(M.Fields):
  match tokens:
    case [raw]: value_single(raw, field, params)
    case [sign, raw]: value_pair(sign, raw, field, params)
    case _: Fail{"expected one literal or :parameter"}

def lookup_value(+fields: M.Fields, name: String, tokens: L.Tokens, params: M.Fields) -> M.Checked(M.Fields):
  do M.Checked<M.Fields>:
    f : M.Field <- S.lookup(fields, name)
    value(tokens, f, params)

# The predicate checker is a single pass over the token stream. Parentheses,
# NOT, AND and OR stay in the emitted SQL so the database applies SQL precedence.
# States distinguish BETWEEN's AND and IN's parentheses from boolean syntax.
type PredicateMode is Data:
  Term{}
  Operator{field: M.Field}
  NegatedOperator{field: M.Field}
  Operand{field: M.Field, next: PredicateMode}
  SignedOperand{field: M.Field, negative: Bool, next: PredicateMode}
  NullTest{negated: Bool}
  InOpen{field: M.Field}
  InMore{field: M.Field}
  BetweenAnd{field: M.Field}
  Complete{}
  LikeEnd{}
  EscapeValue{}

def compatible_columns(field: M.Field, other: M.Field) -> M.Checked(Unit):
  M.Field{_, kind, _} = field
  M.Field{_, rhs, _} = other
  S.require(same_kind(kind, rhs), "incompatible column types in WHERE")

def comparison_value(+raw: String, +field: M.Field, fs: M.Fields, +params: M.Fields) -> M.Checked(M.Fields):
  use_column = L.identifier(raw) && Bool.not(List.contains(~String, ~String.eq, ["true", "false", "null"], raw))
  action = Bool.pick(Unit -> M.Checked(M.Fields), use_column,
    _ => do M.Checked<M.Fields>:
      other : M.Field <- S.lookup(fs, raw)
      compatible_columns(field, other)
      return params,
    _ => do M.Checked<M.Fields>:
      S.require(Bool.not(String.eq(raw, "null")), "compare NULL using IS [NOT] NULL")
      value([raw], field, params))
  action(Unit{})

def text_field(field: M.Field) -> M.Checked(Unit):
  M.Field{_, k, _} = field
  S.require(same_kind(k, M.SqlText{}), "LIKE requires a TEXT column")

def escape_character(raw: String) -> Bool:
  match raw:
    case "''''": True{}
    case SCon{Chr{39}, SCon{_, SCon{Chr{39}, SNil{}}}}: True{}
    case _: False{}

type PredicateState is Data:
  PredicateState{params: M.Fields, depth: Nat, mode: PredicateMode}

def predicate_term_tag(tag: Nat, raw: String, fs: M.Fields, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match tag:
    case 1n: Done{PredicateState{params, 1n+depth, Term{}}}
    case 2n: Done{PredicateState{params, depth, Term{}}}
    case _:
      do M.Checked<PredicateState>:
        field : M.Field <- S.lookup(fs, raw)
        return PredicateState{params, depth, Operator{field}}

def predicate_term(+raw: String, fs: M.Fields, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  tag = Bool.pick(Nat, String.eq(raw, "("), 1n, Bool.pick(Nat, String.eq(raw, "not"), 2n, 0n))
  predicate_term_tag(tag, raw, fs, params, depth)

def predicate_like(+field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  do M.Checked<PredicateState>:
    text_field(field)
    return PredicateState{params, depth, Operand{field, LikeEnd{}}}

def predicate_negated_tag(tag: Nat, +field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match tag:
    case 1n: Done{PredicateState{params, depth, InOpen{field}}}
    case 2n: Done{PredicateState{params, depth, Operand{field, BetweenAnd{field}}}}
    case 3n: predicate_like(field, params, depth)
    case _: Fail{"expected IN, BETWEEN, or LIKE after NOT"}

def predicate_negated(+raw: String, field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  tag = Bool.pick(Nat, String.eq(raw, "in"), 1n, Bool.pick(Nat, String.eq(raw, "between"), 2n, Bool.pick(Nat, String.eq(raw, "like"), 3n, 0n)))
  predicate_negated_tag(tag, field, params, depth)

def operator_kind(+raw: String) -> Nat:
  Bool.pick(Nat, String.eq(raw, "is"), 0n, Bool.pick(Nat, String.eq(raw, "not"), 1n, Bool.pick(Nat, String.eq(raw, "in"), 2n, Bool.pick(Nat, String.eq(raw, "between"), 3n, Bool.pick(Nat, String.eq(raw, "like"), 4n, 5n)))))

def predicate_operator_tag(tag: Nat, raw: String, +field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match tag:
    case 0n: Done{PredicateState{params, depth, NullTest{False{}}}}
    case 1n: Done{PredicateState{params, depth, NegatedOperator{field}}}
    case 2n: Done{PredicateState{params, depth, InOpen{field}}}
    case 3n: Done{PredicateState{params, depth, Operand{field, BetweenAnd{field}}}}
    case 4n: predicate_like(field, params, depth)
    case _:
      do M.Checked<PredicateState>:
        S.require(List.contains(~String, ~String.eq, ["=", "<>", "!=", "<", "<=", ">", ">="], raw), "unsupported WHERE operator")
        return PredicateState{params, depth, Operand{field, Complete{}}}

def predicate_operator(+raw: String, field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  predicate_operator_tag(operator_kind(raw), raw, field, params, depth)

def predicate_null_tag(tag: Nat, negated: Bool, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match tag:
    case 1n: Done{PredicateState{params, depth, Complete{}}}
    case 2n:
      do M.Checked<PredicateState>:
        S.require(Bool.not(negated), "expected NULL after IS NOT")
        return PredicateState{params, depth, NullTest{True{}}}
    case _: Fail{"expected [NOT] NULL after IS"}

def predicate_null(+raw: String, negated: Bool, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  tag = Bool.pick(Nat, String.eq(raw, "null"), 1n, Bool.pick(Nat, String.eq(raw, "not"), 2n, 0n))
  predicate_null_tag(tag, negated, params, depth)

def predicate_in(raw: String, +field: M.Field, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match raw:
    case ",": Done{PredicateState{params, depth, Operand{field, InMore{field}}}}
    case ")": Done{PredicateState{params, depth, Complete{}}}
    case _: Fail{"expected comma or closing parenthesis in IN"}

def predicate_operand(raw: String, field: M.Field, next: PredicateMode, fs: M.Fields, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match raw:
    case "+": Done{PredicateState{params, depth, SignedOperand{field, False{}, next}}}
    case "-": Done{PredicateState{params, depth, SignedOperand{field, True{}, next}}}
    case _:
      do M.Checked<PredicateState>:
        bound : M.Fields <- comparison_value(raw, field, fs, params)
        return PredicateState{bound, depth, next}

def predicate_close(depth: Nat, params: M.Fields) -> M.Checked(PredicateState):
  match depth:
    case 0n: Fail{"unexpected closing parenthesis in WHERE"}
    case 1n+n: Done{PredicateState{params, n, Complete{}}}

def predicate_boolean_tag(tag: Nat, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match tag:
    case 1n: Done{PredicateState{params, depth, Term{}}}
    case 2n: predicate_close(depth, params)
    case _: Fail{"expected AND, OR, or closing parenthesis in WHERE"}

def predicate_boolean(+raw: String, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  tag = Bool.pick(Nat, String.eq(raw, "and") || String.eq(raw, "or"), 1n,
    Bool.pick(Nat, String.eq(raw, ")"), 2n, 0n))
  predicate_boolean_tag(tag, params, depth)

def predicate_like_end_tag(escape: Bool, raw: String, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match escape:
    case True{}: Done{PredicateState{params, depth, EscapeValue{}}}
    case False{}: predicate_boolean(raw, params, depth)

def predicate_like_end(+raw: String, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  predicate_like_end_tag(String.eq(raw, "escape"), raw, params, depth)

# Dispatch on the parser state before matching token text. A combined match on
# tokens, depth and recursive states creates an enormous pattern decision tree.
def predicate_step(mode: PredicateMode, raw: String, fs: M.Fields, params: M.Fields, depth: Nat) -> M.Checked(PredicateState):
  match mode:
    case Term{}: predicate_term(raw, fs, params, depth)
    case Operator{field}: predicate_operator(raw, field, params, depth)
    case NegatedOperator{field}: predicate_negated(raw, field, params, depth)
    case Operand{field, next}: predicate_operand(raw, field, next, fs, params, depth)
    case SignedOperand{M.Field{_, kind, _}, negative, next}:
      do M.Checked<PredicateState>:
        S.require(same_kind(kind, M.SqlInt{}) && integer_literal(raw, negative), "expected signed integer literal in WHERE")
        return PredicateState{params, depth, next}
    case NullTest{negated}: predicate_null(raw, negated, params, depth)
    case InOpen{+field}:
      do M.Checked<PredicateState>:
        S.require(String.eq(raw, "("), "expected opening parenthesis after IN")
        return PredicateState{params, depth, Operand{field, InMore{field}}}
    case InMore{field}: predicate_in(raw, field, params, depth)
    case BetweenAnd{field}:
      do M.Checked<PredicateState>:
        S.require(String.eq(raw, "and"), "expected AND in BETWEEN")
        return PredicateState{params, depth, Operand{field, Complete{}}}
    case Complete{}: predicate_boolean(raw, params, depth)
    case LikeEnd{}: predicate_like_end(raw, params, depth)
    case EscapeValue{}:
      do M.Checked<PredicateState>:
        S.require(escape_character(raw), "ESCAPE requires a single-character string literal")
        return PredicateState{params, depth, Complete{}}

def predicate_complete(mode: PredicateMode) -> Bool:
  match mode:
    case Complete{}: True{}
    case LikeEnd{}: True{}
    case _: False{}

def predicate_finish(state: PredicateState) -> M.Checked(M.Fields):
  PredicateState{params, depth, mode} = state
  do M.Checked<M.Fields>:
    S.require(Nat.is_eq(depth, 0n) && predicate_complete(mode), "incomplete WHERE expression or unmatched parenthesis")
    return params

def predicate_tokens(ts: L.Tokens, +fs: M.Fields, state: PredicateState) -> M.Checked(M.Fields):
  match ts:
    case Nil{}: predicate_finish(state)
    case raw <> rest:
      PredicateState{params, depth, mode} = state
      do M.Checked<M.Fields>:
        next : PredicateState <- predicate_step(mode, raw, fs, params, depth)
        predicate_tokens(rest, fs, next)

def predicates(ts: L.Tokens, fs: M.Fields, params: M.Fields, depth: Nat, mode: PredicateMode) -> M.Checked(M.Fields):
  predicate_tokens(ts, fs, PredicateState{params, depth, mode})

def where_tail(ts: L.Tokens, fs: M.Fields, params: M.Fields) -> M.Checked(M.Fields):
  match ts:
    case Nil{}: Done{params}
    case +keyword <> rest:
      do M.Checked<M.Fields>:
        S.require(String.eq(keyword, "where"), "unsupported query clause: " ++ keyword)
        predicates(rest, fs, params, 0n, Term{})

# PostgreSQL otherwise infers the wire type of a repeated parameter from
# its first use, which may be an INT column even when another is BIGINT.
def placeholder(index: U32, kind: M.SqlType, sqlite: Bool) -> String:
  match kind sqlite:
    case _ True{}: "?" ++ U32.show(index)
    case M.SqlInt{} False{}: "$" ++ U32.show(index) ++ "::bigint"
    case _ False{}: "$" ++ U32.show(index)

def Slots() -> Data:
  Map<&2, String>

def index_slots(fs: M.Fields, +sqlite: Bool, +index: U32, slots: Slots) -> Slots:
  match fs:
    case Nil{}: slots
    case M.Field{name, kind, _} <> rest:
      index_slots(rest, sqlite, (index + 1 : U32), Map.set(&2, String, slots, name, placeholder(index, kind, sqlite)))

def sql_token(token: String, slots: Slots) -> String:
  match token:
    case SCon{Chr{58}, name}: Pair.snd(Slots, String, Map.get(String, "invalid_parameter", slots, name))
    case _: token

def sql_tokens(ts: L.Tokens, +slots: Slots) -> L.Tokens:
  match ts:
    case Nil{}: Nil{}
    case token <> rest: sql_token(token, slots) <> sql_tokens(rest, slots)

# Resolve each placeholder through one index instead of scanning the complete
# parameter list again at every use. String.join only copies each token once.
def sql(ts: L.Tokens, params: M.Fields, sqlite: Bool) -> String:
  String.join(sql_tokens(ts, index_slots(params, sqlite, 1, MTip{})), " ")
