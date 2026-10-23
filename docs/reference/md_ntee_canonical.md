# The NTEE crosswalk is canonical, and its nteev2 columns are not

`ntee_resolved_crosswalk` supersedes the BMF's NTEE fields because it
carries provenance: per-EIN it gives `ntee_current`, `ntee_most_recent`
and `ntee_modal`, each with a subsector and an nteev2 rendering, plus
`ntee_most_recent_source`, `n_vintages_with_ntee`, `n_distinct_codes`,
an `ntee_agreement` verdict, and `ntee_code_distribution` - a JSON
object giving each observed code's count and first/last vintage.

## NTEE is not an invariant trait

Measured on a 400,000-row sample: `ntee_agreement` is `unanimous` for
62%, **`mixed` for 31%**, and `single` for 7%. Roughly a third of
organisations have been classified inconsistently across vintages. Any
schema that stores one NTEE code per EIN without saying which rule
produced it, and without surfacing that the underlying history
disagreed, is presenting a coin flip as a fact.

Note also that `ntee_current` is populated for only 34.7% of rows while
`ntee_most_recent` is populated for 100%. `current` means "currently
listed", not "the current value" - most EINs in the unified file are not
in the active BMF at all.

## The nteev2 columns carry the known defect

They are populated, and they must still be recomputed with
[`fiscal::get_nteev2()`](https://rdrr.io/pkg/fiscal/man/get_nteev2.html)
rather than taken as given. The specialty double-encoding documented in
`pfmatch/dev/SCHEDI-ALIAS-FINDINGS.md` §6d is present: `B11` renders as
`EDU-B11-MS` where the correct value is `EDU-B00-MS`. In NTEEv2 the
digits 01-19 encode organisation *type*, not activity, so the activity
slot is `B00` and the type is carried by the `MS` suffix - this file
emits `11` in both slots.

21,983 of the 400,000 sampled rows (5.5%) carry a 10-19 org-type code
and are affected. Others seen: `D11 -> ENV-D11-MS`, `S11 -> PSB-S11-MS`,
`N12 -> HMS-N12-MM`, `X19 -> REL-X19-NS`.

Recompute from `ntee_code_raw`, not from a cleaned three-character code:
the legacy five-character form carries the `B8443 -> B43` rule, which
truncation destroys.
