# Why 527 Schedule B is not a matchdb source

`2024-11-POL-ORGS-SCHED-B.csv` (1.33 GB, 6,936,571 rows) records what a
527 *paid out*: filer `EIN` and `ORG_NAME` on one side,
`RECIEPIENT_NAME` plus an address on the other, with
`EXPENDITURE_AMOUNT`, `EXPENDITURE_PURPOSE` and `EXPENDITURE_DATE`.

## Details

**The recipient has no EIN.** That makes the file structurally identical
to 990-PF Part XIV grants - a payer identified by EIN, a payee
identified only by a name and address someone typed. It is therefore a
*query-side* dataset: the kind of file you run **against** a
disambiguation database, exactly as `pfmatch` runs grants against the
reference. It is not a source of `(name -> EIN)` observations, because
the EIN on the row belongs to the payer, not to the name being
described.

Ingesting it as a `name` source would attach every payee's name to the
*payer's* EIN - aliasing "Hawaii Republican Party" onto a teachers'
union PAC. That is the single most destructive thing that could be done
to a disambiguation reference, and the row shape makes it an easy
mistake, which is why the exclusion is written down rather than left
implicit.

Two further reasons it does not belong on the reference side: most
payees are political committees, candidates and vendors rather than
exempt organisations; and `RECIPIENT_OCCUPATION` and
`RECIEPIENT_EMPLOYER` are individual-level fields, so a large share of
rows describe people, who have no place in an organisational reference.

The file is kept under `sources/query-side/` as a future matching
workload.
