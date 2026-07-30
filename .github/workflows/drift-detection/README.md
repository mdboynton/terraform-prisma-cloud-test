# Workflow 5 — Drift Detection (scheduled)

**Workflow file:** [`../drift-detection.yml`](../drift-detection.yml) · **Actions name:** `5. Drift Detection (scheduled)`

Answers "did anything change in the tenant since yesterday?" and opens an issue
when the answer is yes.

**Can it change the tenant?** No. The only thing it writes is a snapshot file
committed back to this repo.

---

## Why snapshots instead of `terraform plan`

The usual way to detect drift is to run `terraform plan` and see if Terraform
wants to change anything. That does not work here, for a structural reason:

**This repo has no remote backend.** State is local to each Actions job and
discarded when the job ends. Terraform therefore has no prior state to compare
the tenant against, and every run looks like a first run.

Comparing successive **read-only snapshots** answers the same question without a
backend. It also covers something `terraform plan` never would: objects nobody
manages in Terraform — which is most of this tenant. A role created by hand in
the console is invisible to `plan` but shows up here immediately.

If a remote backend is added later, real plan-based drift detection becomes
possible and this workflow can be revisited. It stays useful either way, because
of the unmanaged-object coverage.

---

## How it works

```
terraform plan (read-only)  →  snapshot.sh  →  diff.sh  →  issue + new baseline
        data blocks only        fingerprint     compare
```

1. **Read** the tenant via the `access-audit` and `tenant-inventory` modules
   (both `data`-only).
2. **Fingerprint** the result with [`snapshot.sh`](../../../scripts/drift/snapshot.sh)
   — a reduced, sorted, privacy-safe JSON document.
3. **Compare** against the committed baseline with
   [`diff.sh`](../../../scripts/drift/diff.sh).
4. **Report** — write a table to the run summary, and open a GitHub issue if
   anything changed.
5. **Advance** the baseline so tomorrow reports only what changed since today.

### Schedule

Runs daily at **08:00 UTC** (~midnight US Pacific). GitHub's cron is best-effort
and can be delayed under load; this job is not time-critical.

You can also trigger it manually: **Actions** → **5. Drift Detection
(scheduled)** → **Run workflow**.

| Input | Default | Notes |
|---|---|---|
| `update_baseline` | `true` | Uncheck to inspect drift **without** accepting it — the report is produced but the baseline is left alone, so the same drift is reported again next run. |

On a schedule the baseline always advances. Otherwise a single change would be
re-reported every day forever.

---

## Privacy — why the snapshot is safe to commit

The baseline is committed to a **public** repo, so this is enforced in two
independent places:

1. The workflow hard-codes `TF_VAR_access_audit_redact_usernames: "true"`, so
   usernames are SHA-256 hashed before they ever reach the file.
2. `snapshot.sh` independently greps its own output for an email address and, if
   it finds one, **deletes the file** and fails the run.

The second check exists so that flipping the first to `false` breaks the
workflow rather than leaking. Hashes are stable, so a hashed user is still
trackable across snapshots — you can tell that *a* user changed without learning
who.

Note that hashing is one-way on purpose. Encoding (`base64`) would be
reversible and is not redaction.

---

## Reading the report

The summary lists three kinds of change per category:

| Kind | Meaning |
|---|---|
| **added** | Present now, absent in the baseline |
| **removed** | Present in the baseline, gone now |
| **modified** | Same name, different contents (the report shows was → now) |

Counts are reported separately from the object lists, so a bulk change reads as
one count delta rather than hundreds of rows.

### Exit codes

`diff.sh` uses exit codes as its interface, and they are deliberately not the
shell defaults:

| Code | Meaning |
|---|---|
| `0` | No drift |
| `2` | Drift detected |
| `1` | The script itself failed |

Drift is `2` rather than `1` so that a genuine script failure is never
misreported as "the tenant changed."

**A missing baseline is not drift.** The first run has nothing to compare
against, so it exits `0`, says so, and establishes the baseline — rather than
opening a spurious issue on day one.

---

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

The workflow needs `contents: write` (to commit the baseline) and `issues: write`
(to open the drift issue). Both are declared in the workflow file; no repo
setting is required.

The `drift` label is created automatically the first time an issue is opened —
you do not need to create it by hand.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Every run reports drift | The baseline isn't advancing. Check whether the **Update baseline** step is being skipped — a manual run with `update_baseline` unchecked does exactly this. |
| First run reported nothing | Expected. There was no baseline; it was just created. |
| Run failed with "snapshot contained an email address" | Redaction was disabled. The output was deleted rather than committed. Restore `TF_VAR_access_audit_redact_usernames: "true"`. |
| Push rejected on the baseline commit | A concurrent commit to `main` won the race. The step retries once with `git pull --rebase`; if it still fails, re-run the workflow. |
| Issue not created | Check the run has `issues: write` and that the diff step reported `drift=true`. |
| Huge diff after a provider upgrade | A new provider version can add fields, which reads as "modified" everywhere. Accept the baseline once and subsequent runs return to normal. |

## Files

| Path | Role |
|---|---|
| [`../drift-detection.yml`](../drift-detection.yml) | The workflow |
| [`../../../scripts/drift/snapshot.sh`](../../../scripts/drift/snapshot.sh) | Plan JSON → privacy-safe fingerprint |
| [`../../../scripts/drift/diff.sh`](../../../scripts/drift/diff.sh) | Baseline vs current → markdown + exit code |
| `.drift/tenant-snapshot.json` | The committed baseline |
