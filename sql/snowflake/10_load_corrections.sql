-- Run only after the base pipeline. Keep base files immutable.
-- Relative client paths are resolved from the project root, not sql/snowflake.
-- Replaying this file uses the SAME prefix; do not invent a replay prefix.
USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;

PUT 'file://data/corrections/suppliers.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.SUPPLIERS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/suppliers.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/corrections/purchase_orders.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PURCHASE_ORDERS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/purchase_orders.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/corrections/po_lines.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PO_LINES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/po_lines.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/corrections/invoices.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.INVOICES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/invoices.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/corrections/invoice_lines.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.INVOICE_LINES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8, t.$9,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/invoice_lines.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/corrections/payments.csv' @RAW.P2P_STAGE/corrections/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PAYMENTS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/corrections/payments.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

-- Next run 04_validate_staging.sql, 06_refresh_marts.sql, 09_validate_marts.sql.
-- Repeat 10 + 04 + 06 + 09 for an identical correction replay.
-- COPY history is time-limited. Even if an old file is physically appended again,
-- STAGING latest-key selection and MERGE preserve semantic idempotence.
