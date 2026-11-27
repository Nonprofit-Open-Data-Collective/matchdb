# `md_reference(fetch = "missing")` keeps a stale bundle after a republish

This dev note comes from the intermediaries project (`Nonprofit-Open-Data-Collective/intermediaries`) and is dated 2026-11-26. It was found while preparing the full TY2021–2024 990-PF match in pfmatch, which loads its reference with `matchdb::md_reference(tier, fetch = "missing")`.

**Request:** `md_reference()` should detect that a local bundle no longer matches what the remote publishes under the same `label/spec_hash`, and download it again. That covers the case where the remote republished the bundle under a new normalizer. The error message for a signature mismatch should also say what to run.

---

## 1. What happened

| | Local copy | Remote (`latest.json` → `active-observed`) |
|---|---|---|
| spec hash | `9cc7b76e3e144a87` | `9cc7b76e3e144a87` |
| `stamp.json` normalizer | `v1-6dcb298522cc5118` | `v1-5e901add4a04a5d6` |
| installed npnormalize 0.1.8 / 0.1.9 | — | `v1-5e901add4a04a5d6` |

The local bundle was fetched before npnormalize changed. The bundle was then rebuilt and republished at the **same** path, because the spec hash does not depend on the normalizer. When pfmatch called `md_reference("active-observed", fetch = "missing")`:

1. `local_has()` (`R/md-publish.R:149`) found `latest.json` with an `active-observed` entry and returned `TRUE`, so nothing was fetched.
2. The local `stamp.json` failed the signature check (`R/md-publish.R:167`), and `md_reference()` stopped with:

   > bundle active-observed/9cc7b76e3e144a87 was built by normalizer v1-6dcb298522cc5118; the installed one is v1-5e901add4a04a5d6. … - republish it.

That message sends the user the wrong way. Nothing needed republishing, because the remote was already correct. The local copy only needed to be fetched again. Most users of a downloaded reference can't republish anyway; they don't have the database.

**Workaround used:**
1. Move the local directory aside to `…/9cc7b76e3e144a87.stale-2026-10-23`.
2. Run `md_fetch_reference("active-observed")`.

`md_reference(..., fetch = TRUE)` would also have worked, because `md_fetch_reference()` downloads a fresh `stamp.json` and replaces every file whose md5 differs. So only the `"missing"` mode has the bug. That is the mode pfmatch uses by default, so every pfmatch user with an older cache hits this after a normalizer change.

## 2. Why it will recur

- **The spec hash leaves out the normalizer.** `.md_spec_hash()` (`R/md-spec.R:149`) hashes the spec keys only: layers, names, addresses, sources and so on. A rebuild under a new normalizer keeps the same path, so "it's here" can't mean "it's current".
- **"missing" only checks that a bundle exists.** It never compares the local copy with the remote stamp.
- **The signature check runs after the fetch decision.** By the time the mismatch is found, `md_reference()` has already decided not to download.
- **Wrong advice in the error.** The only advice offered is "republish it".

## 3. Proposed fix, cheapest first

1. **Fetch again when the signature doesn't match.** In `md_reference()`, when the local stamp's `normalize_signature` differs from the installed one and `fetch` is not `FALSE`, call `md_fetch_reference(label, spec_hash, root = root)` once and re-read the stamp. Stop only if it still differs. This is a few lines and needs no network call in the normal case. Make the same change in the `spec_hash`-pinned branch of `local_has()`.

2. **Fix the error message.** Name the two causes and their remedies:
   - the local copy is older than the remote: run `md_fetch_reference("<label>")` or `md_reference(..., fetch = TRUE)`;
   - the remote itself was built by another normalizer: install npnormalize `<version from stamp>`, or republish.

   The stamp already records the normalizer version (`.md_normalizer_versions()`), so the message can name the version to install.

3. **Make "missing" mean "missing or stale".** Download the remote `stamp.json` (small) and compare its md5 with the local one. Reuse the local copy only when they match. If the remote can't be reached, use the local copy with a warning. This catches every republish, including one that keeps the normalizer but changes the data, at the cost of one small request per load.

4. **Put the normalizer in the path, or record a build id.** Either include `normalize_signature` in the spec hash, or keep the spec hash and add a `build` field to `latest.json` and the stamp that `md_reference()` compares. This is the structural fix: a pinned `spec_hash` would then always mean the same bytes, which matters for reproducibility. A paper that cites `active-observed/9cc7b76e3e144a87` currently can't tell which build it used.

**Suggested:** options 1 and 2 now, and option 3 or 4 with the retention rule work (`dev/` retention notes, commits `7d9d775`/`da0fd0c`). Republishing in place and retaining versions interact: if old builds are kept, they need distinct paths.

## 4. Tests to add

- A local bundle stamped with signature A and a `file://` remote stamped with B, under the same spec hash: `md_reference(fetch = "missing")` fetches and returns B.
- The same setup with an unreachable remote: a clear error saying the local copy is stale and the remote can't be reached, with the fetch command.
- A local copy that matches the remote: no download. Check with the `fetch_reference` log row, or a mocked `.md_download`.

## 5. Downstream

pfmatch's `pf_reference(source = "matchdb")` documentation (`R/pipeline.R:96–107`) describes the download-once behaviour and the fallback after a normalizer update. Update it once this lands, so the pfmatch error path points at `md_fetch_reference()` rather than at republishing.
