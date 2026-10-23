# Ingest organisation websites

Builds the `website` table from every source that carries a website
field: the 990 filing header (`F9_00_ORG_WEBSITE`), the 1023-EZ
approvals (`Orgurl`) and the 990-N e-Postcard (`website`). One row per
`(ein, site_key, source)`. Rebuilt whole on each call, like the derived
tables, because three sources feed it and `n_eins_sharing` spans all
three.

## Usage

``` r
md_ingest_websites(
  con = NULL,
  efile_version = NULL,
  f1023ez_version = NULL,
  e_postcard_version = NULL
)
```

## Arguments

- con:

  A connection from
  [`md_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_db.md).

- efile_version:

  Pinned `efile_header` version, or `NULL` to skip.

- f1023ez_version:

  Pinned `f1023ez` version, or `NULL` to skip. Reads the CSVs
  [`md_ingest_f1023ez()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_ingest_f1023ez.md)
  converted, so run that first.

- e_postcard_version:

  Pinned `e_postcard` version, or `NULL` to skip.

## Value

Row counts per source, invisibly.

## Details

A website is strong evidence when it is specific to one organisation and
worthless when it is not, so the table records which is which rather
than leaving it to every consumer.

## What counts as a website

The fields are free text, and much of it is not a website: `N/A`,
`NONE`, `TBD`, `SEE SCHEDULE O`, `UNDER CONSTRUCTION`, an organisation's
name, even `xxx-xx-xxxx`. Rather than list placeholders, a value is kept
only if, after cleaning, its host is a valid domain name: dot-separated
labels of letters, digits and hyphens ending in a 2-24 letter top-level
domain. Cleaning lowercases, turns a comma into a dot (`www,ptk.org` is
a common typo), and strips the scheme, a leading `www.` and any port. A
value with spaces in its host is not a website.

An email address (`info@example.org`) is kept by its domain, as
`kind = 'email'`, because an organisation's mail domain is usually its
web domain. Mail from a personal provider (gmail.com, yahoo.com, ...) is
dropped: it says nothing about which organisation sent it.

## `site_key`

what a match would compare: For most sites `site_key` is the host
without `www.`. For pages hosted on a shared platform (facebook.com,
sites.google.com, a `*.wixsite.com` page, linktr.ee, ...) the host
identifies the platform, not the organisation, so the key is the host
plus the first path segment (`facebook.com/hullscove`), and
`is_platform` is `TRUE`. A bare platform host with no path is dropped.

`n_eins_sharing` counts the EINs holding each `site_key`, across all
sources. A national body's site written by thousands of chapters
(`elks.org`) is family evidence, not identity evidence - the same
distinction `name_compact` draws with its own `n_eins_sharing`.

## Only known entities

A website needs an entity to belong to. Rows for EINs absent from
`entity` are held back and counted, not admitted: the e-Postcard has
73,503 such EINs, and whether to admit them is a decision for an
e-Postcard entity ingest, not for this one.
