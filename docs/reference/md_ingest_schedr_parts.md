<div id="main" class="col-md-9" role="main">

# Add the other three identification parts of Schedule R

<div class="ref-description section level2">

`md_ingest_relations()` reads Schedule R **Part II** - related
*tax-exempt* organisations. The form has three more identification
parts, and all three name a counterparty with an EIN:

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_schedr_parts(
  con = NULL,
  which = c("disregarded", "partnership", "corporation"),
  version = "v2_2"
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A connection from `md_db()`.

-   which:

    One or more of `"disregarded"`, `"partnership"`, `"corporation"`.

-   version:

    Pinned version of the three Schedule R part sources, e.g. `"v3_1"`.

</div>

<div class="section level2">

## Value

Row counts per part, invisibly.

</div>

<div class="section level2">

## Details

-   Part I:

    disregarded entities - `efile_disregarded`

-   Part III:

    related organisations taxable as a partnership - `efile_related_ptr`

-   Part IV:

    related organisations taxable as a corporation or trust -
    `efile_related_corp`

</div>

<div class="section level2">

## These counterparties are mostly not nonprofits, and the rate is the point

Part II counterparties are exempt organisations by definition, so their
EINs resolve well. These do not. Measured on Part I across 2009-2024:

<div class="sourceCode">

      rows                              2,000,291
      with a counterparty EIN             317,232
      distinct counterparty EINs           35,306
      resolving to a known `entity`         4,763  (13.5

</div>

13.5% is close to the 14.8% seen on 527 Schedule R, and for the same
reason: a disregarded entity is usually a single-member LLC with no
exempt status of its own, and a taxable subsidiary is a C-corp. They are
outside the BMF universe.

Rows are still written with `ein_b` populated, because unlike the 527
file these sources *give* the EIN - an EIN that is real but unknown to
matchdb is a different thing from an EIN that was never disclosed. A
consumer joining `ein_b` to `entity` should expect roughly one in seven
to land, and the per-source rate is reported on every run.

</div>

<div class="section level2">

## Part I is a different relation from Parts III and IV

See the §4a vocabulary. Parts III and IV describe organisations the
filer controls, owns a share of, or shares governance with -
`related_entity`. Part I describes an entity with **no separate tax
existence at all**, whose activity is reported on the filer's own
return. That is a tighter tie than any disclosure on the rest of the
form, so it gets its own value, `disregarded_entity`.

The part is additionally carried in `evidence`
(`schedule_r_part_i_disregarded`, `..._part_iii_partnership`,
`..._part_iv_corporation`), so the taxable/exempt distinction inside
`related_entity` survives without needing its own enum value.

</div>

<div class="section level2">

## A deferred question about disregarded entities

Because a disregarded entity has no separate tax existence, its name is
arguably a name the *parent* operates under - closer to a `dba` than to
a relation at all. That would be a `name` row on the parent's EIN.

It is deliberately **not** done here. §10 forbids casually aliasing one
organisation's name onto another, and the difference between
"disregarded for tax" and "the same organisation for matching" has not
been measured. Recording the relation keeps the option open; writing the
alias would not be reversible.

</div>

<div class="section level2">

## An ingest hazard, and it is not the one documented for 527

Pre-2013 files carry doubled quotes inside *unquoted* fields
(`PLEASE SEE SCHEDULE ""O"".`), which is malformed CSV and aborts a
strict parse partway through 2010.
`quote='"', escape='"', ignore_errors=TRUE` reads them. Early years are
also much wider - Part I is 96 columns in 2012 against 34 in 2013 - so
`union_by_name=TRUE` is required, and most rows are blank padding rather
than data.

</div>

</div>
