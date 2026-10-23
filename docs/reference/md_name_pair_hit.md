# Do two name keys name the same organisation by an abbreviation rule?

Long prefix (8+ characters), acronym (a 2-8 letter single token equal to
the other's initials), or token-abbreviation sequence. `q` and `n` are
keys from
[`md_guard_key()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_key.md),
pairwise.

## Usage

``` r
md_name_pair_hit(q, n)
```

## Arguments

- q, n:

  Character vectors of equal length.

## Value

Logical.
