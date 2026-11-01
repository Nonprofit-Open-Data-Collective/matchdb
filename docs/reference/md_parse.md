<div id="main" class="col-md-9" role="main">

# Parse a raw source file into a ledger frame

<div class="ref-description section level2">

Each parser reads one source's raw file, with the publisher's own column
names, and returns the name of a temporary view in the standard frame
shape `md_apply_release()` takes. Parsing is the whole job: which names
and addresses a record states, under which role, with which key.
Identity, diffing and writing are the engine's (`dev/IDENTITY.md` §5).

</div>

<div class="section level2">

## Usage

<div class="sourceCode">

``` r
md_parse_efile_header(con, relation, view = "frame_efile_header")

md_parse_schedi(con, relation, view = "frame_schedi")

md_parse_bmf_active(con, relation, view = "frame_bmf_active")

md_parse_address_crosswalk(con, relation, view = "frame_address_crosswalk")

md_parse_bmf_unified(con, relation, view = "frame_bmf_unified")

md_parse_f1023ez(con, relation, year, view = "frame_f1023ez")

md_parse_efile_related(con, relation, view = "frame_efile_related")

md_parse_affiliate_listing(con, relation, view = "frame_affiliate_listing")

md_parse_e_postcard(con, relation, view = "frame_e_postcard")

md_parse_revocations(con, relation, view = "frame_revocations")
```

</div>

</div>

<div class="section level2">

## Arguments

-   con:

    A DuckDB connection.

-   relation:

    The raw file as a table, view or `read_csv(...)` expression.

-   view:

    Name for the temporary view returned.

-   year:

    For `md_parse_f1023ez()`: the approval year of the file.

</div>

<div class="section level2">

## Value

The view's name.

</div>

<div class="section level2">

## Details

Text is passed through as the source wrote it; only structure is parsed
(an EIN to `EIN2`, a ZIP into its five and four digits, name lines
joined). Case, punctuation and abbreviations are the normalizer's
business, in the derived columns.

Phase 5 step 4 ports one source of each kind:

-   `md_parse_efile_header()`:

    series. One frame row per name on the return - legal, DBA, in care
    of - each with the return's address. `record_key` is `OBJECTID`.

-   `md_parse_schedi()`:

    mentions. One row per grant line: the recipient's name and address
    as the filer wrote them, `asserted_by` the filer. Identical lines in
    one return are kept, and the engine numbers them.

-   `md_parse_bmf_active()`:

    snapshot. Names and the address as separate rows, so a renamed
    organisation that did not move keeps its address spell, and the
    other way round.

-   `md_parse_address_crosswalk()`:

    cache. One row per address spell, with the range the crosswalk
    states as `first_seen`/`last_seen`.

Step 5 ports the remaining sources that write names or addresses:

-   `md_parse_bmf_unified()`:

    seed. Like the monthly BMF, names and the address are separate rows;
    each carries the EIN's first and last vintage, stored as an envelope
    ("the EIN existed over this range and ended with this value"), not
    as a spell.

-   `md_parse_f1023ez()`:

    series, one partition per approval year. The legal name with the
    address, keyed on the EIN.

-   `md_parse_efile_related()`:

    mentions. Schedule R Part II: each related organisation's name and
    address as the filer wrote them.

-   `md_parse_affiliate_listing()`:

    mentions. A group return's roster: each subordinate's own name, and
    from e-file v3_1 its address. A row needs a full nine-digit member
    EIN, and a parent listing itself is dropped, as in
    `md_ingest_affiliate_listing()`.

-   `md_parse_e_postcard()`:

    snapshot. The legal name and up to three DBAs, and the address, as
    separate rows. The postcard's tax year is not kept: a spell runs
    across monthly releases, not across postcards.

-   `md_parse_revocations()`:

    series, one cumulative partition. The legal name and DBA, each with
    the address as of revocation, keyed on the EIN and revocation date;
    the year revoked is the period.

</div>

</div>
