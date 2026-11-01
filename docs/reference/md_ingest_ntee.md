<div id="main" class="col-md-9" role="main">

# Fill the resolved NTEE triple on entity

<div class="ref-description section level2">

Populates `ntee_code`, `ntee_rule`, `ntee_agreement`, `ntee_n_distinct`,
`ntee_source` and `nteev2` (§4) by combining the BMF snapshot with the
canonical NTEE crosswalk.

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_ingest_ntee(
  version,
  crosswalk = NULL,
  con = NULL,
  crosswalk_version = "2026-08"
)
```

</div>

</div>

<div class="section level2">

## Arguments

-   version:

    The pinned `bmf_unified` version (for the active-vintage test).

-   crosswalk:

    Path to `ntee_resolved_crosswalk.csv`.

-   con:

    A connection from `md_db()`.

-   crosswalk_version:

    Pinned `ntee_crosswalk` version, used when `crosswalk` is `NULL`.

</div>

<div class="section level2">

## Value

A table of rule counts, invisibly.

</div>

<div class="section level2">

## The resolution rule

1.  **`bmf_current`** - the organisation is in the current active BMF
    release and the BMF carries an NTEE code. What the IRS says now wins
    for an organisation that currently exists.

2.  **`modal`** - otherwise, the code observed in the most vintages.
    Robust to a single mis-keyed year, which a most-recent rule is not.

3.  **`most_recent`** - if there is no modal value.

4.  **`bmf_only`** - for EINs absent from the crosswalk entirely, the
    BMF code, whatever its vintage.

5.  `NULL` with `ntee_rule = 'none'` when no source has a code.

</div>

<div class="section level2">

## What the measurements say about this rule

Three findings shaped it, all against the pinned BMF and crosswalk.

**The BMF and the crosswalk's `ntee_current` are the same value, not two
opinions.** Among active EINs where the crosswalk has a `current` code,
it agrees with the BMF on 1,382,208 and differs on 608 - 99.96%. So
there is no choice to make between "the BMF version" and "the
crosswalked current version"; the real choice is between *now* and
*history*.

**The BMF's NTEE is missing far more often for active organisations than
inactive ones** - 29.4% against 3.6%. The fallback is therefore not an
edge case: rule 1 leaves 581,028 active organisations to be resolved by
rule 2. The inversion is not a defect; legacy rows inherit NTEE from
NCCS series that assigned it, while the current IRS extract often does
not.

**For active organisations the BMF code and the modal code disagree
38.8% of the time** (741,207 of 1,911,130), so rule 1 versus rule 2 is a
consequential choice rather than a formality. For inactive organisations
modal and most-recent differ only 4.1%, so rule 3 is nearly free.

</div>

<div class="section level2">

## nteev2 is recomputed, and how well depends on the rule

`fiscal::get_nteev2()` is applied to the chosen code rather than any
stored rendering, because both the BMF and the crosswalk ship the
specialty double-encoding defect (`?md_ntee_canonical`).

One honest limitation. Rule 1 recomputes from `ntee_code_raw`, which
preserves the legacy five-character form and so gets the `B8443 -> B43`
rule right. Rules 2 and 3 only have the crosswalk's three-character
code, where that information is already gone. `ntee_source` records
which, so rows whose NTEEv2 rests on a truncated input are identifiable
rather than merely suspected.

</div>

</div>
