# Publishing checklist

## Suggested repository details

- **Name:** `purchase-to-pay-analytics`
- **Description:** Procurement analytics with Python and SQL: grain-safe spend, invoice exceptions, supplier history, and reconciled corrections. Locally tested; Snowflake execution pending.
- **Topics:** `python`, `sql`, `snowflake`, `sqlite`, `data-analytics`, `data-engineering`, `procurement`, `dimensional-modeling`, `data-quality`, `portfolio-project`
- **Website:** Leave blank unless you have an actual deployed demo. This repository does not include a hosted dashboard.

Keep the local-versus-cloud distinction in the description. Do not add passing CI, deployment, license, or performance badges without matching evidence.

## Use the clean export

The working project belongs to a larger local workspace that contains unrelated projects. Publishing that workspace root could expose other work.

A source-only copy is prepared locally at:

```text
artifacts/github-ready/purchase-to-pay-analytics/
```

A matching ZIP is available at:

```text
artifacts/github-ready/purchase-to-pay-analytics.zip
```

These paths are relative to the working project, not files shipped inside the export itself. The export includes documentation, source, tests, Git hygiene files, and a sanitized local-validation snapshot. It excludes `.git`, generated data, SQLite databases, raw reports/logs, credentials, and other workspace projects. Raw local reports and database audit rows can contain the input/database paths supplied at runtime; do not publish them without inspecting and sanitizing those fields.

Use a separate folder outside the shared workspace for the new repository. Extract the ZIP there, then open the extracted `purchase-to-pay-analytics/` folder. Do not initialize a nested repository inside the original shared workspace.

## Before publishing

1. Review the README and project claims. Local checks passed; Snowflake execution and cloud metrics are still pending.
2. Confirm your ownership and any employer or institutional publication requirements. Synthetic transaction data does not by itself settle code ownership.
3. Choose a software license if you want to grant others permission to reuse the code. No license has been selected automatically.
4. From the clean export, generate data, run the validator, and run the regression tests using the README commands. Generated outputs should remain untracked.
5. Inspect staged files. Do not include passwords, private keys, connection files, personal paths, databases, or unrelated projects.
6. Complete any applicable pre-push verification gates in your development environment. The recorded local tests are not evidence of mutation testing or live Snowflake integration.

No CI workflow, remote repository, commit, or push was created as part of preparing this package.

## Publish using Git

Create an empty GitHub repository with your chosen name. For the command-line route below, do not initialize that remote with another README or license; those can cause a first-push history conflict. If the remote already contains commits, clone it separately and integrate the prepared files instead of forcing a push.

Run these commands only from the extracted standalone project folder, after completing the checks above:

```bash
git init -b main
git add README.md .gitignore .gitattributes scripts sql tests docs
git status --short
git diff --cached --stat
git diff --cached
git commit -m "Add purchase-to-pay analytics portfolio project"
```

Copy the actual remote URL from your GitHub repository's Code button. Replace the placeholder below before running either command:

```bash
git remote add origin <your-actual-repository-url>
git push -u origin main
```

These are manual instructions, not actions already performed. Authentication must be configured through your normal GitHub sign-in process, not by placing a token in source files or a remote URL.

## Publish using the website

For a small source-only project, you can instead upload the extracted files through GitHub's upload-files screen. Upload the folder's contents, preserving `scripts/`, `sql/`, `tests/`, and `docs/`; do not upload the ZIP as a replacement for the actual source tree. Include the dotfiles `.gitignore` and `.gitattributes`.

After publication:

- Confirm the README and Mermaid diagrams render.
- Check that documentation links open correctly.
- Confirm the source folders, tests, and portable evidence are visible.
- Confirm `data/`, `artifacts/`, databases, credentials, and private file paths are absent.
- Add the repository description and topics, then pin it on your profile if desired.

## Evidence included

[local-validation.json](evidence/local-validation.json) is a compact, sanitized snapshot derived from a real local run. It records 12 passing tests, 227 passing reconciliation checks, deterministic generation, replay/correction results, and source hashes. It is not an automatically updating CI report and does not claim Snowflake verification.

To refresh the snapshot later, rerun validation and tests, confirm the outcomes, and update the evidence from actual results. Never mark cloud checks as passed from local SQLite evidence.