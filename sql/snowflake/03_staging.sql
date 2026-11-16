USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- Typed views preserve source metadata. Business payload excludes batch/file metadata.

CREATE OR REPLACE VIEW STAGING.STG_SUPPLIERS AS
WITH typed AS (
    SELECT supplier_id,
           TRIM(supplier_name) AS supplier_name,
           UPPER(TRIM(category)) AS category,
           UPPER(TRIM(country)) AS country,
           TRY_TO_DECIMAL(payment_terms_days, 38, 0) AS payment_terms_days,
           TRY_TO_DATE(effective_from, 'YYYY-MM-DD') AS effective_from,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.SUPPLIERS
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY supplier_id, effective_from
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_PURCHASE_ORDERS AS
WITH typed AS (
    SELECT po_id,
           supplier_id,
           TRY_TO_DATE(order_date, 'YYYY-MM-DD') AS order_date,
           status,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.PURCHASE_ORDERS
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY po_id
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_PO_LINES AS
WITH typed AS (
    SELECT po_line_id,
           po_id,
           TRY_TO_DECIMAL(line_number, 38, 0) AS line_number,
           description,
           TRY_TO_DECIMAL(quantity, 38, 0) AS quantity,
           TRY_TO_DECIMAL(unit_price_cents, 38, 0) AS unit_price_cents,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.PO_LINES
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY po_line_id
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_INVOICES AS
WITH typed AS (
    SELECT invoice_id,
           supplier_id,
           TRY_TO_DATE(invoice_date, 'YYYY-MM-DD') AS invoice_date,
           TRY_TO_DATE(due_date, 'YYYY-MM-DD') AS due_date,
           invoice_number,
           TRY_TO_DECIMAL(invoice_total_cents, 38, 0) AS invoice_total_cents,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.INVOICES
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY invoice_id
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_INVOICE_LINES AS
WITH typed AS (
    SELECT invoice_line_id,
           invoice_id,
           TRY_TO_DECIMAL(line_number, 38, 0) AS line_number,
           po_line_id,
           description,
           TRY_TO_DECIMAL(quantity, 38, 0) AS quantity,
           TRY_TO_DECIMAL(unit_price_cents, 38, 0) AS unit_price_cents,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.INVOICE_LINES
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY invoice_line_id
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

CREATE OR REPLACE VIEW STAGING.STG_PAYMENTS AS
WITH typed AS (
    SELECT payment_id,
           invoice_id,
           TRY_TO_DATE(payment_date, 'YYYY-MM-DD') AS payment_date,
           TRY_TO_DECIMAL(amount_cents, 38, 0) AS amount_cents,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           batch_id, source_filename, source_file_row_number, source_file_content_key, ingested_at
    FROM RAW.PAYMENTS
)
SELECT * FROM typed
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payment_id
    ORDER BY source_updated_at DESC NULLS LAST, ingested_at DESC,
             source_filename DESC, source_file_row_number DESC, batch_id DESC
) = 1;

-- All malformed rows, not just the chosen latest row, fail the load gate.
CREATE OR REPLACE VIEW STAGING.SOURCE_ROW_ERRORS AS
SELECT * FROM (
SELECT 'SUPPLIERS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(supplier_id, effective_from)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(supplier_id), '') IS NULL, 'supplier_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(supplier_name), '') IS NULL, 'supplier_name: required nonblank', NULL),
           IFF(NULLIF(TRIM(category), '') IS NULL, 'category: required nonblank', NULL),
           IFF(NULLIF(TRIM(country), '') IS NULL, 'country: required nonblank', NULL),
           IFF(payment_terms_days IS NULL OR NOT REGEXP_LIKE(payment_terms_days, '[0-9]+') OR TRY_TO_DECIMAL(payment_terms_days, 38, 0) IS NULL, 'payment_terms_days: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(effective_from IS NULL OR NOT REGEXP_LIKE(effective_from, '[0-9]{4}-[0-9]{2}-[0-9]{2}') OR TRY_TO_DATE(effective_from, 'YYYY-MM-DD') IS NULL, 'effective_from: required YYYY-MM-DD', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.SUPPLIERS
UNION ALL
SELECT 'PURCHASE_ORDERS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(po_id)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(po_id), '') IS NULL, 'po_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(supplier_id), '') IS NULL, 'supplier_id: required nonblank', NULL),
           IFF(order_date IS NULL OR NOT REGEXP_LIKE(order_date, '[0-9]{4}-[0-9]{2}-[0-9]{2}') OR TRY_TO_DATE(order_date, 'YYYY-MM-DD') IS NULL, 'order_date: required YYYY-MM-DD', NULL),
           IFF(NULLIF(TRIM(status), '') IS NULL, 'status: required nonblank', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.PURCHASE_ORDERS
UNION ALL
SELECT 'PO_LINES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(po_line_id)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(po_line_id), '') IS NULL, 'po_line_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(po_id), '') IS NULL, 'po_id: required nonblank', NULL),
           IFF(line_number IS NULL OR NOT REGEXP_LIKE(line_number, '[0-9]+') OR TRY_TO_DECIMAL(line_number, 38, 0) IS NULL, 'line_number: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(NULLIF(TRIM(description), '') IS NULL, 'description: required nonblank', NULL),
           IFF(quantity IS NULL OR NOT REGEXP_LIKE(quantity, '[0-9]+') OR TRY_TO_DECIMAL(quantity, 38, 0) IS NULL, 'quantity: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(unit_price_cents IS NULL OR NOT REGEXP_LIKE(unit_price_cents, '[0-9]+') OR TRY_TO_DECIMAL(unit_price_cents, 38, 0) IS NULL, 'unit_price_cents: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.PO_LINES
UNION ALL
SELECT 'INVOICES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(invoice_id)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(invoice_id), '') IS NULL, 'invoice_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(supplier_id), '') IS NULL, 'supplier_id: required nonblank', NULL),
           IFF(invoice_date IS NULL OR NOT REGEXP_LIKE(invoice_date, '[0-9]{4}-[0-9]{2}-[0-9]{2}') OR TRY_TO_DATE(invoice_date, 'YYYY-MM-DD') IS NULL, 'invoice_date: required YYYY-MM-DD', NULL),
           IFF(due_date IS NULL OR NOT REGEXP_LIKE(due_date, '[0-9]{4}-[0-9]{2}-[0-9]{2}') OR TRY_TO_DATE(due_date, 'YYYY-MM-DD') IS NULL, 'due_date: required YYYY-MM-DD', NULL),
           IFF(NULLIF(TRIM(invoice_number), '') IS NULL, 'invoice_number: required nonblank', NULL),
           IFF(invoice_total_cents IS NULL OR NOT REGEXP_LIKE(invoice_total_cents, '[0-9]+') OR TRY_TO_DECIMAL(invoice_total_cents, 38, 0) IS NULL, 'invoice_total_cents: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.INVOICES
UNION ALL
SELECT 'INVOICE_LINES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(invoice_line_id)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(invoice_line_id), '') IS NULL, 'invoice_line_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(invoice_id), '') IS NULL, 'invoice_id: required nonblank', NULL),
           IFF(line_number IS NULL OR NOT REGEXP_LIKE(line_number, '[0-9]+') OR TRY_TO_DECIMAL(line_number, 38, 0) IS NULL, 'line_number: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(NULLIF(TRIM(description), '') IS NULL, 'description: required nonblank', NULL),
           IFF(quantity IS NULL OR NOT REGEXP_LIKE(quantity, '[0-9]+') OR TRY_TO_DECIMAL(quantity, 38, 0) IS NULL, 'quantity: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(unit_price_cents IS NULL OR NOT REGEXP_LIKE(unit_price_cents, '[0-9]+') OR TRY_TO_DECIMAL(unit_price_cents, 38, 0) IS NULL, 'unit_price_cents: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.INVOICE_LINES
UNION ALL
SELECT 'PAYMENTS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(payment_id)) AS natural_key,
       source_filename, source_file_row_number,
       ARRAY_CONSTRUCT_COMPACT(
           IFF(NULLIF(TRIM(payment_id), '') IS NULL, 'payment_id: required nonblank', NULL),
           IFF(NULLIF(TRIM(invoice_id), '') IS NULL, 'invoice_id: required nonblank', NULL),
           IFF(payment_date IS NULL OR NOT REGEXP_LIKE(payment_date, '[0-9]{4}-[0-9]{2}-[0-9]{2}') OR TRY_TO_DATE(payment_date, 'YYYY-MM-DD') IS NULL, 'payment_date: required YYYY-MM-DD', NULL),
           IFF(amount_cents IS NULL OR NOT REGEXP_LIKE(amount_cents, '[0-9]+') OR TRY_TO_DECIMAL(amount_cents, 38, 0) IS NULL, 'amount_cents: required nonnegative integer within NUMBER(38,0)', NULL),
           IFF(source_updated_at IS NULL OR NOT REGEXP_LIKE(source_updated_at, '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}') OR TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') IS NULL, 'source_updated_at: required UTC ISO second timestamp', NULL),
           IFF(batch_id IS NULL OR batch_id NOT IN ('BASE', 'CORRECTION'), 'batch_id: BASE or CORRECTION required', NULL)
       ) AS errors
FROM RAW.PAYMENTS
) WHERE ARRAY_SIZE(errors) > 0;

-- Identical replay duplicates are allowed; conflicting same-timestamp rows are not.
CREATE OR REPLACE VIEW STAGING.SOURCE_VERSION_CONFLICTS AS
SELECT 'SUPPLIERS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(supplier_id, effective_from)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(supplier_id, supplier_name, category, country, payment_terms_days, effective_from))) AS distinct_payloads
FROM RAW.SUPPLIERS
GROUP BY supplier_id, effective_from, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(supplier_id, supplier_name, category, country, payment_terms_days, effective_from))) > 1
UNION ALL
SELECT 'PURCHASE_ORDERS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(po_id)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(po_id, supplier_id, order_date, status))) AS distinct_payloads
FROM RAW.PURCHASE_ORDERS
GROUP BY po_id, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(po_id, supplier_id, order_date, status))) > 1
UNION ALL
SELECT 'PO_LINES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(po_line_id)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(po_line_id, po_id, line_number, description, quantity, unit_price_cents))) AS distinct_payloads
FROM RAW.PO_LINES
GROUP BY po_line_id, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(po_line_id, po_id, line_number, description, quantity, unit_price_cents))) > 1
UNION ALL
SELECT 'INVOICES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(invoice_id)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(invoice_id, supplier_id, invoice_date, due_date, invoice_number, invoice_total_cents))) AS distinct_payloads
FROM RAW.INVOICES
GROUP BY invoice_id, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(invoice_id, supplier_id, invoice_date, due_date, invoice_number, invoice_total_cents))) > 1
UNION ALL
SELECT 'INVOICE_LINES' AS source_table, TO_JSON(ARRAY_CONSTRUCT(invoice_line_id)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(invoice_line_id, invoice_id, line_number, po_line_id, description, quantity, unit_price_cents))) AS distinct_payloads
FROM RAW.INVOICE_LINES
GROUP BY invoice_line_id, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(invoice_line_id, invoice_id, line_number, po_line_id, description, quantity, unit_price_cents))) > 1
UNION ALL
SELECT 'PAYMENTS' AS source_table, TO_JSON(ARRAY_CONSTRUCT(payment_id)) AS natural_key,
       source_updated_at, COUNT(*) AS landed_rows,
       COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(payment_id, invoice_id, payment_date, amount_cents))) AS distinct_payloads
FROM RAW.PAYMENTS
GROUP BY payment_id, source_updated_at
HAVING COUNT(DISTINCT TO_JSON(ARRAY_CONSTRUCT(payment_id, invoice_id, payment_date, amount_cents))) > 1;

-- Invalid optional PO references are analytical exceptions, not rejected rows.
CREATE OR REPLACE VIEW STAGING.RELATIONSHIP_ERRORS AS
SELECT 'PO_WITHOUT_LINES' AS check_name, p.po_id AS record_key
FROM STAGING.STG_PURCHASE_ORDERS p
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_PO_LINES l WHERE l.po_id = p.po_id)
UNION ALL
SELECT 'INVOICE_WITHOUT_LINES', i.invoice_id FROM STAGING.STG_INVOICES i
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_INVOICE_LINES l WHERE l.invoice_id = i.invoice_id)
UNION ALL
SELECT 'PO_LINE_MISSING_PARENT', l.po_line_id FROM STAGING.STG_PO_LINES l
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_PURCHASE_ORDERS p WHERE p.po_id = l.po_id)
UNION ALL
SELECT 'INVOICE_LINE_MISSING_PARENT', l.invoice_line_id FROM STAGING.STG_INVOICE_LINES l
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_INVOICES i WHERE i.invoice_id = l.invoice_id)
UNION ALL
SELECT 'PAYMENT_MISSING_INVOICE', p.payment_id FROM STAGING.STG_PAYMENTS p
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_INVOICES i WHERE i.invoice_id = p.invoice_id)
UNION ALL
SELECT 'PO_SUPPLIER_NO_EFFECTIVE_VERSION', p.po_id FROM STAGING.STG_PURCHASE_ORDERS p
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_SUPPLIERS s
                  WHERE s.supplier_id = p.supplier_id AND s.effective_from <= p.order_date)
UNION ALL
SELECT 'INVOICE_SUPPLIER_NO_EFFECTIVE_VERSION', i.invoice_id FROM STAGING.STG_INVOICES i
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_SUPPLIERS s
                  WHERE s.supplier_id = i.supplier_id AND s.effective_from <= i.invoice_date)
UNION ALL
SELECT 'PAYMENT_SUPPLIER_NO_EFFECTIVE_VERSION', p.payment_id
FROM STAGING.STG_PAYMENTS p JOIN STAGING.STG_INVOICES i ON i.invoice_id = p.invoice_id
WHERE NOT EXISTS (SELECT 1 FROM STAGING.STG_SUPPLIERS s
                  WHERE s.supplier_id = i.supplier_id AND s.effective_from <= p.payment_date)
UNION ALL
SELECT 'DUPLICATE_PO_LINE_NUMBER', TO_JSON(ARRAY_CONSTRUCT(po_id, line_number))
FROM STAGING.STG_PO_LINES GROUP BY po_id, line_number HAVING COUNT(*) > 1
UNION ALL
SELECT 'DUPLICATE_INVOICE_LINE_NUMBER', TO_JSON(ARRAY_CONSTRUCT(invoice_id, line_number))
FROM STAGING.STG_INVOICE_LINES GROUP BY invoice_id, line_number HAVING COUNT(*) > 1
UNION ALL
SELECT 'PO_DATE_OUTSIDE_DIM_DATE', po_id FROM STAGING.STG_PURCHASE_ORDERS
WHERE order_date NOT BETWEEN '2025-01-01'::DATE AND '2025-12-31'::DATE
UNION ALL
SELECT 'INVOICE_DATE_OUTSIDE_DIM_DATE', invoice_id FROM STAGING.STG_INVOICES
WHERE invoice_date NOT BETWEEN '2025-01-01'::DATE AND '2025-12-31'::DATE
   OR due_date NOT BETWEEN '2025-01-01'::DATE AND '2025-12-31'::DATE
UNION ALL
SELECT 'PAYMENT_DATE_OUTSIDE_DIM_DATE', payment_id FROM STAGING.STG_PAYMENTS
WHERE payment_date NOT BETWEEN '2025-01-01'::DATE AND '2025-12-31'::DATE;

-- Check first arrival of each distinct natural-key/source-timestamp version.
-- An old, already-seen file replay keeps its original first_seen and remains valid.
-- A previously unseen stale correction fails instead of silently disappearing.
CREATE OR REPLACE VIEW STAGING.SOURCE_ORDER_ERRORS AS
WITH versions AS (
    SELECT 'SUPPLIERS' AS source_table,
           TO_JSON(ARRAY_CONSTRUCT(supplier_id, effective_from)) AS natural_key,
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS') AS source_updated_at,
           MIN(ingested_at) AS first_seen, MAX(IFF(batch_id = 'CORRECTION', 1, 0)) AS is_correction
    FROM RAW.SUPPLIERS GROUP BY supplier_id, effective_from, source_updated_at
    UNION ALL
    SELECT 'PURCHASE_ORDERS', TO_JSON(ARRAY_CONSTRUCT(po_id)),
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
           MIN(ingested_at), MAX(IFF(batch_id = 'CORRECTION', 1, 0))
    FROM RAW.PURCHASE_ORDERS GROUP BY po_id, source_updated_at
    UNION ALL
    SELECT 'PO_LINES', TO_JSON(ARRAY_CONSTRUCT(po_line_id)),
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
           MIN(ingested_at), MAX(IFF(batch_id = 'CORRECTION', 1, 0))
    FROM RAW.PO_LINES GROUP BY po_line_id, source_updated_at
    UNION ALL
    SELECT 'INVOICES', TO_JSON(ARRAY_CONSTRUCT(invoice_id)),
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
           MIN(ingested_at), MAX(IFF(batch_id = 'CORRECTION', 1, 0))
    FROM RAW.INVOICES GROUP BY invoice_id, source_updated_at
    UNION ALL
    SELECT 'INVOICE_LINES', TO_JSON(ARRAY_CONSTRUCT(invoice_line_id)),
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
           MIN(ingested_at), MAX(IFF(batch_id = 'CORRECTION', 1, 0))
    FROM RAW.INVOICE_LINES GROUP BY invoice_line_id, source_updated_at
    UNION ALL
    SELECT 'PAYMENTS', TO_JSON(ARRAY_CONSTRUCT(payment_id)),
           TRY_TO_TIMESTAMP_NTZ(source_updated_at, 'YYYY-MM-DD"T"HH24:MI:SS'),
           MIN(ingested_at), MAX(IFF(batch_id = 'CORRECTION', 1, 0))
    FROM RAW.PAYMENTS GROUP BY payment_id, source_updated_at
), ordered AS (
    SELECT *, MAX(source_updated_at) OVER (
        PARTITION BY source_table, natural_key ORDER BY first_seen, source_updated_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS prior_latest_source_updated_at
    FROM versions
)
SELECT source_table, natural_key, source_updated_at, first_seen, prior_latest_source_updated_at
FROM ordered
WHERE is_correction = 1 AND source_updated_at < prior_latest_source_updated_at;

