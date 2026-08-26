# Workflow 5 — Drift Detection (scheduled)

**Workflow file:** [`../drift-detection.yml`](../drift-detection.yml) · **Actions name:** `5. Drift Detection (scheduled)`

Detects tenant changes since yesterday and opens an issue when found.

**Can it change the tenant?** No. Only writes a snapshot file committed back to this repo.

No remote backend, so `terraform plan` has no prior state to compare against — every run looks like a first run. This workflow compares successive read-only snapshots instead, which also catches objects nobody manages in Terraform (e.g. a role created by hand in the console).

## How it works

```
terraform plan (read-only)  →  snapshot.sh  →  diff.sh  →  issue + new baseline
        data blocks only        fingerprint     compare
```

1. **Read** the tenant via the `access-audit` and `tenant-inventory` modules (both `data`-only).
2. **Fingerprint** with [`snapshot.sh`](../../../scripts/drift/snapshot.sh) — reduced, sorted, privacy-safe JSON.
3. **Compare** against the committed baseline with [`diff.sh`](../../../scripts/drift/diff.sh).
4. **Report** — table to the run summary; open a GitHub issue if anything changed.
5. **Advance** the baseline.

### Schedule

Daily at **08:00 UTC**. Manual trigger: **Actions** → **5. Drift Detection (scheduled)** → **Run workflow**.

| Input | Default | Notes |
|---|---|---|
| `update_baseline` | `true` | Uncheck to inspect drift without accepting it — same drift reports again next run. |

Scheduled runs always advance the baseline.

## Privacy

Baseline is committed to a **public** repo, enforced two ways:

1. Workflow hard-codes `TF_VAR_access_audit_redact_usernames: "true"` — SHA-256 hashed before reaching the file.
2. `snapshot.sh` greps its own output for an email address; if found, deletes the file and fails the run.

Hashing is one-way and stable — trackable across snapshots without revealing identity.

## Reading the report

| Kind | Meaning |
|---|---|
| **added** | Present now, absent in the baseline |
| **removed** | Present in the baseline, gone now |
| **modified** | Same name, different contents (was → now) |

Counts reported separately from object lists.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No drift |
| `2` | Drift detected |
| `1` | Script failed |

A missing baseline is not drift — first run exits `0` and establishes the baseline.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

Needs `contents: write` (commit baseline) and `issues: write` (open drift issue) — both declared in the workflow file. The `drift` label auto-creates on first issue.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Every run reports drift | Baseline isn't advancing — check if `update_baseline` was left unchecked. |
| First run reported nothing | Expected — baseline was just created. |
| `snapshot contained an email address` | Redaction disabled. File deleted, not committed. Restore `TF_VAR_access_audit_redact_usernames: "true"`. |
| Push rejected on baseline commit | Concurrent commit won the race. Retries once with `git pull --rebase`; re-run if still failing. |
| Issue not created | Check `issues: write` permission and that the diff step reported `drift=true`. |
| Huge diff after provider upgrade | New fields read as "modified" everywhere. Accept the baseline once. |

## Files

| Path | Role |
|---|---|
| [`../drift-detection.yml`](../drift-detection.yml) | The workflow |
| [`../../../scripts/drift/snapshot.sh`](../../../scripts/drift/snapshot.sh) | Plan JSON → privacy-safe fingerprint |
| [`../../../scripts/drift/diff.sh`](../../../scripts/drift/diff.sh) | Baseline vs current → markdown + exit code |
| `.drift/tenant-snapshot.json` | The committed baseline |
