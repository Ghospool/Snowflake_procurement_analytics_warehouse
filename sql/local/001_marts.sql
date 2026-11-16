-- Local SQLite evidence only. Reporting date is fixed by the source contract.
CREATE VIEW IF NOT EXISTS stg_suppliers AS SELECT * FROM suppliers;
CREATE VIEW IF NOT EXISTS stg_purchase_orders AS SELECT * FROM purchase_orders;
CREATE VIEW IF NOT EXISTS stg_po_lines AS SELECT * FROM po_lines;
CREATE VIEW IF NOT EXISTS stg_invoices AS SELECT * FROM invoices;
CREATE VIEW IF NOT EXISTS stg_invoice_lines AS SELECT * FROM invoice_lines;
CREATE VIEW IF NOT EXISTS stg_payments AS SELECT * FROM payments;
DROP VIEW IF EXISTS v_overdue_aging;
DROP VIEW IF EXISTS v_unmatched_spend;
DROP VIEW IF EXISTS v_supplier_concentration;
DROP VIEW IF EXISTS v_supplier_spend;
DROP VIEW IF EXISTS v_payment_performance;
DROP VIEW IF EXISTS v_invoice_balance;
DROP VIEW IF EXISTS fact_payment;
DROP VIEW IF EXISTS fact_invoice;
DROP VIEW IF EXISTS fact_purchasing;
DROP VIEW IF EXISTS dim_supplier;
DROP VIEW IF EXISTS dim_date;

CREATE VIEW dim_supplier AS
SELECT supplier_id || '|' || effective_from AS supplier_key,
       supplier_id, supplier_name, category, country, payment_terms_days,
       effective_from AS valid_from,
       LEAD(effective_from, 1, '9999-12-31') OVER
           (PARTITION BY supplier_id ORDER BY effective_from) AS valid_to
FROM suppliers;

CREATE VIEW dim_date AS
WITH RECURSIVE days(calendar_date) AS (
    SELECT '2025-01-01'
    UNION ALL SELECT date(calendar_date, '+1 day') FROM days WHERE calendar_date < '2025-12-31'
)
SELECT CAST(replace(calendar_date, '-', '') AS INTEGER) AS date_key,
       calendar_date, CAST(strftime('%Y', calendar_date) AS INTEGER) AS year,
       CAST(strftime('%m', calendar_date) AS INTEGER) AS month,
       CAST(strftime('%d', calendar_date) AS INTEGER) AS day FROM days;

CREATE VIEW fact_purchasing AS
SELECT l.po_line_id, h.po_id, h.supplier_id, d.supplier_key, h.order_date,
       h.status, l.line_number, l.description, l.quantity, l.unit_price_cents,
       l.quantity * l.unit_price_cents AS ordered_amount_cents
FROM po_lines l JOIN purchase_orders h ON h.po_id = l.po_id
LEFT JOIN dim_supplier d ON d.supplier_id = h.supplier_id
 AND h.order_date >= d.valid_from AND h.order_date < d.valid_to;

CREATE VIEW fact_invoice AS
WITH line_totals AS (
 SELECT invoice_id, SUM(quantity * unit_price_cents) AS line_total_cents
 FROM invoice_lines GROUP BY invoice_id
), duplicates AS (
 SELECT supplier_id, upper(trim(invoice_number)) AS normalized_invoice_number
 FROM invoices GROUP BY supplier_id, upper(trim(invoice_number)) HAVING COUNT(*) > 1
)
SELECT l.invoice_line_id, h.invoice_id, h.supplier_id, d.supplier_key,
       h.invoice_date, h.due_date, h.invoice_number,
       upper(trim(h.invoice_number)) AS normalized_invoice_number,
       h.invoice_total_cents, t.line_total_cents, l.line_number, l.po_line_id,
       p.po_id, ph.supplier_id AS po_supplier_id, l.description,
       l.quantity, l.unit_price_cents, l.quantity * l.unit_price_cents AS invoiced_amount_cents,
       CASE WHEN l.po_line_id IS NULL THEN 1 ELSE 0 END AS no_po,
       CASE WHEN l.po_line_id IS NOT NULL AND p.po_line_id IS NULL THEN 1 ELSE 0 END AS invalid_po_reference,
       CASE WHEN p.po_line_id IS NOT NULL AND ph.supplier_id <> h.supplier_id THEN 1 ELSE 0 END AS supplier_mismatch,
       CASE WHEN p.po_line_id IS NOT NULL AND p.unit_price_cents <> l.unit_price_cents THEN 1 ELSE 0 END AS price_mismatch,
       CASE WHEN h.invoice_total_cents <> t.line_total_cents THEN 1 ELSE 0 END AS header_total_mismatch,
       CASE WHEN du.supplier_id IS NOT NULL THEN 1 ELSE 0 END AS duplicate_invoice_number
FROM invoice_lines l JOIN invoices h ON h.invoice_id = l.invoice_id
JOIN line_totals t ON t.invoice_id = h.invoice_id
LEFT JOIN po_lines p ON p.po_line_id = l.po_line_id
LEFT JOIN purchase_orders ph ON ph.po_id = p.po_id
LEFT JOIN duplicates du ON du.supplier_id = h.supplier_id
 AND du.normalized_invoice_number = upper(trim(h.invoice_number))
LEFT JOIN dim_supplier d ON d.supplier_id = h.supplier_id
 AND h.invoice_date >= d.valid_from AND h.invoice_date < d.valid_to;

CREATE VIEW fact_payment AS
SELECT p.payment_id, p.invoice_id, h.supplier_id, d.supplier_key,
       p.payment_date, p.amount_cents
FROM payments p JOIN invoices h ON h.invoice_id = p.invoice_id
LEFT JOIN dim_supplier d ON d.supplier_id = h.supplier_id
 AND p.payment_date >= d.valid_from AND p.payment_date < d.valid_to;

CREATE VIEW v_invoice_balance AS
WITH lines AS (
 SELECT invoice_id, SUM(invoiced_amount_cents) AS line_total_cents
 FROM fact_invoice GROUP BY invoice_id
), paid AS (
 SELECT invoice_id, SUM(amount_cents) AS paid_to_date_cents
 FROM payments WHERE payment_date <= '2025-03-31' GROUP BY invoice_id
)
SELECT h.invoice_id, h.supplier_id, h.invoice_date, h.due_date,
       h.invoice_total_cents, l.line_total_cents,
       h.invoice_total_cents - l.line_total_cents AS header_difference_cents,
       COALESCE(p.paid_to_date_cents, 0) AS paid_to_date_cents,
       l.line_total_cents - COALESCE(p.paid_to_date_cents, 0) AS balance_cents,
       CASE WHEN h.due_date < '2025-03-31' AND l.line_total_cents - COALESCE(p.paid_to_date_cents, 0) > 0
            THEN 1 ELSE 0 END AS is_overdue
FROM invoices h JOIN lines l ON l.invoice_id = h.invoice_id
LEFT JOIN paid p ON p.invoice_id = h.invoice_id
WHERE h.invoice_date <= '2025-03-31';

CREATE VIEW v_payment_performance AS
WITH daily AS (
 SELECT invoice_id, payment_date, SUM(amount_cents) AS amount_cents
 FROM payments WHERE payment_date <= '2025-03-31' GROUP BY invoice_id, payment_date
), cumulative AS (
 SELECT invoice_id, payment_date, SUM(amount_cents) OVER
 (PARTITION BY invoice_id ORDER BY payment_date ROWS UNBOUNDED PRECEDING) AS cumulative_cents FROM daily
), full_dates AS (
 SELECT b.invoice_id, MIN(c.payment_date) AS paid_in_full_date
 FROM v_invoice_balance b JOIN cumulative c ON c.invoice_id = b.invoice_id
 WHERE c.cumulative_cents >= b.line_total_cents GROUP BY b.invoice_id
)
SELECT b.*, CASE WHEN b.line_total_cents = 0 THEN b.invoice_date ELSE f.paid_in_full_date END AS paid_in_full_date,
       CASE WHEN b.line_total_cents = 0 THEN CAST(julianday(b.invoice_date) - julianday(b.due_date) AS INTEGER)
            WHEN f.paid_in_full_date IS NOT NULL THEN CAST(julianday(f.paid_in_full_date) - julianday(b.due_date) AS INTEGER)
            ELSE NULL END AS days_late
FROM v_invoice_balance b LEFT JOIN full_dates f ON f.invoice_id = b.invoice_id;

CREATE VIEW v_supplier_spend AS
SELECT supplier_id, SUM(invoiced_amount_cents) AS spend_cents,
       COUNT(DISTINCT invoice_id) AS invoice_count,
       COUNT(DISTINCT CASE WHEN no_po + invalid_po_reference + supplier_mismatch + price_mismatch
         + header_total_mismatch + duplicate_invoice_number > 0 THEN invoice_id END) AS exception_invoice_count,
       1.0 * COUNT(DISTINCT CASE WHEN no_po + invalid_po_reference + supplier_mismatch + price_mismatch
         + header_total_mismatch + duplicate_invoice_number > 0 THEN invoice_id END)
         / COUNT(DISTINCT invoice_id) AS exception_rate
FROM fact_invoice WHERE invoice_date <= '2025-03-31' GROUP BY supplier_id;

CREATE VIEW v_supplier_concentration AS
WITH ranked AS (
 SELECT *, ROW_NUMBER() OVER (ORDER BY spend_cents DESC, supplier_id) AS spend_rank,
 SUM(spend_cents) OVER () AS total_spend_cents FROM v_supplier_spend
)
SELECT MAX(total_spend_cents) AS total_spend_cents,
       1.0 * SUM(CASE WHEN spend_rank <= 5 THEN spend_cents ELSE 0 END) / NULLIF(MAX(total_spend_cents), 0) AS top_five_share,
       SUM((1.0 * spend_cents / NULLIF(total_spend_cents, 0)) * (1.0 * spend_cents / NULLIF(total_spend_cents, 0))) AS hhi
FROM ranked;

CREATE VIEW v_unmatched_spend AS
SELECT COALESCE(SUM(CASE WHEN no_po = 1 THEN invoiced_amount_cents ELSE 0 END), 0) AS no_po_spend_cents,
       COALESCE(SUM(CASE WHEN invalid_po_reference = 1 THEN invoiced_amount_cents ELSE 0 END), 0) AS invalid_po_spend_cents,
       COALESCE(SUM(CASE WHEN no_po = 1 OR invalid_po_reference = 1 THEN invoiced_amount_cents ELSE 0 END), 0) AS unmatched_spend_cents
FROM fact_invoice WHERE invoice_date <= '2025-03-31';

CREATE VIEW v_overdue_aging AS
SELECT *, CAST(julianday('2025-03-31') - julianday(due_date) AS INTEGER) AS days_overdue,
 CASE WHEN julianday('2025-03-31') - julianday(due_date) <= 30 THEN '1-30'
      WHEN julianday('2025-03-31') - julianday(due_date) <= 60 THEN '31-60'
      WHEN julianday('2025-03-31') - julianday(due_date) <= 90 THEN '61-90'
      ELSE '90+' END AS aging_bucket
FROM v_invoice_balance WHERE is_overdue = 1;
