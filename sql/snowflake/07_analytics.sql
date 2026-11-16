USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- This is a fixed-date synthetic report, not a CURRENT_DATE dashboard.
CREATE OR REPLACE VIEW MART.REPORTING_DATE AS
SELECT '2025-03-31'::DATE AS reporting_date;

CREATE OR REPLACE VIEW MART.SPEND_BY_SUPPLIER AS
SELECT f.supplier_id, SUM(f.invoiced_amount_cents) AS spend_cents,
       (SUM(f.invoiced_amount_cents) / 100)::NUMBER(38,2) AS spend_usd,
       COUNT(DISTINCT f.invoice_id) AS invoice_count
FROM MART.FACT_INVOICE f CROSS JOIN MART.REPORTING_DATE r
WHERE f.invoice_date <= r.reporting_date GROUP BY f.supplier_id;

-- Category uses the supplier version effective on invoice date, not today's category.
CREATE OR REPLACE VIEW MART.SPEND_BY_CATEGORY_MONTH AS
SELECT DATE_TRUNC('month', f.invoice_date)::DATE AS invoice_month, s.category,
       SUM(f.invoiced_amount_cents) AS spend_cents,
       (SUM(f.invoiced_amount_cents) / 100)::NUMBER(38,2) AS spend_usd
FROM MART.FACT_INVOICE f
JOIN MART.DIM_SUPPLIER s ON s.supplier_key = f.supplier_key
CROSS JOIN MART.REPORTING_DATE r
WHERE f.invoice_date <= r.reporting_date
GROUP BY DATE_TRUNC('month', f.invoice_date)::DATE, s.category;

CREATE OR REPLACE VIEW MART.SUPPLIER_CONCENTRATION AS
SELECT supplier_id, spend_cents, spend_usd,
       ROW_NUMBER() OVER (ORDER BY spend_cents DESC, supplier_id) AS spend_rank,
       spend_cents / NULLIF(SUM(spend_cents) OVER (), 0) AS spend_share
FROM MART.SPEND_BY_SUPPLIER;

CREATE OR REPLACE VIEW MART.CONCENTRATION_SUMMARY AS
SELECT SUM(spend_cents) AS total_spend_cents,
       SUM(IFF(spend_rank <= 5, spend_share, 0)) AS top_five_spend_share,
       SUM(POWER(spend_share, 2)) AS hhi_fraction,
       10000 * SUM(POWER(spend_share, 2)) AS hhi_points
FROM MART.SUPPLIER_CONCENTRATION;

CREATE OR REPLACE VIEW MART.INVOICE_EXCEPTION_RATE AS
SELECT f.supplier_id, COUNT(DISTINCT f.invoice_id) AS invoice_count,
       COUNT(DISTINCT IFF(no_po OR invalid_po_reference OR supplier_mismatch OR price_mismatch
                            OR header_total_mismatch OR duplicate_invoice_number,
                          f.invoice_id, NULL)) AS exception_invoice_count,
       COUNT(DISTINCT IFF(no_po OR invalid_po_reference OR supplier_mismatch OR price_mismatch
                            OR header_total_mismatch OR duplicate_invoice_number,
                          f.invoice_id, NULL)) / NULLIF(COUNT(DISTINCT f.invoice_id), 0) AS exception_rate,
       COUNT(DISTINCT IFF(no_po, f.invoice_id, NULL)) AS no_po_invoice_count,
       COUNT(DISTINCT IFF(invalid_po_reference, f.invoice_id, NULL)) AS invalid_reference_invoice_count,
       COUNT(DISTINCT IFF(supplier_mismatch, f.invoice_id, NULL)) AS supplier_mismatch_invoice_count,
       COUNT(DISTINCT IFF(price_mismatch, f.invoice_id, NULL)) AS price_mismatch_invoice_count,
       COUNT(DISTINCT IFF(header_total_mismatch, f.invoice_id, NULL)) AS header_mismatch_invoice_count,
       COUNT(DISTINCT IFF(duplicate_invoice_number, f.invoice_id, NULL)) AS duplicate_number_invoice_count
FROM MART.FACT_INVOICE f CROSS JOIN MART.REPORTING_DATE r
WHERE f.invoice_date <= r.reporting_date GROUP BY f.supplier_id;

CREATE OR REPLACE VIEW MART.UNMATCHED_SPEND AS
SELECT f.supplier_id, SUM(f.invoiced_amount_cents) AS total_spend_cents,
       SUM(IFF(f.no_po, f.invoiced_amount_cents, 0)) AS no_po_spend_cents,
       SUM(IFF(f.invalid_po_reference, f.invoiced_amount_cents, 0)) AS invalid_reference_spend_cents,
       SUM(IFF(f.no_po OR f.invalid_po_reference, f.invoiced_amount_cents, 0)) AS unmatched_spend_cents,
       SUM(IFF(f.no_po OR f.invalid_po_reference, f.invoiced_amount_cents, 0))
           / NULLIF(SUM(f.invoiced_amount_cents), 0) AS unmatched_spend_share
FROM MART.FACT_INVOICE f CROSS JOIN MART.REPORTING_DATE r
WHERE f.invoice_date <= r.reporting_date GROUP BY f.supplier_id;

-- One row per invoice BEFORE joining any payment data. Header total is repeated
-- on fact lines, so MAX is correct and SUM(invoice_total_cents) would be wrong.
CREATE OR REPLACE VIEW MART.INVOICE_TOTALS AS
SELECT invoice_id, supplier_id, supplier_key, invoice_date, due_date, invoice_number,
       MAX(invoice_total_cents) AS header_total_cents,
       SUM(invoiced_amount_cents) AS line_total_cents,
       MAX(invoice_total_cents) - SUM(invoiced_amount_cents) AS header_difference_cents
FROM MART.FACT_INVOICE
GROUP BY invoice_id, supplier_id, supplier_key, invoice_date, due_date, invoice_number;

CREATE OR REPLACE VIEW MART.INVOICE_BALANCES_AS_OF AS
WITH payments_by_invoice AS (
    SELECT p.invoice_id,
           SUM(IFF(p.payment_date <= r.reporting_date, p.amount_cents, 0)) AS paid_to_date_cents,
           SUM(IFF(p.payment_date > r.reporting_date, p.amount_cents, 0)) AS future_payment_cents
    FROM MART.FACT_PAYMENT p CROSS JOIN MART.REPORTING_DATE r
    GROUP BY p.invoice_id
), balances AS (
    SELECT i.*, r.reporting_date,
           COALESCE(p.paid_to_date_cents, 0) AS paid_to_date_cents,
           COALESCE(p.future_payment_cents, 0) AS future_payment_cents,
           i.line_total_cents - COALESCE(p.paid_to_date_cents, 0) AS balance_cents
    FROM MART.INVOICE_TOTALS i CROSS JOIN MART.REPORTING_DATE r
    LEFT JOIN payments_by_invoice p ON p.invoice_id = i.invoice_id
    WHERE i.invoice_date <= r.reporting_date
)
SELECT balances.*, (balance_cents / 100)::NUMBER(38,2) AS balance_usd,
       due_date < reporting_date AND balance_cents > 0 AS is_overdue,
       balance_cents < 0 AS is_overpaid,
       IFF(due_date < reporting_date AND balance_cents > 0,
           DATEDIFF('day', due_date, reporting_date), 0) AS overdue_days
FROM balances;

-- Aggregate allocations by invoice/day before the running window: allocations
-- on the same date have no arbitrary within-day ordering.
CREATE OR REPLACE VIEW MART.PAYMENT_PERFORMANCE_AS_OF AS
WITH daily_payments AS (
    SELECT p.invoice_id, p.payment_date, SUM(p.amount_cents) AS daily_amount_cents
    FROM MART.FACT_PAYMENT p CROSS JOIN MART.REPORTING_DATE r
    WHERE p.payment_date <= r.reporting_date GROUP BY p.invoice_id, p.payment_date
), running_payments AS (
    SELECT invoice_id, payment_date,
           SUM(daily_amount_cents) OVER (PARTITION BY invoice_id ORDER BY payment_date
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_paid_cents
    FROM daily_payments
), first_full_payment AS (
    SELECT p.invoice_id, MIN(p.payment_date) AS paid_in_full_date
    FROM running_payments p JOIN MART.INVOICE_TOTALS i ON i.invoice_id = p.invoice_id
    WHERE p.cumulative_paid_cents >= i.line_total_cents GROUP BY p.invoice_id
), performance AS (
    SELECT b.*,
           -- Zero-dollar invoices require no cash: settled on their invoice date.
           IFF(b.line_total_cents = 0, b.invoice_date, p.paid_in_full_date) AS paid_in_full_date
    FROM MART.INVOICE_BALANCES_AS_OF b
    LEFT JOIN first_full_payment p ON p.invoice_id = b.invoice_id
)
SELECT performance.*,
       DATEDIFF('day', due_date, paid_in_full_date) AS signed_days_from_due,
       DATEDIFF('day', due_date, paid_in_full_date) AS days_late,
       IFF(paid_in_full_date IS NOT NULL, paid_in_full_date <= due_date, NULL) AS paid_on_time
FROM performance;

-- Example outputs; do not sum counts across overlapping flag columns.
SELECT * FROM MART.CONCENTRATION_SUMMARY;
SELECT * FROM MART.INVOICE_EXCEPTION_RATE ORDER BY exception_rate DESC, supplier_id;
SELECT * FROM MART.UNMATCHED_SPEND ORDER BY unmatched_spend_cents DESC, supplier_id;
SELECT * FROM MART.INVOICE_BALANCES_AS_OF WHERE is_overdue OR is_overpaid ORDER BY invoice_id;
SELECT * FROM MART.PAYMENT_PERFORMANCE_AS_OF ORDER BY invoice_id;
