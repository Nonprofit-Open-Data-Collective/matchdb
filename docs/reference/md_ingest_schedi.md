# Ingest Schedule I recipient aliases as observed names and addresses

Form 990 Schedule I Part II is where a non-PF filer lists every grant it
made to a US organisation, with the recipient's **name, address and
EIN**. That last field is what makes it unlike every other source here:
it is a large set of (name variant, address variant) to EIN
observations, written by third parties, in the register a grantmaker
actually uses.

## Usage

``` r
md_ingest_schedi(
  version = "v2_2",
  years = NULL,
  con = NULL,
  min_corroborators = 1L,
  guard = TRUE
)
```

## Arguments

- version:

  Pinned `schedi` version, e.g. `"v2_2"`.

- years:

  Years to load. Defaults to every file present.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- min_corroborators:

  Drop groups written by fewer than this many distinct filers. `1` keeps
  everything; filtering belongs in the spec, so the default loads all of
  it.

- guard:

  Run
  [`md_guard_observed()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_observed.md)
  on the loaded rows. Flags are only as good as the first-party names
  already loaded, so re-run it once the BMF and return headers are in.

## Value

Row counts, invisibly.

## Details

The BMF gives one legal name per EIN. This gives many *observed* names,
and it is the source `pfmatch/dev/AUDIT-FINDINGS.md` named as the
missing piece for brand-versus-legal-name matching.

## Corroboration is the trust signal

Rows are collapsed to one per `(ein, name_key, city, state, zip5)` and
carry `n_corroborators`, the count of **distinct filers** who wrote that
string for that EIN. One filer's typo and a brand name fifty foundations
independently use are both "observed names"; only the corroborator count
separates them. It becomes a spec filter (§5) rather than a threshold
baked into a script.

## The pairing link

A grantmaker wrote a name *and an address together*, and that pairing is
real information. Each observed address carries the `name_id` it was
seen with, so the compiler emits roughly *k + m* rows per EIN rather
than *k x m* (§8). Losing the link is what turns a useful source into a
row explosion.

## Grouping on a key, storing the raw string

Deduplication needs some normalisation or trivial punctuation
differences become separate variants. Rows are grouped on the light key
([`md_light_key()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_light_key.md):
accents and `&` spelled out, uppercased, punctuation dropped, whitespace
collapsed) - but the stored `name_raw` is the **most frequently written
raw form** within the group, so the database still holds a string a
filer actually typed rather than a normalised reconstruction.
`np_normalize()` derived columns are built from that raw string later,
exactly as for BMF rows.

## Wrong names on the right line

A filer's own EIN written for its grantee, a denomination's central EIN
written for a congregation, a fiscal sponsor's EIN written for its
projects, `000000000` and `SEE SCHEDULE O`: all are on Schedule I, often
by many filers. Rows are kept and flagged by
[`md_guard_observed()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_observed.md);
see `dev/OBSERVED-NAME-GUARDS.md` for how many and how corroborated they
are.
