# Data contract

All data is fictional. Monetary values are integer USD cents in CSV and local SQLite; Snowflake marts additionally expose decimal USD. No tax, FX, credits, reversals, receipts, or bank-file modelling is included. Reporting date: 2025-03-31. UTC timestamps use ISO format without timezone suffix. Base batch: 2025-03-01T00:00:00; correction batch: 2025-03-15T00:00:00. Data covers January–March 2025. Supplier history starts 2025-01-01.

## Files and columns

CSV headers are required, column order is exact. Empty string represents null. IDs are strings. Date strings are YYYY-MM-DD. All records include source_updated_at and batch_id as their final two columns. Batch ID is BASE or CORRECTION. Correction files are partial upserts, not full snapshots. Source timestamps must increase for corrections; equal timestamps with different payloads are rejected. Natural-key deletes are out of scope.

| CSV | Columns before source_updated_at,batch_id | Natural key / grain |
| --- | --- | --- |
| suppliers.csv | supplier_id,supplier_name,category,country,payment_terms_days,effective_from | supplier_id,effective_from / one effective-dated supplier version |
| purchase_orders.csv | po_id,supplier_id,order_date,status | po_id / one PO header |
| po_lines.csv | po_line_id,po_id,line_number,description,quantity,unit_price_cents | po_line_id / one PO line |
| invoices.csv | invoice_id,supplier_id,invoice_date,due_date,invoice_number,invoice_total_cents | invoice_id / one invoice header |
| invoice_lines.csv | invoice_line_id,invoice_id,line_number,po_line_id,description,quantity,unit_price_cents | invoice_line_id / one invoice line |
| payments.csv | payment_id,invoice_id,payment_date,amount_cents | payment_id / one payment allocation to one invoice |

Quantity and prices are nonnegative integers; amount_cents and invoice_total_cents are nonnegative integers. Each PO/invoice contains at least one line. Duplicate line_number within a document is invalid. po_line_id on invoice_lines is optional; populated but absent references are classified INVALID_PO_REFERENCE, not silently removed. Suppliers and document parents must exist. Invoice lines may refer to a PO from another supplier to demonstrate SUPPLIER_MISMATCH. Cancelled POs are not generated. Multiple invoice lines may reference one PO line; PO quantities are not necessarily wholly billed. Payments can be partial, multiple, or later than the reporting date. Payment amounts remain at allocation grain: no claim of modelling a cash disbursement spanning multiple invoices.

## Warehouse names and grains

- RAW: append-only landing tables named SUPPLIERS, PURCHASE_ORDERS, PO_LINES, INVOICES, INVOICE_LINES, PAYMENTS. Add file metadata when loading.
- STAGING: STG_ prefixed typed, deduplicated versions of each source. Latest source_updated_at by natural key wins. Supplier natural key includes effective_from.
- MART.DIM_SUPPLIER: SCD2 versions by supplier_id/effective_from; deterministic key supplier_id || '|' || effective_from; half-open validity [valid_from,valid_to); final valid_to 9999-12-31. Effective dates, not ingestion timestamps, drive history. Corrections to a version restate that interval. Facts use the version effective on their own document/payment date.
- MART.DIM_DATE: one date for every day of 2025; date_key YYYYMMDD integer.
- MART.FACT_PURCHASING: one po_line_id; ordered_amount_cents = quantity * unit_price_cents.
- MART.FACT_INVOICE: one invoice_line_id; invoiced_amount_cents = quantity * unit_price_cents. Include supplier key, header fields, PO reference, and independent boolean flags.
- MART.FACT_PAYMENT: one payment_id; retain invoice_id and supplier key. Do not attach payments to invoice-line rows.

## Analytical semantics

Spend means invoiced line amount, not PO commitments plus invoices plus payments. Supplier concentration includes invoices dated on/before the reporting date; top five share and HHI use the full spend denominator. Exception flags: NO_PO (blank reference), INVALID_PO_REFERENCE (nonblank absent reference), SUPPLIER_MISMATCH, PRICE_MISMATCH (invoice and referenced PO unit prices differ), HEADER_TOTAL_MISMATCH (header total differs from sum of all invoice lines), DUPLICATE_INVOICE_NUMBER (same supplier and normalized invoice number on different invoice IDs). Flags overlap. A header mismatch or duplicate-number flag applies to every line of the invoice. Supplier exception rate counts distinct exception invoices / distinct invoices, never lines.

Unmatched spend is NO_PO or INVALID_PO_REFERENCE, reported separately and together. Supplier mismatch is an exception but is not included in unmatched-reference spend. Price mismatch is exact integer-cents comparison; no tolerance. Overdue means invoice due_date < reporting date, invoice_date <= reporting date, and line-derived balance > 0. Paid-to-date includes allocations payment_date <= reporting date; future allocations do not reduce historical balances. Negative balance is overpayment and must remain visible, never clamped in the underlying balance view. Open balance is line sum less payments, with header discrepancies exposed separately. Payment performance includes paid-in-full date (first cumulative payment date reaching invoice line amount) and signed days late (negative means early); future payments are excluded from as-of analysis. A zero-total invoice is treated as settled on its invoice date without requiring a payment. Invoice balance and payment-performance views aggregate lines and payments independently to invoice grain before joining.

## Deterministic scenarios

Generator CLI: python scripts/generate_data.py --output data --seed 42. Write data/base/<six files>, data/corrections/<six files>, data/expected.json. At least 20 suppliers and 100 invoices; include multiple lines and multiple payment allocations. Include explicit stable fixture IDs for each exception and an unpaid overdue invoice, partial payment, future payment, overpayment, and clean paid-on-time invoice. Corrections must update an existing payment amount, one invoice-line amount (and its header total), and restate an existing effective-dated supplier category version. Base data includes multiple effective dates for one supplier; local behavior checks also exercise insertion of a late-arriving effective-date interval. data/expected.json documents stable fixture IDs and expected correction changes, and records per-file counts and monetary sums generated from the actual rows. Same seed must produce byte-identical output.

Local CLI target: python scripts/validate_local.py --data data --output artifacts. Local SQLite database and report JSON/Markdown are generated artifacts; never label local evidence as Snowflake execution. Base load, identical replay, correction load, and correction replay must be demonstrated. Snowflake deployment remains manual without an account; no fabricated Query Profile or warehouse credits.
