# The published release's version retention

`s3-lifecycle.json` is **applied**, as of 2026-11-03. It is the bucket's only
lifecycle rule. S3's read-back matches the file field for field, including
`NewerNoncurrentVersions`, which is worth saying because the CLI here predates
that field by weeks and a field the CLI does not model is dropped in silence
rather than refused.

Applying it deleted nothing. Expiry is bounded by `NoncurrentDays`, and the
oldest noncurrent version became noncurrent on 2026-10-22, so the first
deletions fall due around **2026-11-21** — about three weeks of room to change
course.

## What it is for

`s3://nccs-efile` has versioning enabled and, as of 2026-11-03, no lifecycle
configuration at all. Nothing ever expires. Every release makes the previous
`MATCHDB.duckdb` and `MATCHDB-full.duckdb` noncurrent rather than replacing
them, so each release adds about **38 GB that is then kept forever** — 11.85 GB
of user copy plus 26.51 GB of maintainer copy, at current sizes.

The accumulated total today is 128.05 GB of noncurrent versions: 48.58 GB across
two versions of the maintainer copy, and 79.47 GB across eight of the user copy,
the oldest from 2026-10-22. The present cost of that is about three dollars a
month, which is not the argument. The argument is the slope: at roughly a release
a week it is about 2 TB a year, and it grows without anyone deciding to let it.

## What the rule does

```json
"NoncurrentVersionExpiration": {
  "NewerNoncurrentVersions": 2,
  "NoncurrentDays": 30
}
```

A noncurrent version is deleted only when **both** conditions hold: at least two
*newer* noncurrent versions exist, and it has been noncurrent for at least 30
days. So the two most recent superseded releases are kept indefinitely whatever
their age, which gives three generations — current plus two — to roll back to,
and anything newer than 30 days is kept regardless.

Applied today, that keeps both maintainer versions (neither has two newer
noncurrent versions yet) and both of the two most recent user versions, and
expires the six user versions from 2026-10-22 to 2026-10-24 — 55.97 GB — as they
pass 30 days noncurrent, which falls around 2026-11-22.

```json
"AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
```

Insurance, not a current problem: the maintainer copy uploads as 3,161 parts, and
a failed multipart upload leaves parts that are billed but appear in no object
listing. There are none orphaned right now — the 2026-11-01 upload aborted at the
logs step, after both databases had completed — but that is luck about *where* it
failed, not a property of the upload.

## Before applying it

- **The prefix matters.** `nccs-efile` is not a matchdb bucket; it holds NCCS
  e-file data. The filter is `dev/matchdb/` and must stay scoped. A rule written
  without a prefix applies to every object in the bucket.
- **There is no `Expiration` block, deliberately.** That field acts on *current*
  versions — it would delete the live release. Check it is still absent before
  applying.
- **`put-bucket-lifecycle-configuration` replaces the whole configuration**, it
  does not merge. There is nothing to lose today because there is no
  configuration, but anyone re-applying this file later would silently drop rules
  added in between. Always `get` first.
- **Do not add `NoncurrentVersionTransitions` at this prefix.** Moving noncurrent
  versions to IA or Glacier looks like free money on a 26 GB database, but the
  prefix also holds manifests, pins and logs of a few kilobytes each, and the
  colder classes bill a 128 KB minimum per object plus a per-object transition
  request. On thousands of small objects that costs more than it saves. If the
  saving is wanted, scope a separate rule to the two database keys.
- **This does not touch superseded bundles.** `publish/` is signature-keyed, so a
  new normalizer writes new *keys*, not new versions of old ones. Those stay
  current objects and are kept on purpose, so a client pinned to an older
  signature keeps working. What to retain there is a different question, and it
  is not answered here.

## Changing it, later

```
aws s3api get-bucket-lifecycle-configuration --bucket nccs-efile
aws s3api put-bucket-lifecycle-configuration --bucket nccs-efile \
  --lifecycle-configuration file://dev/verify/release/s3-lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket nccs-efile
```

Read first, every time. When this was first applied the `get` was expected to
fail with `NoSuchLifecycleConfiguration`, and did. **That is no longer the
case**: the bucket now has a configuration, so a `put` from this file overwrites
whatever is there, including rules someone else added for another prefix. If the
`get` returns anything this file does not contain, merge it in before putting.

The third call confirms what took effect, and is not a formality — it is the
only way to see that a field the CLI does not understand was dropped.

