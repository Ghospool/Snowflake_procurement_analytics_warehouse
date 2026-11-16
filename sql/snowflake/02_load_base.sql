-- Run with SnowSQL/Snowflake CLI from the purchase-to-pay-analytics project root.
-- PUT is a client command; Snowsight worksheets do not read local file:// paths.
-- Never mix corrected files into this prefix. Never set FORCE = TRUE.
USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;

PUT 'file://data/base/suppliers.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.SUPPLIERS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/suppliers.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/base/purchase_orders.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PURCHASE_ORDERS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/purchase_orders.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/base/po_lines.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PO_LINES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/po_lines.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/base/invoices.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.INVOICES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/invoices.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/base/invoice_lines.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.INVOICE_LINES
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6, t.$7, t.$8, t.$9,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/invoice_lines.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

PUT 'file://data/base/payments.csv' @RAW.P2P_STAGE/base/ AUTO_COMPRESS = TRUE OVERWRITE = FALSE;
COPY INTO RAW.PAYMENTS
FROM (SELECT t.$1, t.$2, t.$3, t.$4, t.$5, t.$6,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$START_SCAN_TIME
      FROM @RAW.P2P_STAGE/base/payments.csv.gz t)
FILE_FORMAT = (FORMAT_NAME = RAW.P2P_CSV)
ON_ERROR = 'ABORT_STATEMENT' FORCE = FALSE;

-- Inspect every COPY result for loaded/skipped files before proceeding.
-- Optional owner/admin diagnostic: raw-table history visibility is not granted
-- to the loader, and must not make an otherwise successful loader run fail.
-- SELECT TABLE_NAME, FILE_NAME, ROW_COUNT, STATUS, FIRST_ERROR_MESSAGE
-- FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
--     TABLE_NAME => 'P2P_ANALYTICS.RAW.PAYMENTS',
--     START_TIME => DATEADD('day', -1, CURRENT_TIMESTAMP())));
