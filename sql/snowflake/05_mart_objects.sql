USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- Snowflake standard-table PK/FK constraints are informational, not enforced.
-- Executable grain / FK / interval checks live in 09_validate_marts.sql.
CREATE TABLE IF NOT EXISTS MART.DIM_DATE (
    date_key NUMBER(8,0) NOT NULL, calendar_date DATE NOT NULL,
    calendar_year NUMBER(4,0), calendar_month NUMBER(2,0), day_of_month NUMBER(2,0),
    month_start DATE, PRIMARY KEY (date_key)
);
CREATE TABLE IF NOT EXISTS MART.DIM_SUPPLIER (
    supplier_key VARCHAR NOT NULL, supplier_id VARCHAR NOT NULL,
    supplier_name VARCHAR NOT NULL, category VARCHAR NOT NULL, country VARCHAR NOT NULL,
    payment_terms_days NUMBER(38,0) NOT NULL,
    valid_from DATE NOT NULL, valid_to DATE NOT NULL, is_current BOOLEAN NOT NULL,
    source_updated_at TIMESTAMP_NTZ NOT NULL, row_hash NUMBER(19,0) NOT NULL,
    PRIMARY KEY (supplier_key)
);
CREATE TABLE IF NOT EXISTS MART.FACT_PURCHASING (
    po_line_id VARCHAR NOT NULL, po_id VARCHAR NOT NULL, line_number NUMBER(38,0) NOT NULL,
    supplier_id VARCHAR NOT NULL, supplier_key VARCHAR NOT NULL,
    order_date DATE NOT NULL, order_date_key NUMBER(8,0) NOT NULL, status VARCHAR,
    description VARCHAR, quantity NUMBER(38,0) NOT NULL, unit_price_cents NUMBER(38,0) NOT NULL,
    ordered_amount_cents NUMBER(38,0) NOT NULL, ordered_amount_usd NUMBER(38,2) NOT NULL,
    source_updated_at TIMESTAMP_NTZ NOT NULL, row_hash NUMBER(19,0) NOT NULL,
    PRIMARY KEY (po_line_id), FOREIGN KEY (supplier_key) REFERENCES MART.DIM_SUPPLIER(supplier_key),
    FOREIGN KEY (order_date_key) REFERENCES MART.DIM_DATE(date_key)
);
CREATE TABLE IF NOT EXISTS MART.FACT_INVOICE (
    invoice_line_id VARCHAR NOT NULL, invoice_id VARCHAR NOT NULL, line_number NUMBER(38,0) NOT NULL,
    supplier_id VARCHAR NOT NULL, supplier_key VARCHAR NOT NULL,
    invoice_date DATE NOT NULL, invoice_date_key NUMBER(8,0) NOT NULL,
    due_date DATE NOT NULL, due_date_key NUMBER(8,0) NOT NULL,
    invoice_number VARCHAR NOT NULL, invoice_number_normalized VARCHAR NOT NULL,
    invoice_total_cents NUMBER(38,0) NOT NULL,
    po_line_id VARCHAR, po_id VARCHAR, description VARCHAR,
    quantity NUMBER(38,0) NOT NULL, unit_price_cents NUMBER(38,0) NOT NULL,
    invoiced_amount_cents NUMBER(38,0) NOT NULL, invoiced_amount_usd NUMBER(38,2) NOT NULL,
    no_po BOOLEAN NOT NULL, invalid_po_reference BOOLEAN NOT NULL,
    supplier_mismatch BOOLEAN NOT NULL, price_mismatch BOOLEAN NOT NULL,
    header_total_mismatch BOOLEAN NOT NULL, duplicate_invoice_number BOOLEAN NOT NULL,
    source_updated_at TIMESTAMP_NTZ NOT NULL, row_hash NUMBER(19,0) NOT NULL,
    PRIMARY KEY (invoice_line_id), FOREIGN KEY (supplier_key) REFERENCES MART.DIM_SUPPLIER(supplier_key),
    FOREIGN KEY (invoice_date_key) REFERENCES MART.DIM_DATE(date_key),
    FOREIGN KEY (due_date_key) REFERENCES MART.DIM_DATE(date_key)
);
CREATE TABLE IF NOT EXISTS MART.FACT_PAYMENT (
    payment_id VARCHAR NOT NULL, invoice_id VARCHAR NOT NULL,
    supplier_id VARCHAR NOT NULL, supplier_key VARCHAR NOT NULL,
    payment_date DATE NOT NULL, payment_date_key NUMBER(8,0) NOT NULL,
    amount_cents NUMBER(38,0) NOT NULL, amount_usd NUMBER(38,2) NOT NULL,
    source_updated_at TIMESTAMP_NTZ NOT NULL, row_hash NUMBER(19,0) NOT NULL,
    PRIMARY KEY (payment_id), FOREIGN KEY (supplier_key) REFERENCES MART.DIM_SUPPLIER(supplier_key),
    FOREIGN KEY (payment_date_key) REFERENCES MART.DIM_DATE(date_key)
);

-- Full latest natural-key supplier history, not merely the current correction batch.
-- A late inserted version shortens the previous interval even if its payload is unchanged.
CREATE OR REPLACE VIEW STAGING.SRC_DIM_SUPPLIER AS
WITH intervals AS (
    SELECT supplier_id || '|' || TO_CHAR(effective_from, 'YYYY-MM-DD') AS supplier_key,
           supplier_id, supplier_name, category, country, payment_terms_days,
           effective_from AS valid_from,
           LEAD(effective_from, 1, '9999-12-31'::DATE)
               OVER (PARTITION BY supplier_id ORDER BY effective_from) AS valid_to,
           source_updated_at
    FROM STAGING.STG_SUPPLIERS
)
SELECT supplier_key, supplier_id, supplier_name, category, country, payment_terms_days,
       valid_from, valid_to, valid_to = '9999-12-31'::DATE AS is_current, source_updated_at,
       HASH(supplier_id, supplier_name, category, country, payment_terms_days, valid_from, valid_to) AS row_hash
FROM intervals;

CREATE OR REPLACE VIEW STAGING.SRC_FACT_PURCHASING AS
WITH src AS (
    SELECT l.po_line_id, l.po_id, l.line_number, p.supplier_id, s.supplier_key,
           p.order_date, TO_NUMBER(TO_CHAR(p.order_date, 'YYYYMMDD')) AS order_date_key,
           p.status, l.description, l.quantity, l.unit_price_cents,
           l.quantity * l.unit_price_cents AS ordered_amount_cents,
           (l.quantity * l.unit_price_cents / 100)::NUMBER(38,2) AS ordered_amount_usd,
           GREATEST(l.source_updated_at, p.source_updated_at, s.source_updated_at) AS source_updated_at
    FROM STAGING.STG_PO_LINES l
    JOIN STAGING.STG_PURCHASE_ORDERS p ON p.po_id = l.po_id
    JOIN MART.DIM_SUPPLIER s ON s.supplier_id = p.supplier_id
        AND p.order_date >= s.valid_from AND p.order_date < s.valid_to
)
SELECT src.*, HASH(po_line_id, po_id, line_number, supplier_id, supplier_key, order_date,
                  status, description, quantity, unit_price_cents, ordered_amount_cents) AS row_hash
FROM src;

CREATE OR REPLACE VIEW STAGING.SRC_FACT_INVOICE AS
WITH line_totals AS (
    SELECT invoice_id, SUM(quantity * unit_price_cents) AS line_total_cents
    FROM STAGING.STG_INVOICE_LINES GROUP BY invoice_id
), number_counts AS (
    -- Normalize with UPPER(TRIM(...)); internal whitespace is intentionally preserved.
    SELECT supplier_id, UPPER(TRIM(invoice_number)) AS normalized_number,
           COUNT(DISTINCT invoice_id) AS invoice_count
    FROM STAGING.STG_INVOICES GROUP BY supplier_id, UPPER(TRIM(invoice_number))
), src AS (
    SELECT l.invoice_line_id, l.invoice_id, l.line_number, i.supplier_id, s.supplier_key,
           i.invoice_date, TO_NUMBER(TO_CHAR(i.invoice_date, 'YYYYMMDD')) AS invoice_date_key,
           i.due_date, TO_NUMBER(TO_CHAR(i.due_date, 'YYYYMMDD')) AS due_date_key,
           i.invoice_number, UPPER(TRIM(i.invoice_number)) AS invoice_number_normalized,
           i.invoice_total_cents, l.po_line_id, p.po_id, l.description, l.quantity, l.unit_price_cents,
           l.quantity * l.unit_price_cents AS invoiced_amount_cents,
           (l.quantity * l.unit_price_cents / 100)::NUMBER(38,2) AS invoiced_amount_usd,
           l.po_line_id IS NULL AS no_po,
           l.po_line_id IS NOT NULL AND pl.po_line_id IS NULL AS invalid_po_reference,
           pl.po_line_id IS NOT NULL AND i.supplier_id <> p.supplier_id AS supplier_mismatch,
           pl.po_line_id IS NOT NULL AND l.unit_price_cents <> pl.unit_price_cents AS price_mismatch,
           i.invoice_total_cents <> lt.line_total_cents AS header_total_mismatch,
           nc.invoice_count > 1 AS duplicate_invoice_number,
           GREATEST(l.source_updated_at, i.source_updated_at, s.source_updated_at,
                    COALESCE(pl.source_updated_at, l.source_updated_at),
                    COALESCE(p.source_updated_at, l.source_updated_at)) AS source_updated_at
    FROM STAGING.STG_INVOICE_LINES l
    JOIN STAGING.STG_INVOICES i ON i.invoice_id = l.invoice_id
    JOIN line_totals lt ON lt.invoice_id = i.invoice_id
    JOIN number_counts nc ON nc.supplier_id = i.supplier_id
        AND nc.normalized_number = UPPER(TRIM(i.invoice_number))
    JOIN MART.DIM_SUPPLIER s ON s.supplier_id = i.supplier_id
        AND i.invoice_date >= s.valid_from AND i.invoice_date < s.valid_to
    LEFT JOIN STAGING.STG_PO_LINES pl ON pl.po_line_id = l.po_line_id
    LEFT JOIN STAGING.STG_PURCHASE_ORDERS p ON p.po_id = pl.po_id
)
SELECT src.*, HASH(invoice_line_id, invoice_id, line_number, supplier_id, supplier_key,
                  invoice_date, due_date, invoice_number, invoice_total_cents, po_line_id, po_id,
                  description, quantity, unit_price_cents, invoiced_amount_cents,
                  no_po, invalid_po_reference, supplier_mismatch, price_mismatch,
                  header_total_mismatch, duplicate_invoice_number) AS row_hash
FROM src;

CREATE OR REPLACE VIEW STAGING.SRC_FACT_PAYMENT AS
WITH src AS (
    SELECT p.payment_id, p.invoice_id, i.supplier_id, s.supplier_key, p.payment_date,
           TO_NUMBER(TO_CHAR(p.payment_date, 'YYYYMMDD')) AS payment_date_key,
           p.amount_cents, (p.amount_cents / 100)::NUMBER(38,2) AS amount_usd,
           GREATEST(p.source_updated_at, i.source_updated_at, s.source_updated_at) AS source_updated_at
    FROM STAGING.STG_PAYMENTS p
    JOIN STAGING.STG_INVOICES i ON i.invoice_id = p.invoice_id
    JOIN MART.DIM_SUPPLIER s ON s.supplier_id = i.supplier_id
        AND p.payment_date >= s.valid_from AND p.payment_date < s.valid_to
)
SELECT src.*, HASH(payment_id, invoice_id, supplier_id, supplier_key, payment_date, amount_cents) AS row_hash
FROM src;
