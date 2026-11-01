<div id="main" class="col-md-9" role="main">

# Known hazards in the NCCS metadata name and address files

<div class="ref-description section level2">

Two things about `meta_names` / `meta_addresses` have to be settled
before either is trusted as a variant source, and both are visible in
the first rows of the files:

</div>

<div class="section level2">

## Details

1.  **`ORG_NAME_ALL` is comma-concatenated and appears truncated.** The
    first data row reads
    `"SECOND BAPTIST CHURCH, PALMER SECOND BAPTIST CHURCH, PALMER SECOND BAPTIST CHU"`
    - several names joined by commas, with the last one cut mid-word.
    Splitting on the comma is ambiguous because organisation names
    contain commas, and a truncated tail would enter the database as a
    name that never existed. Quantify the truncation rate before
    ingesting; a variant source that invents strings is worse than no
    variant source.

2.  **`ORG_ADDRESS_ALL` is comma-joined** as `street,city,state,zip`,
    which collides with commas inside street lines. Prefer
    `address_resolved_crosswalk`, which has already done this parse and
    records each address spell as its own row with a vintage range.

`EIN2` is **not** a defect - it is the canonical identifier for this
project. See `md_ein()`. An earlier revision of this note had that
backwards.

</div>

</div>
