USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- Deploy this view once as the object owner. Routine loader checks use 09, not DDL.
-- No business exception (e.g. deliberately invalid PO reference or overpayment)
-- is itself a pipeline failure: incorrect modelling/flags/reconciliation is.
CREATE OR REPLACE VIEW STAGING.MART_QUALITY_FAILURES AS
WITH expected_dates AS (
    SELECT DATEADD('day', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
                   '2025-01-01'::DATE)::DATE AS calendar_date
    FROM TABLE(GENERATOR(ROWCOUNT => 365))
), fact_suppliers AS (
    SELECT 'FACT_PURCHASING' AS fact_name, po_line_id AS record_key, supplier_id,
           supplier_key, order_date AS business_date FROM MART.FACT_PURCHASING
    UNION ALL
    SELECT 'FACT_INVOICE', invoice_line_id, supplier_id, supplier_key, invoice_date FROM MART.FACT_INVOICE
    UNION ALL
    SELECT 'FACT_PAYMENT', payment_id, supplier_id, supplier_key, payment_date FROM MART.FACT_PAYMENT
), fact_dates AS (
    SELECT 'FACT_PURCHASING' AS fact_name, po_line_id AS record_key, 'ORDER' AS date_role,
           order_date AS business_date, order_date_key AS date_key FROM MART.FACT_PURCHASING
    UNION ALL
    SELECT 'FACT_INVOICE', invoice_line_id, 'INVOICE', invoice_date, invoice_date_key FROM MART.FACT_INVOICE
    UNION ALL
    SELECT 'FACT_INVOICE', invoice_line_id, 'DUE', due_date, due_date_key FROM MART.FACT_INVOICE
    UNION ALL
    SELECT 'FACT_PAYMENT', payment_id, 'PAYMENT', payment_date, payment_date_key FROM MART.FACT_PAYMENT
), source_line_totals AS (
    SELECT invoice_id, SUM(quantity * unit_price_cents) AS line_total_cents
    FROM STAGING.STG_INVOICE_LINES GROUP BY invoice_id
), source_paid AS (
    SELECT p.invoice_id, SUM(p.amount_cents) AS paid_cents
    FROM STAGING.STG_PAYMENTS p CROSS JOIN MART.REPORTING_DATE r
    WHERE p.payment_date <= r.reporting_date GROUP BY p.invoice_id
), expected_balances AS (
    SELECT i.invoice_id, i.invoice_date, l.line_total_cents, COALESCE(p.paid_cents, 0) AS paid_cents,
           l.line_total_cents - COALESCE(p.paid_cents, 0) AS balance_cents
    FROM STAGING.STG_INVOICES i JOIN source_line_totals l ON l.invoice_id = i.invoice_id
    CROSS JOIN MART.REPORTING_DATE r LEFT JOIN source_paid p ON p.invoice_id = i.invoice_id
    WHERE i.invoice_date <= r.reporting_date
), source_daily_paid AS (
    SELECT p.invoice_id, p.payment_date, SUM(p.amount_cents) AS cents
    FROM STAGING.STG_PAYMENTS p CROSS JOIN MART.REPORTING_DATE r
    WHERE p.payment_date <= r.reporting_date GROUP BY p.invoice_id, p.payment_date
), source_running_paid AS (
    SELECT invoice_id, payment_date, SUM(cents) OVER (PARTITION BY invoice_id ORDER BY payment_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cents
    FROM source_daily_paid
), expected_full_dates AS (
    SELECT b.invoice_id, IFF(b.line_total_cents = 0, b.invoice_date,
           MIN(IFF(p.cents >= b.line_total_cents, p.payment_date, NULL))) AS paid_in_full_date
    FROM expected_balances b LEFT JOIN source_running_paid p ON p.invoice_id = b.invoice_id
    GROUP BY b.invoice_id, b.line_total_cents, b.invoice_date
)
SELECT 'DATE_DIMENSION_MISSING' AS check_name, TO_CHAR(e.calendar_date, 'YYYY-MM-DD') AS record_key,
       TO_CHAR(e.calendar_date, 'YYYYMMDD') AS expected_value, TO_VARCHAR(d.date_key) AS actual_value
FROM expected_dates e LEFT JOIN MART.DIM_DATE d ON d.calendar_date = e.calendar_date
WHERE d.calendar_date IS NULL OR d.date_key <> TO_NUMBER(TO_CHAR(e.calendar_date, 'YYYYMMDD'))
UNION ALL
SELECT 'DATE_DIMENSION_OUT_OF_RANGE', TO_CHAR(calendar_date, 'YYYY-MM-DD'), '2025 calendar day', TO_VARCHAR(date_key)
FROM MART.DIM_DATE WHERE calendar_date NOT BETWEEN '2025-01-01'::DATE AND '2025-12-31'::DATE
UNION ALL
SELECT 'DIM_DATE_GRAIN', TO_VARCHAR(date_key), '1 nonnull key', TO_VARCHAR(COUNT(*))
FROM MART.DIM_DATE GROUP BY date_key HAVING COUNT(*) <> 1 OR date_key IS NULL
UNION ALL
SELECT 'DIM_SUPPLIER_GRAIN', TO_VARCHAR(supplier_key), '1 nonnull key', TO_VARCHAR(COUNT(*))
FROM MART.DIM_SUPPLIER GROUP BY supplier_key HAVING COUNT(*) <> 1 OR supplier_key IS NULL
UNION ALL
SELECT 'FACT_PURCHASING_GRAIN', TO_VARCHAR(po_line_id), '1 nonnull key', TO_VARCHAR(COUNT(*))
FROM MART.FACT_PURCHASING GROUP BY po_line_id HAVING COUNT(*) <> 1 OR po_line_id IS NULL
UNION ALL
SELECT 'FACT_INVOICE_GRAIN', TO_VARCHAR(invoice_line_id), '1 nonnull key', TO_VARCHAR(COUNT(*))
FROM MART.FACT_INVOICE GROUP BY invoice_line_id HAVING COUNT(*) <> 1 OR invoice_line_id IS NULL
UNION ALL
SELECT 'FACT_PAYMENT_GRAIN', TO_VARCHAR(payment_id), '1 nonnull key', TO_VARCHAR(COUNT(*))
FROM MART.FACT_PAYMENT GROUP BY payment_id HAVING COUNT(*) <> 1 OR payment_id IS NULL
UNION ALL
SELECT 'DATE_CALENDAR_GRAIN', TO_VARCHAR(calendar_date), '1', TO_VARCHAR(COUNT(*))
FROM MART.DIM_DATE GROUP BY calendar_date HAVING COUNT(*) <> 1
UNION ALL
SELECT 'SUPPLIER_VERSION_GRAIN', TO_JSON(ARRAY_CONSTRUCT(supplier_id, valid_from)), '1', TO_VARCHAR(COUNT(*))
FROM MART.DIM_SUPPLIER GROUP BY supplier_id, valid_from HAVING COUNT(*) <> 1
UNION ALL
SELECT 'SUPPLIER_INTERVAL', supplier_key, 'positive adjacent half-open intervals',
       TO_JSON(ARRAY_CONSTRUCT(valid_from, valid_to, previous_valid_to))
FROM (SELECT *, LAG(valid_to) OVER (PARTITION BY supplier_id ORDER BY valid_from) AS previous_valid_to
      FROM MART.DIM_SUPPLIER)
WHERE valid_from >= valid_to OR (previous_valid_to IS NOT NULL AND previous_valid_to <> valid_from)
   OR is_current <> (valid_to = '9999-12-31'::DATE)
UNION ALL
SELECT 'SUPPLIER_CURRENT_COUNT', supplier_id, '1', TO_VARCHAR(SUM(IFF(is_current, 1, 0)))
FROM MART.DIM_SUPPLIER GROUP BY supplier_id HAVING SUM(IFF(is_current, 1, 0)) <> 1
UNION ALL
SELECT 'SUPPLIER_SOURCE_RECONCILIATION', COALESCE(s.supplier_key, t.supplier_key),
       TO_JSON(ARRAY_CONSTRUCT(s.row_hash, s.source_updated_at)),
       TO_JSON(ARRAY_CONSTRUCT(t.row_hash, t.source_updated_at))
FROM STAGING.SRC_DIM_SUPPLIER s FULL OUTER JOIN MART.DIM_SUPPLIER t ON t.supplier_key = s.supplier_key
WHERE s.supplier_key IS NULL OR t.supplier_key IS NULL OR s.row_hash IS DISTINCT FROM t.row_hash
   OR s.source_updated_at IS DISTINCT FROM t.source_updated_at
   OR s.supplier_id IS DISTINCT FROM t.supplier_id OR s.supplier_name IS DISTINCT FROM t.supplier_name
   OR s.category IS DISTINCT FROM t.category OR s.country IS DISTINCT FROM t.country
   OR s.payment_terms_days IS DISTINCT FROM t.payment_terms_days
   OR s.valid_from IS DISTINCT FROM t.valid_from OR s.valid_to IS DISTINCT FROM t.valid_to
   OR s.is_current IS DISTINCT FROM t.is_current
UNION ALL
SELECT 'FACT_PURCHASING_SOURCE_KEY_AMOUNT', COALESCE(s.po_line_id, t.po_line_id),
       TO_VARCHAR(s.quantity * s.unit_price_cents), TO_VARCHAR(t.ordered_amount_cents)
FROM STAGING.STG_PO_LINES s FULL OUTER JOIN MART.FACT_PURCHASING t ON t.po_line_id = s.po_line_id
WHERE s.po_line_id IS NULL OR t.po_line_id IS NULL OR s.quantity * s.unit_price_cents IS DISTINCT FROM t.ordered_amount_cents
UNION ALL
SELECT 'FACT_PURCHASING_FULL_PAYLOAD', COALESCE(s.po_line_id, t.po_line_id),
       TO_JSON(ARRAY_CONSTRUCT(s.row_hash, s.source_updated_at)),
       TO_JSON(ARRAY_CONSTRUCT(t.row_hash, t.source_updated_at))
FROM STAGING.SRC_FACT_PURCHASING s FULL OUTER JOIN MART.FACT_PURCHASING t ON t.po_line_id = s.po_line_id
WHERE s.po_line_id IS NULL OR t.po_line_id IS NULL OR s.row_hash IS DISTINCT FROM t.row_hash
   OR s.source_updated_at IS DISTINCT FROM t.source_updated_at
   OR s.po_id IS DISTINCT FROM t.po_id OR s.line_number IS DISTINCT FROM t.line_number
   OR s.supplier_id IS DISTINCT FROM t.supplier_id OR s.supplier_key IS DISTINCT FROM t.supplier_key
   OR s.order_date IS DISTINCT FROM t.order_date OR s.order_date_key IS DISTINCT FROM t.order_date_key
   OR s.status IS DISTINCT FROM t.status OR s.description IS DISTINCT FROM t.description
   OR s.quantity IS DISTINCT FROM t.quantity OR s.unit_price_cents IS DISTINCT FROM t.unit_price_cents
   OR s.ordered_amount_cents IS DISTINCT FROM t.ordered_amount_cents
   OR s.ordered_amount_usd IS DISTINCT FROM t.ordered_amount_usd
UNION ALL
SELECT 'FACT_PURCHASING_COUNT_SUM', 'FACT_PURCHASING', TO_JSON(ARRAY_CONSTRUCT(s.n, s.cents)),
       TO_JSON(ARRAY_CONSTRUCT(t.n, t.cents))
FROM (SELECT COUNT(*) AS n, COALESCE(SUM(quantity * unit_price_cents), 0) AS cents FROM STAGING.STG_PO_LINES) s
CROSS JOIN (SELECT COUNT(*) AS n, COALESCE(SUM(ordered_amount_cents), 0) AS cents FROM MART.FACT_PURCHASING) t
WHERE s.n <> t.n OR s.cents <> t.cents
UNION ALL
SELECT 'FACT_PURCHASING_USD_CONVERSION', po_line_id, TO_VARCHAR(ordered_amount_cents), TO_VARCHAR(ordered_amount_usd * 100)
FROM MART.FACT_PURCHASING WHERE ordered_amount_cents <> ordered_amount_usd * 100
UNION ALL
SELECT 'FACT_INVOICE_SOURCE_KEY_AMOUNT', COALESCE(s.invoice_line_id, t.invoice_line_id),
       TO_VARCHAR(s.quantity * s.unit_price_cents), TO_VARCHAR(t.invoiced_amount_cents)
FROM STAGING.STG_INVOICE_LINES s FULL OUTER JOIN MART.FACT_INVOICE t ON t.invoice_line_id = s.invoice_line_id
WHERE s.invoice_line_id IS NULL OR t.invoice_line_id IS NULL OR s.quantity * s.unit_price_cents IS DISTINCT FROM t.invoiced_amount_cents
UNION ALL
SELECT 'FACT_INVOICE_FULL_PAYLOAD', COALESCE(s.invoice_line_id, t.invoice_line_id),
       TO_JSON(ARRAY_CONSTRUCT(s.row_hash, s.source_updated_at)),
       TO_JSON(ARRAY_CONSTRUCT(t.row_hash, t.source_updated_at))
FROM STAGING.SRC_FACT_INVOICE s FULL OUTER JOIN MART.FACT_INVOICE t ON t.invoice_line_id = s.invoice_line_id
WHERE s.invoice_line_id IS NULL OR t.invoice_line_id IS NULL OR s.row_hash IS DISTINCT FROM t.row_hash
   OR s.source_updated_at IS DISTINCT FROM t.source_updated_at
   OR s.invoice_id IS DISTINCT FROM t.invoice_id OR s.line_number IS DISTINCT FROM t.line_number
   OR s.supplier_id IS DISTINCT FROM t.supplier_id OR s.supplier_key IS DISTINCT FROM t.supplier_key
   OR s.invoice_date IS DISTINCT FROM t.invoice_date OR s.invoice_date_key IS DISTINCT FROM t.invoice_date_key
   OR s.due_date IS DISTINCT FROM t.due_date OR s.due_date_key IS DISTINCT FROM t.due_date_key
   OR s.invoice_number IS DISTINCT FROM t.invoice_number
   OR s.invoice_number_normalized IS DISTINCT FROM t.invoice_number_normalized
   OR s.invoice_total_cents IS DISTINCT FROM t.invoice_total_cents
   OR s.po_line_id IS DISTINCT FROM t.po_line_id OR s.po_id IS DISTINCT FROM t.po_id
   OR s.description IS DISTINCT FROM t.description OR s.quantity IS DISTINCT FROM t.quantity
   OR s.unit_price_cents IS DISTINCT FROM t.unit_price_cents
   OR s.invoiced_amount_cents IS DISTINCT FROM t.invoiced_amount_cents
   OR s.invoiced_amount_usd IS DISTINCT FROM t.invoiced_amount_usd
   OR s.no_po IS DISTINCT FROM t.no_po OR s.invalid_po_reference IS DISTINCT FROM t.invalid_po_reference
   OR s.supplier_mismatch IS DISTINCT FROM t.supplier_mismatch OR s.price_mismatch IS DISTINCT FROM t.price_mismatch
   OR s.header_total_mismatch IS DISTINCT FROM t.header_total_mismatch
   OR s.duplicate_invoice_number IS DISTINCT FROM t.duplicate_invoice_number
UNION ALL
SELECT 'FACT_INVOICE_COUNT_SUM', 'FACT_INVOICE', TO_JSON(ARRAY_CONSTRUCT(s.n, s.cents)),
       TO_JSON(ARRAY_CONSTRUCT(t.n, t.cents))
FROM (SELECT COUNT(*) AS n, COALESCE(SUM(quantity * unit_price_cents), 0) AS cents FROM STAGING.STG_INVOICE_LINES) s
CROSS JOIN (SELECT COUNT(*) AS n, COALESCE(SUM(invoiced_amount_cents), 0) AS cents FROM MART.FACT_INVOICE) t
WHERE s.n <> t.n OR s.cents <> t.cents
UNION ALL
SELECT 'FACT_INVOICE_USD_CONVERSION', invoice_line_id, TO_VARCHAR(invoiced_amount_cents), TO_VARCHAR(invoiced_amount_usd * 100)
FROM MART.FACT_INVOICE WHERE invoiced_amount_cents <> invoiced_amount_usd * 100
UNION ALL
SELECT 'FACT_PAYMENT_SOURCE_KEY_AMOUNT', COALESCE(s.payment_id, t.payment_id),
       TO_VARCHAR(s.amount_cents), TO_VARCHAR(t.amount_cents)
FROM STAGING.STG_PAYMENTS s FULL OUTER JOIN MART.FACT_PAYMENT t ON t.payment_id = s.payment_id
WHERE s.payment_id IS NULL OR t.payment_id IS NULL OR s.amount_cents IS DISTINCT FROM t.amount_cents
UNION ALL
SELECT 'FACT_PAYMENT_FULL_PAYLOAD', COALESCE(s.payment_id, t.payment_id),
       TO_JSON(ARRAY_CONSTRUCT(s.row_hash, s.source_updated_at)),
       TO_JSON(ARRAY_CONSTRUCT(t.row_hash, t.source_updated_at))
FROM STAGING.SRC_FACT_PAYMENT s FULL OUTER JOIN MART.FACT_PAYMENT t ON t.payment_id = s.payment_id
WHERE s.payment_id IS NULL OR t.payment_id IS NULL OR s.row_hash IS DISTINCT FROM t.row_hash
   OR s.source_updated_at IS DISTINCT FROM t.source_updated_at
   OR s.invoice_id IS DISTINCT FROM t.invoice_id OR s.supplier_id IS DISTINCT FROM t.supplier_id
   OR s.supplier_key IS DISTINCT FROM t.supplier_key OR s.payment_date IS DISTINCT FROM t.payment_date
   OR s.payment_date_key IS DISTINCT FROM t.payment_date_key
   OR s.amount_cents IS DISTINCT FROM t.amount_cents OR s.amount_usd IS DISTINCT FROM t.amount_usd
UNION ALL
SELECT 'FACT_PAYMENT_COUNT_SUM', 'FACT_PAYMENT', TO_JSON(ARRAY_CONSTRUCT(s.n, s.cents)),
       TO_JSON(ARRAY_CONSTRUCT(t.n, t.cents))
FROM (SELECT COUNT(*) AS n, COALESCE(SUM(amount_cents), 0) AS cents FROM STAGING.STG_PAYMENTS) s
CROSS JOIN (SELECT COUNT(*) AS n, COALESCE(SUM(amount_cents), 0) AS cents FROM MART.FACT_PAYMENT) t
WHERE s.n <> t.n OR s.cents <> t.cents
UNION ALL
SELECT 'FACT_PAYMENT_USD_CONVERSION', payment_id, TO_VARCHAR(amount_cents), TO_VARCHAR(amount_usd * 100)
FROM MART.FACT_PAYMENT WHERE amount_cents <> amount_usd * 100
UNION ALL
SELECT 'SUPPLIER_FACT_INTERVAL_FK', f.fact_name || ':' || f.record_key,
       TO_JSON(ARRAY_CONSTRUCT(f.supplier_id, f.business_date)),
       TO_JSON(ARRAY_CONSTRUCT(f.supplier_key, s.supplier_id, s.valid_from, s.valid_to))
FROM fact_suppliers f LEFT JOIN MART.DIM_SUPPLIER s ON s.supplier_key = f.supplier_key
WHERE s.supplier_key IS NULL OR f.supplier_id <> s.supplier_id
   OR f.business_date < s.valid_from OR f.business_date >= s.valid_to
UNION ALL
SELECT 'DATE_FACT_FK', f.fact_name || ':' || f.record_key || ':' || f.date_role,
       TO_VARCHAR(f.business_date), TO_VARCHAR(f.date_key)
FROM fact_dates f LEFT JOIN MART.DIM_DATE d ON d.date_key = f.date_key
WHERE d.date_key IS NULL OR d.calendar_date <> f.business_date
UNION ALL
SELECT 'PAYMENT_INVOICE_FK', p.payment_id, p.invoice_id, NULL::VARCHAR
FROM MART.FACT_PAYMENT p WHERE NOT EXISTS
    (SELECT 1 FROM MART.FACT_INVOICE i WHERE i.invoice_id = p.invoice_id)
UNION ALL
SELECT 'PO_LINE_NUMBER_GRAIN', TO_JSON(ARRAY_CONSTRUCT(po_id, line_number)), '1', TO_VARCHAR(COUNT(*))
FROM MART.FACT_PURCHASING GROUP BY po_id, line_number HAVING COUNT(*) > 1
UNION ALL
SELECT 'INVOICE_LINE_NUMBER_GRAIN', TO_JSON(ARRAY_CONSTRUCT(invoice_id, line_number)), '1', TO_VARCHAR(COUNT(*))
FROM MART.FACT_INVOICE GROUP BY invoice_id, line_number HAVING COUNT(*) > 1
UNION ALL
SELECT 'INVOICE_HEADER_CONSISTENCY', invoice_id, 'one header payload across lines',
       TO_VARCHAR(COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(supplier_id, supplier_key, invoice_date,
           due_date, invoice_number, invoice_total_cents))))
FROM MART.FACT_INVOICE GROUP BY invoice_id
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(supplier_id, supplier_key, invoice_date,
           due_date, invoice_number, invoice_total_cents))) <> 1
UNION ALL
SELECT 'FLAG_NO_PO', f.invoice_line_id, TO_VARCHAR(s.no_po), TO_VARCHAR(f.no_po)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.no_po IS DISTINCT FROM s.no_po
UNION ALL
SELECT 'FLAG_INVALID_PO_REFERENCE', f.invoice_line_id, TO_VARCHAR(s.invalid_po_reference), TO_VARCHAR(f.invalid_po_reference)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.invalid_po_reference IS DISTINCT FROM s.invalid_po_reference
UNION ALL
SELECT 'FLAG_SUPPLIER_MISMATCH', f.invoice_line_id, TO_VARCHAR(s.supplier_mismatch), TO_VARCHAR(f.supplier_mismatch)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.supplier_mismatch IS DISTINCT FROM s.supplier_mismatch
UNION ALL
SELECT 'FLAG_PRICE_MISMATCH', f.invoice_line_id, TO_VARCHAR(s.price_mismatch), TO_VARCHAR(f.price_mismatch)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.price_mismatch IS DISTINCT FROM s.price_mismatch
UNION ALL
SELECT 'FLAG_HEADER_TOTAL_MISMATCH', f.invoice_line_id, TO_VARCHAR(s.header_total_mismatch), TO_VARCHAR(f.header_total_mismatch)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.header_total_mismatch IS DISTINCT FROM s.header_total_mismatch
UNION ALL
SELECT 'FLAG_DUPLICATE_INVOICE_NUMBER', f.invoice_line_id, TO_VARCHAR(s.duplicate_invoice_number), TO_VARCHAR(f.duplicate_invoice_number)
FROM MART.FACT_INVOICE f JOIN STAGING.SRC_FACT_INVOICE s ON s.invoice_line_id = f.invoice_line_id
WHERE f.duplicate_invoice_number IS DISTINCT FROM s.duplicate_invoice_number
UNION ALL
SELECT 'BALANCE_SOURCE_RECONCILIATION', COALESCE(e.invoice_id, b.invoice_id),
       TO_JSON(ARRAY_CONSTRUCT(e.line_total_cents, e.paid_cents, e.balance_cents)),
       TO_JSON(ARRAY_CONSTRUCT(b.line_total_cents, b.paid_to_date_cents, b.balance_cents))
FROM expected_balances e FULL OUTER JOIN MART.INVOICE_BALANCES_AS_OF b ON b.invoice_id = e.invoice_id
WHERE e.invoice_id IS NULL OR b.invoice_id IS NULL OR e.line_total_cents IS DISTINCT FROM b.line_total_cents
   OR e.paid_cents IS DISTINCT FROM b.paid_to_date_cents OR e.balance_cents IS DISTINCT FROM b.balance_cents
UNION ALL
SELECT 'BALANCE_OVERDUE_FLAG', invoice_id,
       TO_VARCHAR(due_date < reporting_date AND balance_cents > 0), TO_VARCHAR(is_overdue)
FROM MART.INVOICE_BALANCES_AS_OF
WHERE is_overdue IS DISTINCT FROM (due_date < reporting_date AND balance_cents > 0)
   OR is_overpaid IS DISTINCT FROM (balance_cents < 0)
UNION ALL
SELECT 'PAYMENT_PERFORMANCE_DATE', p.invoice_id, TO_VARCHAR(e.paid_in_full_date), TO_VARCHAR(p.paid_in_full_date)
FROM expected_full_dates e FULL OUTER JOIN MART.PAYMENT_PERFORMANCE_AS_OF p ON p.invoice_id = e.invoice_id
WHERE e.invoice_id IS NULL OR p.invoice_id IS NULL OR e.paid_in_full_date IS DISTINCT FROM p.paid_in_full_date;
