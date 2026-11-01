<div id="main" class="col-md-9" role="main">

# Package index

<div class="section level2">

## Get a reference and match

<div class="section-desc">

Download a published reference, or the whole database, and read it in
the form npmatch matches against.

</div>

</div>

<div class="section level2">

-   `md_publish()` `md_publish_pointer()` `md_reference()` : Publish a
    compiled reference, and read one back
-   `md_fetch_reference()` `md_fetch_db()` `md_remote()` : Download
    published references, or the whole database

</div>

<div class="section level2">

## Your matchdb folder

<div class="section-desc">

What is published and what is here, the log of everything fetched,
compiled and published, and updating to a new build.

</div>

</div>

<div class="section level2">

-   `md_tranches()` `md_tranche_manifest()` `md_tranche_diff()`
    `md_tranches_prune()` : What tranches are published, what they cost,
    and what changed
-   `md_log()` `md_log_run()` `md_status()` : The workspace log: what
    was fetched, compiled and published, and when

</div>

<div class="section level2">

## Look things up

<div class="section-desc">

Everything the database knows about an EIN, and the families it belongs
to.

</div>

</div>

<div class="section level2">

-   `md_lookup()` `md_lookup_parts()` : Everything the database knows
    about an EIN
-   `md_cluster()` : The families an EIN belongs to, and who else is in
    them
-   `md_ein()` `md_is_ein()` : The canonical EIN format

</div>

<div class="section level2">

## Compile and publish your own slice

<div class="section-desc">

Describe a reference by layer, name and address class, source and
corroboration; compile it; publish it as a stamped bundle.

</div>

</div>

<div class="section level2">

-   `md_spec()` : Describe a reference: which EINs, which names, which
    addresses

-   `md_compile()` : Compile a spec into the reference frame npmatch
    matches against

-   `md_publish()` `md_publish_pointer()` `md_reference()` : Publish a
    compiled reference, and read one back

-   `md_publish_tranches()` `md_tranche_pointer()` `md_fetch_tranches()`
    `md_tranche_db()` : Publish the database as parquet tranches, fetch
    only what a spec needs

-   `md_relations()` `md_layers()` `md_name_classes()`
    `md_address_classes()` : The frozen enumerations, as code

-   `md_name_sources()` `md_address_sources()` :

    Source-bit registries for `source_mask`

</div>

<div class="section level2">

## The database

</div>

<div class="section level2">

-   `md_db()` `md_db_close()` : Open the matchdb database
-   `md_data_root()` `md_path()` `md_data_init()` : Where matchdb keeps
    its data

</div>

<div class="section level2">

## Sources and provenance

</div>

<div class="section level2">

-   `md_sources()` : The source registry
-   `md_source_urls()` : URLs for a year-partitioned source
-   `md_source_head()` : Read upstream object metadata without
    downloading it
-   `md_source_pin()` `md_source_read_pin()` `md_source_read_files()` :
    Pin a source to a concrete, immutable version
-   `md_source_moved()` : Has an upstream pointer moved since we pinned
    it?
-   `md_source_kinds()` : The kinds of source
-   `md_record_vintage()` : Record an ingest in the audit table
-   `md_relations()` `md_layers()` `md_name_classes()`
    `md_address_classes()` : The frozen enumerations, as code
-   `md_f1023ez_urls` : The 1023-EZ approval URLs are not consistently
    named
-   `md_meta_caveats` : Known hazards in the NCCS metadata name and
    address files

</div>

<div class="section level2">

## Stable ids

<div class="section-desc">

Content-hash ids for names, addresses, observations and releases, the
same in R and in SQL (dev/IDENTITY.md).

</div>

</div>

<div class="section level2">

-   `md_canon()` `md_hash_id()` `md_name_text_id()`
    `md_address_text_id()` `md_release_id()` : Canonical text and
    content-hash ids
-   `md_id_recipes()` : The id recipes
-   `md_identity_macros()` : Install the id macros in a DuckDB
    connection
-   `md_record_keys()` : The natural key of each source
-   `md_check_record_key()` : Check a source's natural key on a loaded
    file
-   `md_text_schema()` `md_add_text()` `md_build_text()`
    `md_build_text_derived()` `md_check_text_derived()`
    `md_text_stats()` : Text dictionaries and derived columns keyed on
    the text
-   `md_ledger_schema()` : The observation ledger
-   `md_apply_release()` : Fold one release of a source into the ledger
-   `md_parse_efile_header()` `md_parse_schedi()`
    `md_parse_bmf_active()` `md_parse_address_crosswalk()`
    `md_parse_bmf_unified()` `md_parse_f1023ez()`
    `md_parse_efile_related()` `md_parse_affiliate_listing()`
    `md_parse_e_postcard()` `md_parse_revocations()` : Parse a raw
    source file into a ledger frame
-   `md_build_ledger()` : Load the pinned source files into the ledger
-   `md_build_rollups()` `md_compare_rollups()` `md_install_rollups()` :
    Build name and address from the ledger
-   `md_link_derived()` : Rebuild name_derived and address_derived from
    the text-keyed columns
-   `md_normalizer_diff()` : What a new normalizer would change

</div>

<div class="section level2">

## Building the database

<div class="section-desc">

The ingests, in the order dev/build-matchdb.R runs them, then the
derived tables. Most users never call these.

</div>

</div>

<div class="section level2">

-   `md_ingest_address_crosswalk()` : Ingest the resolved address
    crosswalk as historical spells

-   `md_ingest_affiliate_listing()` : Add group-return rosters: the
    subordinate names the BMF throws away

-   `md_ingest_bmf()` `md_validate_bmf()` : Ingest the unified BMF into
    entity, name and address

-   `md_ingest_efile_group()` : Add group membership from what filers
    report on Form 990 line H

-   `md_ingest_efile_header()` : Ingest the 990 filing header as
    self-reported names and addresses

-   `md_ingest_e_postcard()` : Ingest the Form 990-N e-Postcard

-   `md_ingest_f1023ez()` : Ingest Form 1023-EZ approvals

-   `md_ingest_geocode()` : Attach census geography to the addresses it
    actually describes

-   `md_ingest_group_meta()` : Add historical group membership from the
    NCCS group metadata

-   `md_ingest_irs527_related()` : Add related entities disclosed on 527
    Schedule R

-   `md_ingest_ntee()` : Fill the resolved NTEE triple on entity

-   `md_ingest_officers()` : Ingest officer, director and key-employee
    name keys from Form 990 Part VII

-   `md_ingest_orgtext()` : Ingest mission and program text

-   `md_ingest_relations()` : Build ein_relation from Schedule R and the
    group exemption structure

-   `md_ingest_revocations()` : Ingest the IRS automatic revocation list

-   `md_ingest_schedi()` : Ingest Schedule I recipient aliases as
    observed names and addresses

-   `md_ingest_schedr()` : Ingest Schedule R related organisations as
    observed names and addresses

-   `md_ingest_schedr_parts()` : Add the other three identification
    parts of Schedule R

-   `md_ingest_sched_c_affil()` : Add the Schedule C affiliated-group
    roster

-   `md_ingest_websites()` : Ingest organisation websites

-   `md_build_derived()` : Build the derived-column tables

-   `md_check_derived_fresh()` : Has a re-ingest invalidated the derived
    tables?

-   `md_build_compact()` : Build the compact identity tables

-   `md_build_groups()` :

    Build `group_id`: the federated families in `ein_relation`

-   `md_build_places()` : Places: how crowded an address is, and what
    kind of place it is

-   `md_place_key()` `md_unit_id()` : npnormalize's address key and
    suite identifier

-   `md_addr_freq()` : Address-sharing statistics for a compiled
    reference

-   `md_build_ein_key()` :

    Build `ein_key`: every identifier an EIN holds, with how specific it
    is

-   `md_build_clusters()` : Build the cluster layer: typed, many-to-many
    families of EINs

-   `md_build_stats()` : Build the per-cell corpus statistics

-   `md_ntee_canonical` : The NTEE crosswalk is canonical, and its
    nteev2 columns are not

-   `md_irs527_shape` : What the 527 files can and cannot support

-   `md_schedb_excluded` : Why 527 Schedule B is not a matchdb source

</div>

<div class="section level2">

## Checks and guards

</div>

<div class="section level2">

-   `md_validate()` `md_validate_report()` : Intrinsic validation of a
    built table
-   `md_ingest_bmf()` `md_validate_bmf()` : Ingest the unified BMF into
    entity, name and address
-   `md_ntee_crosscheck()` : Compare the 1023-EZ NTEE against the
    resolved value
-   `md_guard_observed()` : Guards on observed names: is the written
    name really this EIN's?
-   `md_guard_key()` : Name key used by the guards
-   `md_placeholder_ein()` : Placeholder EINs
-   `md_name_pair_hit()` : Do two name keys name the same organisation
    by an abbreviation rule?

</div>

<div class="section level2">

## Verification harness

<div class="section-desc">

Comparing references and match results between builds (the phase gates).

</div>

</div>

<div class="section level2">

-   `md_normal_form()` : Put a frame in comparison normal form
-   `md_compare_frames()` : Compare two frames against the gate
    criterion
-   `md_compare_tiered()` : Compare two tiered benchmark outputs

</div>

<div class="section level2">

## Utilities

</div>

<div class="section level2">

-   `md_modal_sql()` : Deterministically pick a representative value
-   `md_light_key()` : The light key ingests group spellings on
-   `md_xlsx_to_csv()` : Extract named columns from a large .xlsx by
    streaming its XML

</div>

</div>
