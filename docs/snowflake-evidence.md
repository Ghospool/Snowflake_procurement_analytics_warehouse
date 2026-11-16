# Snowflake execution and evidence checklist

Status: NOT EXECUTED. No Snowflake account was available during the initial build. This file is a collection plan, not a benchmark report. Local SQLite results do not prove Snowflake compilation, permissions, COPY behavior, warehouse billing, or Query Profile performance.

## Account and safe setup

1. Obtain a Snowflake account (a trial is sufficient while credits remain) and permission to create the project's database, warehouse, and custom roles. A Python installation alone cannot run Snowflake SQL locally.
2. Review the ordered SQL and its object names before running it. Use a dedicated sandbox, not a production database. Setup allocates billable resources.
3. Authenticate with your Snowflake client's supported browser/SSO or key-pair flow. Never commit passwords, private keys, tokens, or local connection files.
4. Follow the exact order in [the SQL runbook](../sql/snowflake/README.md). Run local-file PUT commands in a compatible client such as SnowSQL; Snowsight SQL worksheets cannot read your laptop's files.
5. Save COPY results and source-to-target reconciliation result sets for both base and correction loads. Validate all six source files; don't accept a partial successful run.

## Reconciliation evidence

Record base and corrected counts, ordered cents, invoiced cents, and paid cents. Every source-to-fact count and amount delta should be zero. Header-versus-line exceptions are intentional business anomalies: show their amounts and classification rather than silently changing line totals to force headers to agree.

Capture an unchanged replay, an updated existing payment, an updated invoice line and header, and a restated effective-dated supplier category. Show that replay does not add facts and that supplier history changes temporal attribution without changing total money.

## Investigated query

Use the investigation query in the numbered performance SQL. The model documentation also gives an unsafe line-to-payment join example as a failure demonstration, not an alternative business result. First prove correct amounts by independently aggregating each side to invoice grain. Inspect query operators and resource use; if testing a rewrite, compare only semantically equivalent variants. Faster wrong results are not an optimization.

For each trial, record the following from Query History and Query Profile:

| Evidence field | Value to record after a real run |
| --- | --- |
| Execution timestamp and query ID | Pending |
| Dataset seed and row counts | Pending |
| SQL variant and Git revision (if available) | Pending |
| Warehouse size and state | Pending |
| Result-cache setting and warm/cold context | Pending |
| Total elapsed / execution / compilation milliseconds | Pending |
| Bytes and partitions scanned | Pending |
| Join input and output row counts | Pending |
| Local/remote spill bytes | Pending |
| Correct invoice and payment totals | Pending |
| Query Profile screenshot path | Pending |

Run repeated trials with the same warehouse and data. Disabling persisted result reuse does not make warehouse-local data caches cold. Report measured variation; a tiny synthetic dataset may be dominated by compilation and startup, and may not justify any performance claim. Do not extrapolate this sample to production-scale workloads.

## Warehouse usage and cost decisions

The baseline uses an X-Small warehouse, auto-resume, and short idle auto-suspend. Batch setup and loads together to avoid unnecessary resume cycles. Keep statement timeouts finite. Do not add clustering, search optimization, materialized views, or scheduled Tasks without evidence that the workload needs them.

Capture actual warehouse credit usage over a bounded test window; distinguish warehouse compute, cloud services, and storage. Account-usage views can lag and may require additional monitoring privileges. Do not interpret an empty usage result as free execution. Dollar costs depend on your contract and region; do not multiply by an invented unit price. A resource monitor can provide an additional guardrail when configured by an authorized administrator, but is not a universal hard cap on all Snowflake costs.

Suspend the dedicated warehouse when finished using an authorized role. Dropping project objects is destructive and deliberately not automated here.

## Publication gate

Before describing this as a completed cloud deployment on GitHub, attach actual reconciliation exports, role-access test results, and at least one Query Profile investigation. Until then use: 'Snowflake-ready implementation with local validation; cloud deployment and performance evidence pending.'

## Sources

- [COPY INTO table](https://docs.snowflake.com/en/sql-reference/sql/copy-into-table)
- [MERGE and duplicate-source behavior](https://docs.snowflake.com/en/sql-reference/sql/merge)
- [Query History and Query Profile](https://docs.snowflake.com/en/user-guide/ui-snowsight-activity)
