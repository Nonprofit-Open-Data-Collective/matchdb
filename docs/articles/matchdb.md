# Getting started

You have a list of organizations: grant recipients, survey respondents,
a contractor list. Each has a name and an address but no EIN. matchdb
supplies the other side of the match: every name and address the IRS and
990 filers have recorded for each EIN.
[npmatch](https://github.com/Nonprofit-Open-Data-Collective/npmatch)
does the matching.

This walk-through matches four grant recipients, reads the results, and
looks more closely at the ones that are not clear-cut. The output shown
is from the published references of 2026-10-23.

## 1. Install

``` r

remotes::install_github("Nonprofit-Open-Data-Collective/npmatch")
remotes::install_github("Nonprofit-Open-Data-Collective/matchdb")
library(matchdb)
```

## 2. Get a reference

A reference is the frame npmatch matches against. Four are published:

| label | which organizations | which names | rows |
|----|----|----|---:|
| `active-legal` | in the current BMF | legal name and DBA | 2.75M |
| `active-observed` | in the current BMF | legal, DBA, and names 2+ grantmakers wrote | 2.89M |
| `unified-legal` | in any BMF release | legal name and DBA | 4.98M |
| `unified-observed` | in any BMF release | legal, DBA, and names 2+ grantmakers wrote | 5.14M |

For current records, start with `active-observed`. The names grantmakers
write (“American Red Cross”) are often not the legal name (“American
National Red Cross”), and the observed names cover that gap.
[`vignette("layers")`](https://nonprofit-open-data-collective.github.io/matchdb/articles/layers.md)
explains when to use the `unified-*` tiers.

``` r

b <- md_reference("active-observed", fetch = "missing")
```

The first call downloads about 260 MB from the public NCCS copy; no AWS
account is needed. Later calls read the local copy. Every file is
checked against the md5 it was published with, and the bundle is refused
if it was built by a different normalizer (npnormalize) than the one
installed. `b` holds:

- `reference`: the frame;
- `name_freq` and `token_idf`: corpus statistics, which tell npmatch how
  common a name or word is;
- `ref_index`: the blocking index;
- `clusters`: the families its organizations belong to.

## 3. Describe your records and match

`np_query()` maps your columns onto npmatch’s fields:

``` r

grants <- data.frame(
  id     = c("g1", "g2", "g3", "g4"),
  name   = c("American Red Cross", "Habitat for Humanity of Greater Boston",
             "Boys & Girls Club of Dane County", "Friends of the Ellsworth Public Library"),
  street = c("431 18th Street NW", "434 Massachusetts Ave Suite 201",
             "5215 Verona Road", "20 State Street"),
  city   = c("Washington", "Boston", "Fitchburg", "Ellsworth"),
  state  = c("DC", "MA", "WI", "ME"),
  zip    = c("20006", "02118", "53711", "04605"))

q <- npmatch::np_query(grants, c(.id = "id", name = "name", street = "street",
                                 city = "city", state = "state", zip5 = "zip"))

m <- npmatch::np_cascade(q, b$reference,
                         name_freq = b$name_freq, token_idf = b$token_idf,
                         ref_index = b$ref_index)
```

## 4. Read the results

Each query gets a tier: `YES` (accept), `MAYBE` (a good candidate that
needs a look) or `NO`. It also gets the best EIN found and the reference
name that won.

``` r

as.data.frame(m)[, c(".id", "tier", "overall_ein", "overall_name_y", "overall_score")]
#>   .id  tier    overall_ein                          overall_name_y overall_score
#> 1  g1 MAYBE EIN-53-0196605                      AMERICAN RED CROSS         0.680
#> 2  g4 MAYBE EIN-01-0498465 FRIENDS OF THE ELLSWORTH PUBLIC LIBRARY         0.980
#> 3  g3 MAYBE EIN-39-1925617  BOYS AND GIRLS CLUB OF DANE COUNTY INC         0.980
#> 4  g2   YES EIN-04-2994233 HABITAT FOR HUMANITY GREATER BOSTON INC         0.927
```

All four found the right organization. Only one is a YES, and each MAYBE
is a MAYBE for a different reason.

- **g2, Habitat for Humanity: YES.** Name and address agree, and nothing
  else comes close.
- **g1, American Red Cross: MAYBE.** The name matched exactly, on an
  observed name: grantmakers write `AMERICAN RED CROSS`, and
  `active-observed` carries that spelling. But each observed name comes
  paired with the address grantmakers wrote next to it, usually a local
  chapter, not headquarters. Name and address therefore point at
  different rows (`views_agree` is `FALSE`), and npmatch holds it at
  MAYBE.
- **g4, Friends of the Ellsworth Public Library: MAYBE.** Exact name and
  address, but `LIBRARY` triggers npmatch’s soft `government_entity`
  veto, since many libraries are government units without an EIN of
  their own. Here the friends group is a nonprofit, and a reviewer would
  accept it.
- **g3, Boys & Girls Club of Dane County: MAYBE, tie.** Three EINs
  scored 0.98. That is a family, not a mistake, as the next section
  shows.

The full result has the reasons in columns: `pass`, `runner_up_score`,
`tie`, `n_close`, `overall_veto_reason`, `views_agree`, `name_ein` and
`addr_ein`.

## 5. Look closer

With the database downloaded,
[`md_lookup()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_lookup.md)
shows everything known about an EIN, and
[`md_cluster()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_cluster.md)
shows its families. The database is about 10 GB, and
[`md_fetch_db()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_fetch_reference.md)
downloads it once.

``` r

md_fetch_db()
md_cluster("39-1925617", types = c("related_system", "shared_website"))
#> <md_cluster> EIN-39-1925617: 4 clusters (related_system 3, shared_website 1)
#>
#>   SYS-87-4664285  related_system, 2 members  BOYS & GIRLS CLUB OF DANE COUNTY FOUNDATION INC
#>       EIN-87-4664285  BOYS & GIRLS CLUB OF DANE COUNTY FOUNDAT WI
#>     * EIN-39-1925617  BOYS AND GIRLS CLUB OF DANE COUNTY INC WI
#>
#>   WEB-bgcdc.org  shared_website, 3 members
#>     * EIN-39-1925617  BOYS AND GIRLS CLUB OF DANE COUNTY INC WI
#>       EIN-87-4618323  BOYS & GIRLS CLUB OF DANE COUNTY LEGACY  WI
#>       EIN-87-4664285  BOYS & GIRLS CLUB OF DANE COUNTY FOUNDAT WI
#>   ...
```

The club, its foundation and its legacy fund share a website, two
addresses and a Schedule R relationship. The tie in g3 is between them.
Whether a grant “to the Boys & Girls Club” belongs to the club or its
foundation is a judgement the data can only flag. The club, the
operating entity, is the usual answer.

``` r

x <- md_lookup("53-0196605")
x
#> <md_lookup> EIN-53-0196605  AMERICAN NATIONAL RED CROSS
#>   layer bmf_active, active TRUE, NTEE P210, subsection 3
#>   names      1800 rows (dba 1, in_care_of 1, legal 2, observed 1796)
#>   addresses  2863 rows
#>   ...
head(x$names[x$names$variant_class == "observed", c("name_raw", "n_corroborators")])
#>                                   name_raw n_corroborators
#> 4                       AMERICAN RED CROSS            1292
#> 5              AMERICAN NATIONAL RED CROSS             377
#> 6                                RED CROSS              40
#> 7 AMERICAN RED CROSS NATIONAL HEADQUARTERS              35
#> 8                   THE AMERICAN RED CROSS              24
#> 9            AMERICAN RED CROSS - NATIONAL              19
```

1,292 different grantmakers wrote `AMERICAN RED CROSS` for this EIN.
That is why `active-observed` carries the spelling, and why g1 found the
right organization even though the name is not the legal one.

## 6. Match one level up

Two npmatch functions read those families alongside the scored
candidates.

`np_pair_links()` reports whether each query’s top two candidates are
one family:

``` r

npmatch::np_pair_links(m, b$clusters)[, c(".id", "top_ein", "runner_up_ein", "linked", "link_types")]
#>   .id        top_ein  runner_up_ein linked                              link_types
#> 1  g1 EIN-53-0196605 EIN-52-0743599   TRUE                               co_tenant
#> 2  g2 EIN-04-2994233 EIN-04-3348433   TRUE                   brand;group_exemption
#> 3  g3 EIN-39-1925617 EIN-87-4664285   TRUE co_tenant;related_system;shared_website
#> 4  g4 EIN-01-0498465 EIN-47-5330473  FALSE
```

A tie between linked EINs (g3) is a family to settle. A tie between
strangers is a real ambiguity.

`np_cluster_rollup()` handles split evidence: the name matches one
member of a family and the address another, so no single EIN scores well
but the family does. It returns nothing for these four, because each
found its organization directly. On 1,984 Schedule I records with a
known EIN, it placed 60 of 739 non-YES records in a family, and the true
EIN was in that family 90% of the time.

``` r

npmatch::np_cluster_rollup(m, b$clusters, query = npmatch::np_normalize(q))
```

## 7. Build your own reference

The published tiers cover the common cases. For anything else, describe
the slice with
[`md_spec()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_spec.md)
and compile it from the database:

``` r

s <- md_spec(layers = c("bmf_active", "bmf_inactive", "postcard_only"),
             names = c("legal", "dba", "observed"),
             addresses = c("mailing", "observed"),
             min_corroborators = 2,
             label = "everything-small-orgs-too")
r <- md_compile(s)
#> spec 5f3050225dde786f: 5,211,807 rows over 3,771,700 EINs
r$report          # rows by class, rows per EIN, family members left out

m2 <- npmatch::np_cascade(q, r$reference, name_freq = r$name_freq,
                          token_idf = r$token_idf,
                          ref_index = npmatch::np_ref_index(r$reference))
```

A spec has a hash, so the same spec always gives the same reference on
any machine. To keep a slice, `md_publish(s)` writes it as a stamped
bundle, and `md_reference("everything-small-orgs-too")` reads it back.

## Next

- [`vignette("layers")`](https://nonprofit-open-data-collective.github.io/matchdb/articles/layers.md):
  which organizations to include.
- [`vignette("sources")`](https://nonprofit-open-data-collective.github.io/matchdb/articles/sources.md):
  where every name and address comes from.
- [`vignette("corroborators")`](https://nonprofit-open-data-collective.github.io/matchdb/articles/corroborators.md):
  how much to trust a name a grantmaker wrote, and why
  `min_corroborators = 2` is the default.
