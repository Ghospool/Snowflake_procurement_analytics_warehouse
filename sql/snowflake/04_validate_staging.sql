USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- These queries return actionable failing rows, including physical file/row for parse errors.
SELECT * FROM STAGING.SOURCE_ROW_ERRORS ORDER BY source_table, source_filename, source_file_row_number;
SELECT * FROM STAGING.SOURCE_VERSION_CONFLICTS ORDER BY source_table, natural_key, source_updated_at;
SELECT * FROM STAGING.SOURCE_ORDER_ERRORS ORDER BY source_table, natural_key, first_seen;
SELECT * FROM STAGING.RELATIONSHIP_ERRORS ORDER BY check_name, record_key;

-- Run the client in stop-on-error mode. No MERGE may follow a failed gate.
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
END;
$$;
