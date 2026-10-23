# Corroborators: how much to trust a name someone else wrote

An `observed` name is one written by a third party: a grantmaker on
Schedule I, or a related organization on Schedule R, writing a name next
to an EIN. These aliases are the reason matchdb outperforms the BMF
alone. Grant records use the names people actually write, and a
reference that has seen those spellings matches them directly.

But one filer’s typo and a name fifty foundations wrote independently
are both “observed names”. **`n_corroborators` separates them**: it
counts the **distinct filers** who wrote that name for that EIN.

## What a corroborator is

Schedule I rows are grouped by EIN and a light name key (uppercased,
punctuation stripped, spaces collapsed). For each group matchdb stores:

- `n_corroborators`: distinct filing EINs that wrote it;
- `n_obs`: total times it was written, across all filings and years;
- `first_year`, `last_year`: when it was seen;
- `name_raw`: the most frequently written spelling.

A foundation that writes the same name in ten annual returns is one
corroborator with ten observations. Ten foundations each writing it once
are ten corroborators. Repetition by one filer is habit; agreement
across filers is evidence.

## How corroboration is distributed

Observed names by corroborator count, build of 2026-10-23:

| distinct filers |     names | mean times written |
|-----------------|----------:|-------------------:|
| 1               | 1,520,042 |                2.3 |
| 2               |   196,658 |                5.7 |
| 3               |    82,615 |                9.0 |
| 4               |    45,861 |               12.5 |
| 5 or more       |   140,294 |               66.0 |

Most observed names, 77%, were written by a single filer.

## Bands, and choosing a threshold

`md_spec(min_corroborators = ...)` keeps observed names written by at
least that many filers. It applies to `observed` names only; first-party
names (BMF, the organization’s own filings) are always kept. The value
must be a band edge, **1, 2, 5 or 20**, because corpus statistics are
precomputed per band and summed. A threshold between edges would cut
across bands.

``` r
library(matchdb)
s <- md_spec(layers = "bmf_active",
             names = c("legal", "dba", "observed"),
             addresses = c("mailing", "observed"),
             min_corroborators = 2)
```

The threshold changes match results. On pfmatch’s 1k grant benchmark
(`dev/verify/phase2-measure.R`), matched against active organizations:

| reference                      |       YES | MAYBE |  NO |
|--------------------------------|----------:|------:|----:|
| legal and DBA names only       |     2,946 |   943 | 854 |
| plus observed names, 2+ filers | **3,092** |   940 | 717 |
| plus observed names, 1+ filer  |     2,419 | 1,702 | 648 |

With two or more filers, aliases add **146 YES** (295 gained, 149 lost).
Letting in single-filer aliases instead **loses 527 YES**: 391 gained,
918 lost. The likely cause is the name-frequency effect `dev/PROCESS.md`
section 0c identified. Adding 1.5 million names, many of them noisy,
makes common words look less distinctive and creates near-ties between
candidates, so confident matches become MAYBEs.

**Use `min_corroborators = 2`** unless you have measured otherwise on
your own records. The published `*-observed` tiers use it.

## What corroboration does not catch

Some errors repeat across filers because the same habit repeats:

- writing a **placeholder EIN** (`00-0000000`, `123456789`);
- writing the **filer’s own EIN** for a grantee;
- writing a **group-ruling central’s EIN** for one of its congregations;
- writing a **fiscal sponsor’s EIN** for each project it sponsors.

Each of these can be corroborated many times and still be wrong. matchdb
flags them rather than deleting them
([`md_guard_observed()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_guard_observed.md)).
Each observed name carries `flag_placeholder_ein`,
`flag_placeholder_name`, `flag_own_ein`, `flag_group_central`,
`flag_multi_name`, and `guard_any` for any of the five.
[`md_compile()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_compile.md)
always leaves guarded names out of a reference.

Corroboration and the guards answer different questions. Corroboration
asks how many independent writers agree. The guards ask whether the EIN
they wrote could be this organization at all.

## Looking at the evidence for one organization

``` r
x <- md_lookup("53-0196605")
obs <- x$names[x$names$variant_class == "observed", ]
head(obs[order(-obs$n_corroborators),
         c("name_raw", "source", "n_corroborators", "n_obs", "first_year", "last_year")])
```

Observed addresses keep the name they were written with (`observed_as`
in
[`md_lookup()`](https://nonprofit-open-data-collective.github.io/matchdb/reference/md_lookup.md)).
A compiled reference therefore pairs each alias with its own address,
rather than every alias with every address.
