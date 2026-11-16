USE DATABASE P2P_ANALYTICS;
USE WAREHOUSE P2P_WH;
-- Zero rows is success. This is not an execution result until actually run.
SELECT * FROM STAGING.MART_QUALITY_FAILURES ORDER BY check_name, record_key;
EXECUTE IMMEDIATE $$
DECLARE
    invalid_mart EXCEPTION (-20002, 'Mart checks failed; inspect STAGING.MART_QUALITY_FAILURES.');
BEGIN
    IF (EXISTS (SELECT 1 FROM STAGING.MART_QUALITY_FAILURES)) THEN
        RAISE invalid_mart;
    END IF;
END;
$$;

-- Known business exceptions are visible separately and should not fail the gate.
SELECT invoice_line_id, invoice_id, po_line_id, no_po, invalid_po_reference,
       supplier_mismatch, price_mismatch, header_total_mismatch, duplicate_invoice_number
FROM MART.FACT_INVOICE
WHERE no_po OR invalid_po_reference OR supplier_mismatch OR price_mismatch
   OR header_total_mismatch OR duplicate_invoice_number
ORDER BY invoice_id, invoice_line_id;
SELECT invoice_id, header_total_cents, line_total_cents, header_difference_cents
FROM MART.INVOICE_TOTALS WHERE header_difference_cents <> 0 ORDER BY invoice_id;
SELECT * FROM MART.INVOICE_BALANCES_AS_OF WHERE is_overpaid ORDER BY invoice_id;
