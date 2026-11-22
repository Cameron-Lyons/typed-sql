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

typed-sql check "$schema" queries
(unset PWD; typed-sql generate "$schema" queries "$output")
grep -Fxq 'import ../runtime.bend as R' "$output"
cp "$output" "$tmp/expected.bend"
PWD=/stale typed-sql generate "$schema" queries "$output" "$lib"
cmp "$tmp/expected.bend" "$output"

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
