# Typed SQL for Bend

Turn a directory of SQL queries into typed Bend functions for SQLite and PostgreSQL. The checker reads a SQL schema offline. The migration runner applies numbered SQL files to a live database.

The checker, generator, CLI, runtime adapters and migration runner are written in Bend 2. The adapters use bend-kit's prepared-statement drivers. SQLite needs the system SQLite library. PostgreSQL uses bend-kit's client over TCP. Tested with Bend 2.0.40. [bend-kit](https://github.com/paymog/bend-kit)

## Try it with SQLite

Run these commands from this folder. The example uses its first migration as the schema and its second migration to seed a book.

```sh
bend main.bend -o typed-sql
./typed-sql check examples/migrations/001_books.sql examples/queries
./typed-sql generate examples/migrations/001_books.sql examples/queries examples/queries.bend
./typed-sql migrate sqlite catalog.db examples/migrations
bend examples/catalog.bend catalog.db "Invisible Cities"
```

The example prints the book's title, author and print status. Running the migration command again reports `Applied 0 migrations.` You can also invoke any CLI command directly with `bend main.bend`.

## Write a query

Give each query its own `.sql` file. The filename supplies the function name. For example, `find_book.sql` contains this query.

```sql
SELECT title, author, in_print FROM books WHERE title = :title;
```

Its generated interface is shown below. A caller passes an open SQLite or PostgreSQL session and a Bend string. Both drivers bind the parameter separately from the SQL.

```bend
type Row_find_book is Data:
  Row_find_book{col_title: String, col_author: Maybe<&2, String>, col_in_print: Bool}

def q_find_book(db: R.Db, p_title: String) -> IO(R.Outcome<List<&2, Row_find_book>>):
  # Generated implementation in examples/queries.bend
```

A successful call returns `R.Good{db, value}`. Pass the returned session to the next call or close it with `R.close`. A database or decoding error returns `R.Bad{db, message}`. A lost PostgreSQL connection returns `R.Disconnected{message}`. See the complete [Bend caller](examples/catalog.bend).

| SQL column | Generated Bend value |
| --- | --- |
| `BIGINT`, `INTEGER`, `INT` | Signed 64-bit `D.I64`, an alias for bend-kit-int's `I64` |
| `TEXT` | `String` |
| `BOOL`, `BOOLEAN` | `Bool` |
| Nullable column | `Maybe<&2, T>` |

Use `BIGINT` for the full signed 64-bit range on both databases. PostgreSQL enforces its 32-bit range on writes to `INT` and `INTEGER`. Both drivers preserve SQL NULL separately from an empty string.

### Checked SQL

- Supply a schema snapshot containing `CREATE TABLE` statements. The checker understands column and table `PRIMARY KEY`/`UNIQUE` constraints, named constraints, `NULL`/`NOT NULL`, typed literal `DEFAULT` values, foreign keys with explicit referenced columns and referential actions, and `CREATE [UNIQUE] INDEX` on columns. Foreign keys must reference compatible primary or unique keys; forward references in the snapshot are allowed. Put explicit `NOT NULL` on primary keys other than SQLite's special `INTEGER PRIMARY KEY`. When an `ALTER TABLE` migration changes a column, update the snapshot used for generation.
- Use single-table `SELECT`, `INSERT INTO … (columns) VALUES (values), …` or `INSERT INTO … DEFAULT VALUES`, `UPDATE … SET`, or `DELETE FROM`. Projections accept column names, `AS` aliases, and `*`. `SELECT DISTINCT` is supported; its `ORDER BY` columns must also be projected. Inserts can omit nullable columns and columns with defaults. Writes can include `RETURNING`. A query with result columns returns a list of typed rows, and a write without result columns returns `Unit`.
- A `WHERE` clause accepts typed comparisons between columns, literals, or named parameters; `IS [NOT] NULL`; `[NOT] IN` lists; `[NOT] BETWEEN`; and text `[NOT] LIKE` with optional single-character `ESCAPE`. Combine predicates with `AND`, `OR`, `NOT`, and parentheses using SQL precedence. Literal `NULL` comparisons and literal `NULL` entries in `IN` lists are rejected; use `IS NULL` explicitly. `LIKE` retains engine semantics: SQLite normally ignores ASCII case, while PostgreSQL is case-sensitive; PostgreSQL also treats backslash as an implicit escape. Use an explicit `ESCAPE` when patterns require portable escaping. Repeated parameter names share a binding. Incompatible types, missing required insert columns, unknown names, ambiguous output names, and unsupported SQL fail the check. Joins, aggregates, subqueries, and dialect-specific expressions are outside the checked grammar.
- A `SELECT` can sort by one or more columns or output aliases and take a page, for example `SELECT id AS book_id, title FROM books ORDER BY title ASC, book_id DESC LIMIT 20 OFFSET 40`. An output alias takes precedence over a source column of the same name. Both engines sort integers numerically and put NULLs last for ascending order and first for descending order. Use `NULLS FIRST` or `NULLS LAST` to choose explicitly. `LIMIT` and its optional `OFFSET` accept nonnegative integer literals up to 9223372036854775807 or named parameters. Page parameters become required `D.I64` arguments, and generated functions reject negative bounds before executing SQL.
- Use ASCII unquoted identifiers of up to 63 characters. Query filenames follow the same identifier shape. SQL identifiers and parameter names fold to lowercase. Use single quotes with doubled apostrophes for SQL strings. Parameters can carry arbitrary supported text without literal escaping.

Generation checks the SQL files and library paths before replacing the output module. The CLI searches `PATH` in Bend and passes literal arguments to `/usr/bin/realpath` and `/usr/bin/test` for path resolution and executable checks, including symlinks. It does not evaluate shell code. Input is read in 64 KiB chunks with strict UTF-8 validation across chunk boundaries. By default it looks for `runtime.bend` and `decode.bend` beside the executable. If you install the binary separately, pass the library directory as the last argument. Generated imports are relative to the output file. Choose a Bend module filename such as `generated.bend`. Each name in its import path must begin with an ASCII letter or underscore and may also contain digits and hyphens.

```sh
typed-sql generate schema.sql queries generated.bend /path/to/typed-sql
# Fail if the checked-in generated module is stale; never rewrite it.
typed-sql generate --check schema.sql queries generated.bend /path/to/typed-sql
```

## Compose transactions

Generated calls work with `R.Action`, which passes the database session through each step and stops on the first error:

```bend
act = do R.Action<Unit>:
  db => Q.q_add_book(db, id, title, author, in_print)
  return Unit{}
result : R.Outcome<Unit> <- R.transaction(Unit, act, db)
```

`R.transaction` commits a successful action and rolls back an action or commit failure. It rejects a connection already in a transaction without rolling back the caller's work. Return `R.Action.fail(A, message)` for an application error. Let the wrapper own transaction control; callbacks must not issue `BEGIN`, `COMMIT`, or `ROLLBACK` themselves. Returned sessions remain available on `R.Good` and `R.Bad`.

## Apply migrations

Name each file `VERSION_description.sql`, for example `001_books.sql` or `12_add_index.sql`. Versions are positive 32-bit unsigned integers and sort numerically. Pass the complete migration directory each time.

```sh
./typed-sql migrate sqlite catalog.db examples/migrations
PGHOST=localhost PGPORT=5432 PGUSER=app PGDATABASE=catalog \
  ./typed-sql migrate postgres examples/migrations
```

The PostgreSQL command reads `PGPASSWORD` when authentication requires it. It defaults to `localhost:5432`, user `postgres`, database matching the user, and `PGSSLMODE=verify-full`. Use `PGSSLMODE=disable` for a local server configured for plaintext.

The runner takes a SQLite write lock or a PostgreSQL transaction-level advisory lock before inspecting history. It compares each applied filename and its full UTF-8 source with the journal in `_bend_migrations`. Duplicate versions, renamed or edited files, missing history, and inserting a version before an applied migration all produce errors. Keep the journal table reserved for the runner.

All pending statements and their history entries commit in one transaction. A failing statement rolls back the pending batch, and statement errors identify their file and statement number. After correcting a pending migration, rerun the same command. SQLite can report a busy lock if another writer is active.

Migration files accept table, index, and view DDL, including temporary tables and views for staging, plus `INSERT`, `UPDATE`, and `DELETE`. Multiple statements may share a file. The splitter respects SQL doubled quotes and semicolons in literals and comments. Use ordinary single-quoted strings and double-quoted identifiers. The runner rejects explicit transaction commands, parameters, dollar quoting, backslash-escaped strings, and nested comments. Keep migrations portable when applying the same directory to both databases.

## Tests

```sh
bend tests/lexer.bend
bend tests/checker.bend
bend tests/query_features.bend
bend tests/schema_features.bend
bend tests/files.bend
bend tests/decode.bend
bend tests/runtime.bend
bend tests/migrations.bend
bend tests/integration.bend
sh tests/cli.sh
```

To exercise PostgreSQL on a local instance configured for passwordless access, run `bend tests/runtime.bend PORT USER DATABASE` and `bend tests/migrations.bend PORT USER DATABASE`. The runtime, migration, and integration suites use session-local test tables. Run `bend tests/integration.bend PORT USER DATABASE` for the generated caller suite. Its checked-in module is regenerated with `bend main.bend generate tests/fixtures/schema.sql tests/fixtures/queries tests/fixtures/generated.bend .`.

Bend 2.0.40 can report `an arity over 247` when native compilation specializes large inline calls or closures involving several `I64` values. Keep such calls in small top-level session helpers and pass runtime values; the integration suite demonstrates this with multi-row inserts and pagination. The generated function signatures stay the same.

The schema checker checks the documented grammar and types; it is not a replacement for applying DDL to the target database. Engine-specific restrictions, automatically generated index names, collations, and database limits still apply. SQLite's driver cannot validate the column width of an empty result; nonempty results and all PostgreSQL results are checked.

To measure checking and generation without compiler startup overhead:

```sh
bend tests/benchmark.bend -o /tmp/typed-sql-benchmark
/tmp/typed-sql-benchmark 256 20
/tmp/typed-sql-benchmark 1024 20
```

Named parameter collection and SQL rendering use indexes instead of repeatedly scanning all parameters. The benchmark reports elapsed milliseconds and generated character counts for reproducibility.

## License

[MIT License](LICENSE)
