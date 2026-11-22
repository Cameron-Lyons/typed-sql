import Base
import ../checker.bend as C
import ../model.bend as M
import ../binding.bend as B

def ensure(ok: Bool, label: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, label)

def unwrap(-A: Data, r: M.Checked(A)) -> IO(A):
  match r:
    case Fail{msg}: IO.die(A, 1, msg)
    case Done{x}: IO.pure(A, x)

def accept_queries(xs: List<&2, String>, +schema: M.Schema) -> IO(Unit):
  match xs:
    case Nil{}: IO.pure(Unit, Unit{})
    case source <> rest:
      do IO<Unit>:
        query : M.Query <- unwrap(M.Query, C.query(schema, "accepted", source))
        accept_queries(rest, schema)

def reject(r: M.Checked(M.Query), source: String) -> IO(Unit):
  match r:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, "unexpectedly accepted: " ++ source)

def reject_queries(xs: List<&2, String>, +schema: M.Schema) -> IO(Unit):
  match xs:
    case Nil{}: IO.pure(Unit, Unit{})
    case +source <> rest:
      do IO<Unit>:
        reject(C.query(schema, "rejected", source), source)
        reject_queries(rest, schema)

def fields_equal(a: M.Fields, b: M.Fields) -> Bool:
  match a b:
    case Nil{} Nil{}: True{}
    case M.Field{an, ak, az} <> at M.Field{bn, bk, bz} <> bt:
      String.eq(an, bn) && B.same_kind(ak, bk) && Bool.not(Bool.xor(az, bz)) && fields_equal(at, bt)
    case _ _: False{}

def names_equal(a: List<&2, String>, b: List<&2, String>) -> Bool:
  match a b:
    case Nil{} Nil{}: True{}
    case an <> at bn <> bt: String.eq(an, bn) && names_equal(at, bt)
    case _ _: False{}

def bound_query(q: M.Query) -> IO(Unit):
  M.Query{_, +sqlite, pg, params, columns, bounds} = q
  do IO<Unit>:
    ensure(fields_equal(params, [M.Field{"lo", M.SqlInt{}, False{}}, M.Field{"hi", M.SqlInt{}, False{}}, M.Field{"pattern", M.SqlText{}, True{}}, M.Field{"skip", M.SqlInt{}, False{}}]), "wrong predicate or pagination parameters")
    ensure(fields_equal(columns, [M.Field{"number", M.SqlInt{}, False{}}]), "wrong bounded result fields")
    ensure(names_equal(bounds, ["hi", "skip"]), "wrong bound validation metadata")
    ensure(String.starts_with(sqlite, "select distinct "), "DISTINCT was dropped")
    ensure(String.contains(sqlite, "where not ( id between ?1 and ?2 or memo like ?3 escape '~' ) and id in ( ?1 , ?2 , + 3 )"), "SQLite predicate structure changed")
    ensure(String.ends_with(sqlite, "order by \"items\".\"id\" asc nulls last limit ?2 offset ?4"), "SQLite pagination bindings")
    ensure(String.ends_with(pg, "order by \"items\".\"id\" asc nulls last limit $2::bigint offset $4::bigint"), "PostgreSQL pagination bindings")

def inserted_query(q: M.Query) -> IO(Unit):
  M.Query{_, +sqlite, pg, params, columns, bounds} = q
  do IO<Unit>:
    ensure(fields_equal(params, [M.Field{"first", M.SqlInt{}, False{}}, M.Field{"memo", M.SqlText{}, True{}}, M.Field{"second", M.SqlInt{}, False{}}]), "wrong multi-row INSERT parameters")
    ensure(fields_equal(columns, [M.Field{"id", M.SqlInt{}, False{}}]), "wrong multi-row INSERT result fields")
    ensure(List.is_empty(&2, String, bounds), "unexpected INSERT bounds")
    ensure(String.contains(sqlite, "values ( ?1 , ?2 , true ) , ( ?3 , ?2 , false ) returning"), "SQLite multi-row bindings")
    ensure(String.contains(pg, "values ( $1::bigint , $2 , true ) , ( $3::bigint , $2 , false ) returning"), "PostgreSQL multi-row bindings")

def main() -> IO(Unit):
  do IO<Unit>:
    # Schema parsing has its own suite; keep this fixture focused on query plans.
    +s : M.Schema = [
      M.Table{"items", [M.Field{"id", M.SqlInt{}, False{}}, M.Field{"memo", M.SqlText{}, True{}}, M.Field{"active", M.SqlBool{}, False{}}], Nil{}, [["id"]]},
      M.Table{"notes", [M.Field{"memo", M.SqlText{}, False{}}, M.Field{"active", M.SqlBool{}, True{}}], ["memo", "active"], Nil{}}
    ]
    bounded : M.Query <- unwrap(M.Query, C.query(s, "bounded", "SELECT DISTINCT id AS number FROM items WHERE NOT (id BETWEEN :lo AND :hi OR memo LIKE :pattern ESCAPE '~') AND id IN (:lo, :hi, +3) ORDER BY number LIMIT :hi OFFSET :skip"))
    bound_query(bounded)
    inserted : M.Query <- unwrap(M.Query, C.query(s, "batch", "INSERT INTO items (id, memo, active) VALUES (:first, :memo, TRUE), (:second, :memo, FALSE) RETURNING id"))
    inserted_query(inserted)
    accept_queries([
      "SELECT ALL * FROM items WHERE ((id = 1)) OR NOT NOT (memo IS NULL AND active = TRUE)",
      "SELECT * FROM items WHERE id NOT IN (1, 2, -3) AND id NOT BETWEEN -9 AND +9",
      "SELECT * FROM items WHERE memo NOT LIKE 'x%' ESCAPE '~'",
      "SELECT * FROM items WHERE memo LIKE 'x%' ESCAPE '''' AND id = id",
      "SELECT * FROM items WHERE memo LIKE memo OR memo IS NOT NULL",
      "SELECT * FROM items WHERE memo BETWEEN 'a' AND 'z' AND active IN (TRUE, FALSE)",
      "SELECT * FROM items WHERE id = id AND memo = memo AND active = active",
      "SELECT DISTINCT id, memo AS note FROM items ORDER BY id DESC, note LIMIT :count",
      "SELECT DISTINCT * FROM items ORDER BY active LIMIT 0 OFFSET :skip",
      "SELECT id FROM items WHERE id = :same LIMIT :same OFFSET :same",
      "UPDATE items SET active = :enabled WHERE (id IN (:a, :b) OR id >= :a) AND NOT memo IS NULL RETURNING id",
      "DELETE FROM items WHERE id BETWEEN :lo AND :hi OR (active = FALSE AND memo NOT LIKE :pattern)",
      "INSERT INTO notes (active) VALUES (TRUE), (FALSE), (NULL) RETURNING memo",
      "INSERT INTO notes DEFAULT VALUES RETURNING *"
    ], s)
    reject_queries([
      "SELECT * FROM items WHERE ()", "SELECT * FROM items WHERE (id = 1",
      "SELECT * FROM items WHERE id = 1)", "SELECT * FROM items WHERE id = 1 OR",
      "SELECT * FROM items WHERE AND id = 1", "SELECT * FROM items WHERE NOT",
      "SELECT * FROM items WHERE id = 1 NOT", "SELECT * FROM items WHERE (NOT)",
      "SELECT * FROM items WHERE id IN ()", "SELECT * FROM items WHERE id IN (1,)",
      "SELECT * FROM items WHERE id IN (,1)", "SELECT * FROM items WHERE id IN (1 2)",
      "SELECT * FROM items WHERE id IN ((1))", "SELECT * FROM items WHERE id IN (1, 'text')",
      "SELECT * FROM items WHERE id IN (NULL)", "SELECT * FROM items WHERE id IN (SELECT id FROM items)",
      "SELECT * FROM items WHERE id BETWEEN 1 OR 2", "SELECT * FROM items WHERE id BETWEEN 1 AND",
      "SELECT * FROM items WHERE id BETWEEN :shared AND :shared OR memo = :shared",
      "SELECT * FROM items WHERE id = memo", "SELECT * FROM items WHERE id = absent",
      "SELECT * FROM items WHERE id LIKE '1'", "SELECT * FROM items WHERE memo LIKE 1",
      "SELECT * FROM items WHERE memo NOT = 'x'", "SELECT * FROM items WHERE id IS TRUE",
      "SELECT * FROM items WHERE memo LIKE '%' ESCAPE ''", "SELECT * FROM items WHERE memo LIKE '%' ESCAPE 'ab'",
      "SELECT * FROM items WHERE memo LIKE '%' ESCAPE :escape", "SELECT * FROM items WHERE memo = 'a' ESCAPE '~'",
      "SELECT * FROM items WHERE id = +TRUE", "SELECT * FROM items WHERE id = --3",
      "SELECT * FROM items WHERE id = 9223372036854775808", "SELECT * FROM items WHERE id = -9223372036854775809",
      "SELECT DISTINCT memo FROM items ORDER BY id", "SELECT DISTINCT FROM items",
      "SELECT DISTINCT ALL * FROM items", "SELECT DISTINCT ON (id) id FROM items",
      "SELECT id FROM items WHERE memo = :count LIMIT :count", "SELECT id FROM items LIMIT :",
      "SELECT id FROM items LIMIT :count + 1", "SELECT id FROM items LIMIT -1", "SELECT id FROM items LIMIT 1 OFFSET -1",
      "INSERT INTO items (id, active) VALUES (1, TRUE), (2)", "INSERT INTO items (id, active) VALUES (1, TRUE),",
      "INSERT INTO items (id, active) VALUES (1, TRUE), (2, 'true')", "INSERT INTO items (active) VALUES (TRUE), (FALSE)",
      "INSERT INTO items (id, active) VALUES ((1), TRUE)", "INSERT INTO items (id, id, active) VALUES (1, 2, TRUE)",
      "INSERT INTO items (id, active) VALUES", "INSERT INTO items DEFAULT VALUES",
      "INSERT INTO notes DEFAULT VALUES, DEFAULT VALUES"
    ], s)
    IO.print("query feature tests passed")
