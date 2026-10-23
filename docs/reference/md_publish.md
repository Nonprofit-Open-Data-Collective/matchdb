# Publish a compiled reference, and read one back

`md_publish()` compiles a spec and writes it as a bundle;
`md_reference()` reads a published bundle into the form npmatch matches
against. This is `PLAN.md` section 7b's first tier: most users download
a compiled reference, not the database.

## Usage

``` r
md_publish(spec, root = md_path("publish"), con = NULL, set_latest = TRUE)

md_publish_pointer(label, spec_hash, root = md_path("publish"))

md_reference(
  label,
  root = md_path("publish"),
  spec_hash = NULL,
  build_index = TRUE,
  fetch = FALSE
)
```

## Arguments

- spec:

  An
  [`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
  with a `label`.

- root:

  The publish directory. Defaults to `md_data_root()/publish`.

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- set_latest:

  Point `latest.json` at this bundle.

- label:

  A published label, e.g. `"active-observed"`.

- spec_hash:

  The bundle to point the label at.

- build_index:

  Also build npmatch's blocking index
  ([`npmatch::np_ref_index()`](https://nonprofit-open-data-collective.github.io/npmatch/reference/np_ref_index.html)),
  so the result can go straight to the cascade.

- fetch:

  Download the bundle first with
  [`md_fetch_reference()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md):
  `TRUE` always (a bundle already here and intact is not downloaded
  again), `"missing"` only when the label is not published locally.

## Value

The bundle directory, invisibly.

For `md_reference()`, a list: `reference` (an `np_reference`),
`name_freq`, `token_idf`, `clusters` (when published), `ref_index` (when
built) and `stamp`.

## What a bundle is

`<root>/<label>/<spec_hash>/` holds

- `reference.parquet`:

  the frame
  [`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
  returns

- `name_freq.parquet`, `token_idf.parquet`:

  npmatch's corpus statistics for exactly that frame

- `report.json`:

  the compile report: shape and absence

- `stamp.json`:

  the spec, the spec hash, the database fingerprint, the normalizer
  signature, the npmatch and matchdb versions, and the md5 of every file
  above

and `<root>/latest.json` maps each label to the bundle currently
published under it.

## Why the stamp is checked, and rollback is a pointer

A bundle's derived columns and statistics are only right for the
normalizer that made them (section 9). `md_reference()` refuses a bundle
whose normalizer signature is not the installed one, and one whose files
do not match their recorded md5. Rolling back is editing `latest.json`
back to an earlier hash - `md_publish_pointer()` - since every bundle
stays where it was written (section 7d).
