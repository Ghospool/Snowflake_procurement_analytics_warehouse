USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
ALTER SESSION SET ERROR_ON_NONDETERMINISTIC_MERGE = TRUE;
-- Single loader, no concurrent COPY/RAW writes during this refresh.
-- There is no timestamp watermark: source views cover every latest natural key.
-- Every MERGE is in one transaction, including SCD interval and fact-key restatement.
EXECUTE IMMEDIATE $$
DECLARE
    invalid_source EXCEPTION (-20001, 'Source validation failed; inspect STAGING validation views.');
BEGIN
    IF (EXISTS (SELECT 1 FROM STAGING.SOURCE_ROW_ERRORS)
        OR EXISTS (SELECT 1 FROM STAGING.SOURCE_VERSION_CONFLICTS)
        OR EXISTS (SELECT 1 FROM STAGING.SOURCE_ORDER_ERRORS)
        OR EXISTS (SELECT 1 FROM STAGING.RELATIONSHIP_ERRORS)) THEN
        RAISE invalid_source;
    END IF;

    BEGIN TRANSACTION;
    MERGE INTO MART.DIM_DATE t
    USING (
        SELECT TO_NUMBER(TO_CHAR(calendar_date, 'YYYYMMDD')) AS date_key,
               calendar_date, YEAR(calendar_date) AS calendar_year,
               MONTH(calendar_date) AS calendar_month, DAY(calendar_date) AS day_of_month,
               DATE_TRUNC('month', calendar_date)::DATE AS month_start
        FROM (
            SELECT DATEADD('day', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
                           '2025-01-01'::DATE)::DATE AS calendar_date
            FROM TABLE(GENERATOR(ROWCOUNT => 365))
        )
    ) s ON t.date_key = s.date_key
    WHEN NOT MATCHED THEN INSERT ALL BY NAME;

    MERGE INTO MART.DIM_SUPPLIER t
    USING STAGING.SRC_DIM_SUPPLIER s ON t.supplier_key = s.supplier_key
    WHEN MATCHED AND s.source_updated_at > t.source_updated_at THEN UPDATE ALL BY NAME
    WHEN MATCHED AND s.row_hash <> t.row_hash THEN UPDATE ALL BY NAME
    WHEN NOT MATCHED THEN INSERT ALL BY NAME;

    -- First branch: normal newer-source upserts. Second branch: dependency restatement.
    -- A late effective supplier version changes historical keys; corrected parents/POs,
    -- invoice totals and duplicate-number peers can change rows with unchanged own timestamps.
    -- row_hash excludes load metadata, so identical replay performs no matched-row update.
    MERGE INTO MART.FACT_PURCHASING t
    USING STAGING.SRC_FACT_PURCHASING s ON t.po_line_id = s.po_line_id
    WHEN MATCHED AND s.source_updated_at > t.source_updated_at THEN UPDATE ALL BY NAME
    WHEN MATCHED AND s.row_hash <> t.row_hash THEN UPDATE ALL BY NAME
    WHEN NOT MATCHED THEN INSERT ALL BY NAME;

    MERGE INTO MART.FACT_INVOICE t
    USING STAGING.SRC_FACT_INVOICE s ON t.invoice_line_id = s.invoice_line_id
    WHEN MATCHED AND s.source_updated_at > t.source_updated_at THEN UPDATE ALL BY NAME
    WHEN MATCHED AND s.row_hash <> t.row_hash THEN UPDATE ALL BY NAME
    WHEN NOT MATCHED THEN INSERT ALL BY NAME;

    MERGE INTO MART.FACT_PAYMENT t
    USING STAGING.SRC_FACT_PAYMENT s ON t.payment_id = s.payment_id
    WHEN MATCHED AND s.source_updated_at > t.source_updated_at THEN UPDATE ALL BY NAME
    WHEN MATCHED AND s.row_hash <> t.row_hash THEN UPDATE ALL BY NAME
    WHEN NOT MATCHED THEN INSERT ALL BY NAME;
    COMMIT;
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;
