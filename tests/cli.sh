#!/bin/sh
# Run with an existing typed-sql binary, or build one from the current checkout.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
lib="$tmp/store/lib"
mkdir -p "$tmp/bin" "$lib/examples" "$tmp/project" "$tmp/invalid.lib"
cp "$root/runtime.bend" "$root/decode.bend" "$lib/"
cp "$lib/runtime.bend" "$lib/decode.bend" "$tmp/invalid.lib/"
if [ "$#" -eq 0 ]; then
    bend "$root/main.bend" -o "$lib/typed-sql"
else
    cp "$1" "$lib/typed-sql"
fi
ln -s ../store/lib/typed-sql "$tmp/bin/typed-sql"
export PATH="$tmp/bin:$PATH"

cd "$tmp/project"
ln -s ../store/lib/examples generated
cp "$root/examples/catalog.bend" generated/
cp -R "$root/examples/queries" "$root/examples/migrations" .
mkdir queries/nested.sql migrations/nested.sql
schema=migrations/001_books.sql
output=generated/queries.bend

expect_error() {
    message=$1
    shift
    if "$@" >"$tmp/error" 2>&1; then
        echo "Expected failure from $*" >&2
        exit 1
    fi
    if ! grep -Fq "$message" "$tmp/error"; then
        cat "$tmp/error" >&2
        exit 1
    fi
}

expect_usage() {
    status=0
    typed-sql "$@" >"$tmp/usage-error" 2>&1 || status=$?
    if [ "$status" -ne 2 ]; then
        cat "$tmp/usage-error" >&2
        echo "Expected usage exit status 2 from typed-sql $*" >&2
        exit 1
    fi
    grep -Fq 'typed-sql check' "$tmp/usage-error"
}

expect_usage
expect_usage unknown
expect_usage --help extra
expect_usage check "$schema"
expect_usage generate --check "$schema" queries
expect_usage generate --check "$schema" queries "$output" "$lib" extra
expect_usage migrate sqlite catalog.db
expect_usage migrate postgres migrations extra

typed-sql check "$schema" queries
typed-sql --help >"$tmp/help"
grep -Fq 'generate [--check]' "$tmp/help"
typed-sql -h >"$tmp/help-short"
cmp "$tmp/help" "$tmp/help-short"
(unset PWD; typed-sql generate "$schema" queries "$output")
grep -Fxq 'import ../runtime.bend as R' "$output"
cp "$output" "$tmp/expected.bend"
PWD=/stale typed-sql generate "$schema" queries "$output" "$lib"
cmp "$tmp/expected.bend" "$output"

# Verification is suitable for CI: it detects stale or missing output without
# replacing the module or creating a missing one.
before=$(stat -c '%i %y' "$output")
typed-sql generate --check "$schema" queries "$output"
typed-sql generate --check "$schema" queries "$output" "$lib"
test "$before" = "$(stat -c '%i %y' "$output")"
# PATH lookup must skip an earlier file that cannot be executed.
mkdir "$tmp/shadow"
cp "$lib/typed-sql" "$tmp/shadow/typed-sql"
chmod 644 "$tmp/shadow/typed-sql"
PATH="$tmp/shadow:$PATH" typed-sql generate --check "$schema" queries "$output"
printf '\n# stale\n' >>"$output"
cp "$output" "$tmp/stale.bend"
expect_error 'out of date' typed-sql generate --check "$schema" queries "$output"
cmp "$tmp/stale.bend" "$output"
cp "$tmp/expected.bend" "$output"
expect_error 'missing.bend' typed-sql generate --check "$schema" queries generated/missing.bend
test ! -e generated/missing.bend
cp queries/find_book.sql "$tmp/find_book.sql"
printf '%s\n' 'SELECT title FROM books WHERE title = :title;' >queries/find_book.sql
expect_error 'out of date' typed-sql generate --check "$schema" queries "$output"
cmp "$tmp/expected.bend" "$output"
cp "$tmp/find_book.sql" queries/find_book.sql

expect_error 'unsupported by Bend imports' typed-sql generate "$schema" queries "$output" "$tmp/invalid.lib"
cmp "$tmp/expected.bend" "$output"
cp "$output" generated/2bad.bend
expect_error 'output filename' typed-sql generate "$schema" queries generated/2bad.bend
cmp "$tmp/expected.bend" generated/2bad.bend
expect_error 'replace its own' typed-sql generate "$schema" queries "$lib/runtime.bend"
cmp "$root/runtime.bend" "$lib/runtime.bend"
printf '%s\n' 'SELECT missing FROM books;' >queries/invalid.sql
expect_error 'unknown column' typed-sql generate "$schema" queries "$output"
cmp "$tmp/expected.bend" "$output"
# Overlong, surrogate, out-of-range, stray continuation, and truncated UTF-8.
for invalid in '\0300\0257' '\0355\0240\0200' '\0364\0220\0200\0200' '\0200' '\0360\0237'; do
    printf 'SELECT title FROM books; -- %b' "$invalid" >queries/invalid.sql
    expect_error 'invalid UTF-8' typed-sql generate "$schema" queries "$output"
    cmp "$tmp/expected.bend" "$output"
done
rm queries/invalid.sql

# A UTF-8 sequence may cross a 64 KiB input chunk; a bad continuation must
# still fail without replacing a generated module.
prefix='SELECT title FROM books; -- '
{
    printf '%s' "$prefix"
    awk -v n="$((65535 - ${#prefix}))" 'BEGIN { for (i = 0; i < n; i++) printf " " }'
} >"$tmp/boundary-prefix"
cp "$tmp/boundary-prefix" queries/boundary.sql
printf '\303\251\n' >>queries/boundary.sql
typed-sql check "$schema" queries
cp "$tmp/boundary-prefix" queries/boundary.sql
printf '\303(\n' >>queries/boundary.sql
expect_error 'invalid UTF-8' typed-sql generate "$schema" queries "$output"
cmp "$tmp/expected.bend" "$output"
rm queries/boundary.sql

# Invalid migration directories fail before opening SQLite or PostgreSQL.
mkdir duplicates
cp migrations/001_books.sql duplicates/001_books.sql
cp migrations/001_books.sql duplicates/1_duplicate.sql
expect_error 'duplicate migration version' typed-sql migrate sqlite unopened.db duplicates
test ! -e unopened.db
expect_error 'duplicate migration version' env PGPORT=invalid typed-sql migrate postgres duplicates

# Paths are passed literally, including shell syntax, quotes, and newlines.
odd='queries $(touch injected-dollar) `touch injected-backtick`'
odd="$odd 'quoted
directory"
cp -R queries "$odd"
typed-sql check "$schema" "$odd"
typed-sql generate --check "$schema" "$odd" "$output"
ln -s ../store/lib "$odd-library"
typed-sql generate --check "$schema" "$odd" "$output" "$odd-library"
ln -s ../store/lib/examples "$odd-output"
typed-sql generate --check "$schema" "$odd" "$odd-output/queries.bend"
test ! -e injected-dollar
test ! -e injected-backtick

# A real replacement character is valid input, as are two- and four-byte text.
cat >>migrations/002_catalog.sql <<'SQL'
INSERT INTO books (id, title, author, in_print) VALUES (2, 'Café � 🐈', NULL, FALSE);
SQL
typed-sql migrate sqlite catalog.db migrations
test "$(typed-sql migrate sqlite catalog.db migrations)" = 'Applied 0 migrations.'
bend "$lib/examples/catalog.bend" catalog.db 'Café � 🐈' >"$tmp/actual"
printf '%s\n' 'Café � 🐈 by unknown' 'In print: False' >"$tmp/expected"
diff -u "$tmp/expected" "$tmp/actual"
echo 'CLI tests passed'
