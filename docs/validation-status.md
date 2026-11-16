# Validation status

**Local validation passed. Snowflake execution is pending.**

Observed with Python 3.12.10, standard-library SQLite, seed 42, and reporting date 2025-03-31. These are real local results, not Snowflake results.

## Executed checks

| Check | Observed result |
| --- | --- |
| Python syntax parsing | All three Python source files passed |
| Public-behavior regression suite | 12 tests, 0 failures, 0 errors |
| Source/target, fixture, and replay checks | 227 passed, 0 failed |
| Same seed generated twice | All 13 output files byte-identical |
| Seed 43 versus seed 42 | Output changed |
| Base load | 1,168 latest-source rows applied |
| Identical base replay | 0 latest-source rows applied; unchanged mart snapshot |
| Correction load | 4 latest-source rows updated |
| Identical correction replay | 0 latest-source rows applied; unchanged mart snapshot |

Base source volume: 25 supplier IDs represented by 26 effective-date versions, 123 PO headers, 370 PO lines, 138 invoice headers, 391 invoice lines, and 120 payment allocations. Multiple lines and multiple payments are present; counts do not grow when mart snapshots are replayed. Raw local audit rows intentionally append on every load attempt; do not confuse this with duplicated facts. Snowflake additionally uses COPY file-load history, whose behavior has not yet been tested here.

## Source-to-fact reconciliation

Every row-count and cents delta between latest source records and its corresponding fact was zero, in all four phases.

| Fact / source | Rows | Base source cents | Base fact cents | Corrected source cents | Corrected fact cents |
| --- | ---: | ---: | ---: | ---: | ---: |
| Purchasing / PO lines | 370 | 29,024,791 | 29,024,791 | 29,024,791 | 29,024,791 |
| Invoicing / invoice lines | 391 | 19,795,895 | 19,795,895 | 19,797,895 | 19,797,895 |
| Payments / payment allocations | 120 | 13,712,761 | 13,712,761 | 13,713,761 | 13,713,761 |

The payment totals above include all payment dates for source-to-fact reconciliation. Historical balance views separately exclude payments after the reporting date.

Header totals exceed line totals by 300 cents in both snapshots because deliberately mismatched headers are included. The warehouse classifies those discrepancies; it does not rewrite amounts to hide them. The invoice correction raises both its header and line-derived amount by 2,000 cents. The payment correction adds 1,000 cents. A supplier version's category is restated from OFFICE to TECHNOLOGY with unchanged transaction totals and version count.

## Example analytical outputs

Corrected local snapshot, as of 2025-03-31:

| Metric | Observed synthetic result |
| --- | ---: |
| Total invoiced spend | $197,978.95 |
| Top-five supplier spend share | 32.13% |
| HHI, fraction scale | 0.05046848 |
| Spend without a PO reference | $21,616.96 |
| Spend with an invalid PO reference | $70.00 |
| Combined unmatched-reference spend | $21,686.96 |
| Overdue invoices with positive balances | 53 |
| Total overdue positive balance | $56,824.80 |

`SUP_022` has the highest exception rate at 100%, but that represents only 3 invoices. Among suppliers with at least 5 invoices, `SUP_005` is highest at 62.5% (5 of 8), followed by `SUP_023` at 60% (3 of 5). The five-invoice filter is a presentation choice, not a change to the underlying exception-rate definition.

These describe the fictional dataset only. They are not market benchmarks or findings about a real company.

## Behavior coverage

The tests cover multi-line/multi-payment joins without multiplication, future payment exclusion, partial and excess payments, due-date boundaries, header discrepancies, overlapping flags, duplicate invoice numbers, timestamp conflicts with atomic rollback, stale-batch protection, rejection of unseen stale corrections while retaining known correction replays, the 2025 date boundary, incremental corrections, effective-date interval insertion and fact reattribution, zero-value invoice settlement, and failure reports when supplied correction expectations are wrong. A zero-total invoice is treated as settled on its invoice date without cash; days_late is signed and can be negative for early settlement.

The expectation checks read generator metadata, and separate hand-constructed unit fixtures test model behavior independently. Reconciliation alone cannot prove every business definition is correct; live Snowflake integration is still required.

## Evidence files and reproduction

The checked-in [portable evidence snapshot](evidence/local-validation.json) preserves the measured test outcomes, reconciliation totals, replay results, reproducibility checks, and tested source hashes. It omits private filesystem paths and raw database files. It is a recorded local result, not a live CI status.

Full local runs produce `local.sqlite`, `reconciliation.json`, and `reconciliation.md` in the selected output directory. Additional build-session test summaries and logs were inspected to prepare the portable snapshot, but are not required outputs of the normal CLI and are not included in the source-only repository.

Generated inputs are in `data/base/`, `data/corrections/`, and `data/expected.json`. Generated data and `artifacts/` are ignored by Git and absent from a fresh clone; recreate them using the commands below.

From the project directory with Python 3.11+:

```bash
python scripts/generate_data.py --output data --seed 42
python scripts/validate_local.py --data data --output artifacts/run-2
python -m unittest discover -s tests -v
```

Use a new output directory for each validation run: the runner refuses to overwrite an existing `local.sqlite`, preserving previous evidence. The normal CLI writes reconciliation JSON/Markdown and the database. The checked-in evidence snapshot additionally includes regression-test and reproducibility outcomes captured during verification.

Environment caveat: the desktop execution wrapper reported `Access is denied`/`EPERM` after Python emitted a completed `OK` test run and wrote the evidence. The generated evidence files were independently read back and confirmed all tests/checks passed. This is not evidence of a clean host-wrapper exit status.

## Pending cloud checks

No Snowflake account was supplied, so setup, COPY, MERGE compilation/execution, actual role isolation, Query Profile, and credit-usage checks have not run. No Snowflake performance, cost, or production-readiness claim is made. See [the cloud evidence checklist](snowflake-evidence.md) and [the ordered SQL runbook](../sql/snowflake/README.md).

Full cloud integration and mutation testing have not been executed. Applicable pre-push verification gates remain separate from the local evidence above. No repository push was performed.
