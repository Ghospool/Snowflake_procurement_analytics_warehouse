import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts' / 'validate_local.py'
spec = importlib.util.spec_from_file_location('validate_local', MODULE)
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class LocalValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.db = local.connect_database()
        self.rows = {
            'suppliers': [dict(supplier_id='S1', supplier_name='Supplier One', category='Old', country='US', payment_terms_days=30, effective_from='2025-01-01'),
                          dict(supplier_id='S1', supplier_name='Supplier One', category='New', country='US', payment_terms_days=30, effective_from='2025-03-01'),
                          dict(supplier_id='S2', supplier_name='Supplier Two', category='Other', country='US', payment_terms_days=30, effective_from='2025-01-01')],
            'purchase_orders': [dict(po_id='PO1', supplier_id='S1', order_date='2025-01-10', status='OPEN')],
            'po_lines': [dict(po_line_id='PL1', po_id='PO1', line_number=1, description='A', quantity=1, unit_price_cents=100),
                         dict(po_line_id='PL2', po_id='PO1', line_number=2, description='B', quantity=2, unit_price_cents=100)],
            'invoices': [dict(invoice_id='I1', supplier_id='S1', invoice_date='2025-02-01', due_date='2025-02-28', invoice_number=' A-1 ', invoice_total_cents=999)],
            'invoice_lines': [dict(invoice_line_id='IL1', invoice_id='I1', line_number=1, po_line_id='PL1', description='A', quantity=1, unit_price_cents=100),
                              dict(invoice_line_id='IL2', invoice_id='I1', line_number=2, po_line_id='PL2', description='B', quantity=2, unit_price_cents=100)],
            'payments': [dict(payment_id='P1', invoice_id='I1', payment_date='2025-02-15', amount_cents=50),
                         dict(payment_id='P2', invoice_id='I1', payment_date='2025-03-01', amount_cents=100),
                         dict(payment_id='P3', invoice_id='I1', payment_date='2025-04-01', amount_cents=150)],
        }

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def write_batch(self, rows=None, name='base', correction=False):
        directory = self.root / name
        directory.mkdir(parents=True, exist_ok=True)
        rows = self.rows if rows is None else rows
        for table, columns in local.COLUMNS.items():
            with (directory / (table + '.csv')).open('w', newline='', encoding='utf-8') as handle:
                writer = csv.DictWriter(handle, fieldnames=columns + ['source_updated_at', 'batch_id'])
                writer.writeheader()
                for record in rows.get(table, []):
                    writer.writerow(dict(record, source_updated_at='2025-03-15T00:00:00' if correction else '2025-03-01T00:00:00', batch_id='CORRECTION' if correction else 'BASE'))
        return directory

    def query(self, sql):
        return [dict(row) for row in self.db.execute(sql)]

    def test_multiline_multipayment_is_grain_safe_and_future_payment_excluded(self):
        local.load_batch(self.db, self.write_batch())
        snapshot = local.snapshot_metrics(self.db)
        self.assertEqual(snapshot['facts']['fact_invoice']['count'], 2)
        self.assertEqual(snapshot['facts']['fact_invoice']['cents'], 300)
        self.assertEqual(snapshot['facts']['fact_payment']['count'], 3)
        self.assertEqual(snapshot['facts']['fact_payment']['cents'], 300)
        balance = snapshot['balances'][0]
        self.assertEqual(balance['paid_to_date_cents'], 150)
        self.assertEqual(balance['balance_cents'], 150)
        self.assertEqual(balance['header_difference_cents'], 699)
        self.assertEqual(snapshot['exceptions'][0]['header_total_mismatch'], 1)
        self.assertIsNone(snapshot['payment_performance'][0]['paid_in_full_date'])
        self.assertEqual(snapshot['supplier_spend'][0]['exception_invoice_count'], 1)
        self.assertEqual(snapshot['supplier_spend'][0]['invoice_count'], 1)
        self.assertEqual(self.query('SELECT COUNT(*) n FROM dim_date')[0]['n'], 365)

    def test_correction_replay_restatements_and_old_batch_do_not_regress(self):
        base = self.write_batch()
        local.load_batch(self.db, base)
        before = local.snapshot_metrics(self.db)
        replay = local.load_batch(self.db, base)
        self.assertEqual(replay['applied_rows'], 0)
        self.assertEqual(before, local.snapshot_metrics(self.db))
        changed_line = dict(self.rows['invoice_lines'][0], unit_price_cents=150)
        changed_header = dict(self.rows['invoices'][0], invoice_total_cents=350)
        changed_supplier = dict(self.rows['suppliers'][1], category='Restated')
        correction = self.write_batch({'invoice_lines': [changed_line], 'invoices': [changed_header],
                                       'payments': [dict(self.rows['payments'][1], amount_cents=300)],
                                       'suppliers': [changed_supplier]}, 'corrections', True)
        local.load_batch(self.db, correction)
        after = local.snapshot_metrics(self.db)
        self.assertEqual(after['balances'][0]['balance_cents'], 0)
        self.assertEqual(after['balances'][0]['header_difference_cents'], 0)
        self.assertEqual(after['payment_performance'][0]['paid_in_full_date'], '2025-03-01')
        self.assertEqual(after['payment_performance'][0]['days_late'], 1)
        self.assertEqual(self.query("SELECT category FROM dim_supplier WHERE supplier_key='S1|2025-03-01'")[0]['category'], 'Restated')
        self.assertEqual(self.query("SELECT supplier_key FROM fact_invoice WHERE invoice_line_id='IL1'")[0]['supplier_key'], 'S1|2025-01-01')
        self.assertEqual(self.query("SELECT supplier_key FROM fact_payment WHERE payment_id='P2'")[0]['supplier_key'], 'S1|2025-03-01')
        self.assertEqual(local.load_batch(self.db, correction)['applied_rows'], 0)
        self.assertEqual(after, local.snapshot_metrics(self.db))
        local.load_batch(self.db, base)
        self.assertEqual(after, local.snapshot_metrics(self.db))
        self.assertEqual(self.query('SELECT COUNT(*) n FROM raw_payments')[0]['n'], 11)

    def test_same_timestamp_conflicting_duplicate_is_atomic(self):
        self.rows['payments'].append(dict(self.rows['payments'][0], amount_cents=51))
        with self.assertRaisesRegex(ValueError, 'conflicting payload'):
            local.load_batch(self.db, self.write_batch())
        self.assertEqual(self.query('SELECT COUNT(*) n FROM invoices')[0]['n'], 0)
        self.assertEqual(self.query('SELECT COUNT(*) n FROM raw_suppliers')[0]['n'], 0)

    def test_historical_timestamp_conflict_rejected_after_correction(self):
        base = self.write_batch()
        local.load_batch(self.db, base)
        local.load_batch(self.db, self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=70)]}, 'correction', True))
        snapshot = local.snapshot_metrics(self.db)
        self.rows['payments'][0]['amount_cents'] = 60
        with self.assertRaisesRegex(ValueError, 'conflicting payload'):
            local.load_batch(self.db, self.write_batch(name='bad'))
        self.assertEqual(snapshot, local.snapshot_metrics(self.db))

    def test_asof_due_boundaries_and_overpayment_remain_visible(self):
        self.rows['payments'] = [dict(self.rows['payments'][0], amount_cents=400)]
        for index, due, invoice_date in [(2, '2025-03-31', '2025-03-31'), (3, '2025-03-30', '2025-03-31'), (4, '2025-03-30', '2025-04-01')]:
            self.rows['invoices'].append(dict(self.rows['invoices'][0], invoice_id=f'I{index}', invoice_number=f'NUM{index}', due_date=due, invoice_date=invoice_date, invoice_total_cents=100))
            self.rows['invoice_lines'].append(dict(self.rows['invoice_lines'][0], invoice_line_id=f'IL{index+1}', invoice_id=f'I{index}'))
        local.load_batch(self.db, self.write_batch())
        balances = {row['invoice_id']: row for row in self.query('SELECT * FROM v_invoice_balance')}
        self.assertEqual(balances['I1']['balance_cents'], -100)
        self.assertEqual(balances['I1']['is_overdue'], 0)
        self.assertEqual(balances['I2']['is_overdue'], 0)
        self.assertEqual(balances['I3']['is_overdue'], 1)
        self.assertNotIn('I4', balances)
        self.assertEqual(self.query('SELECT days_overdue FROM v_overdue_aging')[0]['days_overdue'], 1)

    def test_invalid_references_and_overlapping_invoice_flags_preserved(self):
        self.rows['invoice_lines'][0]['po_line_id'] = 'MISSING'
        self.rows['invoice_lines'][1]['po_line_id'] = ''
        self.rows['invoices'].append(dict(self.rows['invoices'][0], invoice_id='I2', invoice_number='a-1', invoice_total_cents=110))
        self.rows['invoice_lines'].append(dict(self.rows['invoice_lines'][0], invoice_line_id='IL3', invoice_id='I2', po_line_id='PL1', unit_price_cents=110))
        self.rows['purchase_orders'][0]['supplier_id'] = 'S2'
        local.load_batch(self.db, self.write_batch())
        rows = {row['invoice_line_id']: row for row in self.query('SELECT * FROM fact_invoice')}
        self.assertEqual(rows['IL1']['invalid_po_reference'], 1)
        self.assertEqual(rows['IL1']['header_total_mismatch'], 1)
        self.assertEqual(rows['IL2']['no_po'], 1)
        self.assertEqual(rows['IL3']['supplier_mismatch'], 1)
        self.assertEqual(rows['IL3']['price_mismatch'], 1)
        self.assertTrue(all(row['duplicate_invoice_number'] == 1 for row in rows.values()))
        self.assertEqual(self.query('SELECT unmatched_spend_cents FROM v_unmatched_spend')[0]['unmatched_spend_cents'], 300)
        self.assertEqual(self.query('SELECT exception_invoice_count FROM v_supplier_spend')[0]['exception_invoice_count'], 2)

    def test_integer_date_parent_line_number_and_temporal_validation(self):
        cases = [('payments', 'amount_cents', '1.25', 'integer'),
                 ('payments', 'amount_cents', '-1', 'integer'),
                 ('invoices', 'due_date', '2025-02-30', 'invalid due_date'),
                 ('invoices', 'due_date', '2026-01-01', 'invalid due_date'),
                 ('payments', 'invoice_id', 'ABSENT', 'missing invoices'),
                 ('suppliers', 'effective_from', '2025-02-01', 'no supplier version')]
        for table, column, value, message in cases:
            with self.subTest(column=column, value=value):
                original = self.rows[table][0][column]
                self.rows[table][0][column] = value
                with self.assertRaisesRegex(ValueError, message):
                    local.load_batch(self.db, self.write_batch(name='invalid'))
                self.rows[table][0][column] = original
        self.rows['invoice_lines'][1]['line_number'] = 1
        with self.assertRaisesRegex(ValueError, 'duplicate document line_number'):
            local.load_batch(self.db, self.write_batch(name='duplicate_line'))

    def test_scd_inserted_interval_reassigns_fact_by_document_date(self):
        local.load_batch(self.db, self.write_batch())
        correction = self.write_batch({'suppliers': [dict(self.rows['suppliers'][0], effective_from='2025-02-01', category='Middle')]}, 'correction', True)
        local.load_batch(self.db, correction)
        versions = self.query("SELECT valid_from,valid_to FROM dim_supplier WHERE supplier_id='S1' ORDER BY valid_from")
        self.assertEqual(versions, [{'valid_from': '2025-01-01', 'valid_to': '2025-02-01'},
                                    {'valid_from': '2025-02-01', 'valid_to': '2025-03-01'},
                                    {'valid_from': '2025-03-01', 'valid_to': '9999-12-31'}])
        self.assertEqual(self.query("SELECT supplier_key FROM fact_invoice WHERE invoice_line_id='IL1'")[0]['supplier_key'], 'S1|2025-02-01')
        self.assertEqual(self.query("SELECT supplier_key FROM fact_payment WHERE payment_id='P2'")[0]['supplier_key'], 'S1|2025-03-01')

    def test_report_persists_four_phases_and_replay_proof(self):
        self.write_batch()
        self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=60)]}, 'corrections', True)
        report = local.run_validation(self.root, self.root / 'artifacts')
        self.assertTrue(report['passed'])
        self.assertEqual([row['phase'] for row in report['phases']], ['base', 'base_replay', 'correction', 'correction_replay'])
        saved = json.loads((self.root / 'artifacts' / 'reconciliation.json').read_text())
        self.assertTrue(saved['passed'])
        self.assertTrue((self.root / 'artifacts' / 'local.sqlite').exists())
        self.assertIn('PASS', (self.root / 'artifacts' / 'reconciliation.md').read_text())

    def test_unseen_stale_correction_rejected_but_known_correction_replay_allowed(self):
        local.load_batch(self.db, self.write_batch())
        first = self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=60)]}, 'first', True)
        local.load_batch(self.db, first)
        later = self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=80)]}, 'later', True)
        file = later / 'payments.csv'
        file.write_text(file.read_text().replace('2025-03-15T00:00:00', '2025-03-20T00:00:00'))
        local.load_batch(self.db, later)
        before = local.snapshot_metrics(self.db)
        self.assertEqual(local.load_batch(self.db, first)['applied_rows'], 0)
        self.assertEqual(before, local.snapshot_metrics(self.db))
        stale = self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=70)]}, 'stale', True)
        file = stale / 'payments.csv'
        file.write_text(file.read_text().replace('2025-03-15T00:00:00', '2025-03-18T00:00:00'))
        with self.assertRaisesRegex(ValueError, 'previously unseen stale correction'):
            local.load_batch(self.db, stale)
        self.assertEqual(before, local.snapshot_metrics(self.db))

    def test_zero_invoice_without_payment_is_settled_on_invoice_date(self):
        self.rows['invoice_lines'][0]['quantity'] = 0
        self.rows['invoice_lines'][1]['quantity'] = 0
        self.rows['invoices'][0]['invoice_total_cents'] = 0
        self.rows['payments'] = []
        local.load_batch(self.db, self.write_batch())
        row = self.query('SELECT * FROM v_payment_performance')[0]
        self.assertEqual(row['balance_cents'], 0)
        self.assertEqual(row['paid_in_full_date'], '2025-02-01')
        self.assertEqual(row['days_late'], -27)
        self.assertEqual(row['is_overdue'], 0)

    def test_report_fails_and_persists_wrong_generator_correction_expectation(self):
        self.write_batch()
        self.write_batch({'payments': [dict(self.rows['payments'][0], amount_cents=60)]}, 'corrections', True)
        summaries = {}
        for table, metrics in local.expected_source_metrics({table: {index: row for index, row in enumerate(rows)} for table, rows in self.rows.items()}).items():
            summaries[table + '.csv'] = {'row_count': metrics['count'], 'monetary_sums': {'cents': metrics['cents']}}
        corrected = json.loads(json.dumps(summaries))
        corrected['payments.csv']['monetary_sums']['cents'] += 10
        expectations = {'batches': {'BASE': summaries, 'MERGED': corrected}, 'fixtures': {},
                        'corrections': {'row_changes': [{'file': 'payments.csv', 'natural_key': {'payment_id': 'P1'},
                                                       'field': 'amount_cents', 'before': 50, 'after': 999}]}}
        (self.root / 'expected.json').write_text(json.dumps(expectations))
        report = local.run_validation(self.root, self.root / 'artifacts')
        self.assertFalse(report['passed'])
        failed = [row for row in report['checks'] if not row['passed']]
        self.assertEqual(len(failed), 2)
        self.assertTrue(all('correction_field:payments' in row['name'] for row in failed))
        self.assertIn('FAIL', (self.root / 'artifacts' / 'reconciliation.md').read_text())


if __name__ == '__main__':
    unittest.main()
