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

- Supply a schema snapshot containing `CREATE TABLE` statements. The checker understands column-level `PRIMARY KEY`, `UNIQUE`, `NULL`, and `NOT NULL`. Put explicit `NOT NULL` on primary keys other than SQLite's special `INTEGER PRIMARY KEY`. When an `ALTER TABLE` migration changes a column, update the snapshot used for generation.
- Use single-table `SELECT`, `INSERT INTO … (columns) VALUES (values)`, `UPDATE … SET`, or `DELETE FROM`. Projections accept column names, `AS` aliases, and `*`. Writes can include `RETURNING`. A query with result columns returns a list of typed rows, and a write without result columns returns `Unit`.
- A `WHERE` clause accepts comparisons with literals or named parameters, `IS NULL`, `IS NOT NULL`, and `AND`. Repeated parameter names share a binding. Incompatible types, missing required insert columns, unknown names, ambiguous output names, and unsupported SQL fail the check. Joins, aggregates, subqueries, ordering, and dialect-specific expressions are outside the checked grammar.
- Use ASCII unquoted identifiers of up to 63 characters. Query filenames follow the same identifier shape. SQL identifiers and parameter names fold to lowercase. Use single quotes with doubled apostrophes for SQL strings. Parameters can carry arbitrary supported text without literal escaping.

Generation checks the entire query directory before replacing the output module. The default library directory is the directory containing the CLI. If you install the binary elsewhere, pass the directory containing `runtime.bend` and `decode.bend` as the last argument. Generated imports are relative to the output file.

```sh
typed-sql generate schema.sql queries generated.bend /path/to/typed-sql
```

## Apply migrations

Name each file `VERSION_description.sql`, for example `001_books.sql` or `12_add_index.sql`. Versions are positive 32-bit unsigned integers and sort numerically. Pass the complete migration directory each time.

```sh
./typed-sql migrate sqlite catalog.db examples/migrations
PGHOST=localhost PGPORT=5432 PGUSER=app PGDATABASE=catalog \
  ./typed-sql migrate postgres examples/migrations
```

The PostgreSQL command reads `PGPASSWORD` when authentication requires it. It defaults to `localhost:5432`, user `postgres`, database matching the user, and `PGSSLMODE=verify-full`. Use `PGSSLMODE=disable` for a local server configured for plaintext.

The runner takes a SQLite write lock or a PostgreSQL transaction-level advisory lock before inspecting history. It compares each applied filename and its full UTF-8 source with the journal in `_bend_migrations`. Duplicate versions, renamed or edited files, missing history, and inserting a version before an applied migration all produce errors. Keep the journal table reserved for the runner.

All pending statements and their history entries commit in one transaction. A failing statement rolls back the pending batch, and the error identifies its file. After correcting a pending migration, rerun the same command. SQLite can report a busy lock if another writer is active.

Migration files accept table and index DDL, plus `INSERT`, `UPDATE`, and `DELETE`. Multiple statements may share a file. The splitter respects SQL doubled quotes and semicolons in literals and comments. Use ordinary single-quoted strings and double-quoted identifiers. The runner rejects explicit transaction commands, parameters, dollar quoting, backslash-escaped strings, and nested comments. Keep migrations portable when applying the same directory to both databases.

## Tests

```sh
bend tests/checker.bend
bend tests/decode.bend
bend tests/runtime.bend
bend tests/migrations.bend
```

To exercise the runtime against a local PostgreSQL instance configured for passwordless access, run `bend tests/runtime.bend PORT USER DATABASE`. The test uses a temporary table.

## License

[MIT License](LICENSE)
