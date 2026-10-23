# What the 527 files can and cannot support

Measured on the 2024-11 vintage, before writing any ingest against them.

## Form 8871 (`irs527`)

68,365 rows over **51,542 distinct EINs** - so the key is
`FORM_ID_NUMBER` (68,365 distinct, exactly the row count), not `EIN`.
Each amendment is a new row, which is why the file carries name variants
at all: 1,231 EINs (2.4%) appear under more than one organisation name.
Ingest is therefore filing-level for `name`/`address` and deduplicated
to EIN for `entity`.

EIN quality is perfect - all 68,365 are already bare 9-digit strings,
none blank. Notably better than `meta_names`, whose `EIN2` is
`EIN-00-0019818`.

The file carries four address blocks (mailing, business, custodian,
contact) and two person-name fields. `CUSTODIAN_NAME` and
`CONTACT_PERSON_NAME` are legitimate `in_care_of` variants - an
organisation genuinely written as "c/o " is a spelling the matcher
should know. `E_MAIL_ADDRESS` should not be ingested: it carries no
matching signal and is personal contact data with no purpose in a
disambiguation reference.

## Schedule R (`irs527_related`)

62,153 rows over 8,377 EINs - only 16% of 527s file one. Three findings
shape how it can be used, and two of them are restrictive:

1.  **The related entity has no EIN.** The file gives
    `(527 EIN) -> (ENTITY_NAME, address)`. `ein_relation` as specified
    in `PLAN.md` §4 is `(ein_a, ein_b)`; this source cannot populate
    `ein_b`. Resolving a name to an EIN is a matching problem, which is
    `npmatch`'s job, not matchdb's - so these rows land with `ein_b`
    NULL and the counterparty recorded by name, or they wait.

2.  **Most related entities are not nonprofits.** Only 1,102 of 10,597
    distinct `ENTITY_NAME` values match a known 8871 organisation name -
    about 10%. The rest are sponsoring corporations, unions and trade
    associations, largely outside the BMF universe entirely.

3.  **`ENTITY_RELATIONSHIP` is free text, not an enumeration.** 528
    distinct values. `Connected` (54,660) and `Affiliated` (5,801) are
    97.4% of rows, with a long tail running to `Mother`,
    `Indirect Control` and `Common candidate-CA 33rd Assembly Dist.`.
    Any mapping onto the `ein_relation.relation` enum has to be explicit
    and has to say what it does with the tail.

Referential integrity to the 8871 file is close but not exact: 15,095 of
15,285 `FORM_ID_NUMBER` values resolve, leaving **190 orphans (1.2%)**.

## What must not happen

The related entity's name must never be registered as a `name` variant
on the 527's EIN. `PLAN.md` §10 is explicit that affiliates are not
DBAs, and this is the case that most invites the error - "ASSOCIATION OF
SAFETY GROUPS" is a different body from "ASGM PAC", and aliasing them
would manufacture exactly the false matches the disambiguation database
exists to prevent.

## An ingest hazard

[`data.table::fread()`](https://rdrr.io/pkg/data.table/man/fread.html)
segfaults on the 8871 file;
[`utils::read.csv()`](https://rdrr.io/r/utils/read.table.html) reads it
cleanly. The data is not malformed - line count and row count agree, so
there are no embedded newlines. Ingest should not assume `fread` on
these.
