import Base

type SqlType is Data:
  SqlInt{}
  SqlText{}
  SqlBool{}

type Field is Data:
  Field{name: String, kind: SqlType, nullable: Bool}

def Fields() -> Data:
  List<&2, Field>

type Table is Data:
  Table{name: String, fields: Fields}

def Schema() -> Data:
  List<&2, Table>

type Query is Data:
  Query{name: String, sqlite_sql: String, postgres_sql: String, params: Fields, columns: Fields}

def Checked(-A: Data) -> Data:
  Result<&2, &2, String, A>

def Checked.pure(-A: Data, x: A) -> Checked(A):
  Done{x}

def Checked.bind(-A: Data, -B: Data, r: Checked(A), f: A -> Checked(B)) -> Checked(B):
  match r:
    case Done{x}: f(x)
    case Fail{msg}: Fail{msg}
