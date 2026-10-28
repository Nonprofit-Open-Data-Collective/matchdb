# Canonical text and content-hash ids

Phase 5 (`dev/IDENTITY.md` §3) identifies every name, address,
observation and release by an md5 of what the source wrote, so anyone
can recompute an id from the raw file and get the same value on any
machine. These functions are the R side of that recipe. Ingest computes
the same ids in SQL with the macros
[`md_identity_macros()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_identity_macros.md)
installs; a test holds the two to identical output.

## Usage

``` r
md_canon(x)

md_hash_id(tag, ...)

md_name_text_id(name_raw)

md_address_text_id(street, unit, city, state, zip5, zip4)

md_release_id(source, version, partition = NA)
```

## Arguments

- x:

  A character vector (other types are coerced with
  [`as.character()`](https://rdrr.io/r/base/character.html)).

- tag:

  A recipe tag from
  [`md_id_recipes()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_id_recipes.md).

- ...:

  Fields, each a vector of the same length (or length 1).

- name_raw:

  A name as the source wrote it.

- street, unit, city, state, zip5, zip4:

  Address fields as the source wrote them. A source without a separate
  unit line passes `NA`.

- source, version, partition:

  A pinned release. `partition` is the tax year for a year-partitioned
  source and `NA` otherwise.

## Value

A character vector.

## `md_canon()`

The only change made to a field before hashing:

1.  `NA` / `NULL` becomes `""`.

2.  Unicode NFC, so a precomposed and a decomposed accent are one
    string.

3.  Every run of control characters, spaces and no-break spaces
    (`\\x01`-`\\x20`, `\\x7f`, `\\x{a0}`) becomes one space. Tabs and
    newlines are whitespace in the data; the other control characters
    are noise, and folding them in means the field separator `\\x1f` can
    never occur inside a canonical field.

4.  Leading and trailing spaces are dropped.

There is **no** case folding and no punctuation stripping: the canonical
string is what the source wrote, apart from whitespace. Matching on
case-insensitive keys is the normalizer's job, in the derived columns.

## The recipe

`id = md5(tag \\x1f canon(field_1) \\x1f canon(field_2) ...)`, as 32
lowercase hex characters. The tag names the recipe and its version
([`md_id_recipes()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_id_recipes.md)).
Changing what goes into an id means a new tag, never an edit to an old
one.

Ids are kept as hex strings, not integers: DuckDB's R client converts
`HUGEINT` to `double` by default, which would silently destroy a 128-bit
id.
