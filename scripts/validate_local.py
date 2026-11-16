"""Load the fictional P2P contract and persist local-only reconciliation evidence."""
import argparse
import csv
import datetime as dt
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import sqlite3

REPORTING_DATE = '2025-03-31'
COLUMNS = {
    'suppliers': ['supplier_id', 'supplier_name', 'category', 'country', 'payment_terms_days', 'effective_from'],
    'purchase_orders': ['po_id', 'supplier_id', 'order_date', 'status'],
    'po_lines': ['po_line_id', 'po_id', 'line_number', 'description', 'quantity', 'unit_price_cents'],
    'invoices': ['invoice_id', 'supplier_id', 'invoice_date', 'due_date', 'invoice_number', 'invoice_total_cents'],
    'invoice_lines': ['invoice_line_id', 'invoice_id', 'line_number', 'po_line_id', 'description', 'quantity', 'unit_price_cents'],
    'payments': ['payment_id', 'invoice_id', 'payment_date', 'amount_cents'],
}
KEYS = {name: [cols[0]] for name, cols in COLUMNS.items()}
KEYS['suppliers'] = ['supplier_id', 'effective_from']
INTEGER_COLUMNS = {'payment_terms_days', 'line_number', 'quantity', 'unit_price_cents', 'invoice_total_cents', 'amount_cents'}
DATE_COLUMNS = {'effective_from', 'order_date', 'invoice_date', 'due_date', 'payment_date'}
MAX_INTEGER = 9223372036854775807


def connect_database(path=':memory:'):
    connection = sqlite3.connect(str(path))
    connection.row_factory = sqlite3.Row
    for table, cols in COLUMNS.items():
        definitions = [f'{col} {"INTEGER" if col in INTEGER_COLUMNS else "TEXT"} NOT NULL'
                       if not (table == 'invoice_lines' and col == 'po_line_id')
                       else 'po_line_id TEXT' for col in cols]
        definitions += ['source_updated_at TEXT NOT NULL', 'batch_id TEXT NOT NULL',
                        'PRIMARY KEY (' + ','.join(KEYS[table]) + ')']
        connection.execute(f'CREATE TABLE IF NOT EXISTS {table} ({",".join(definitions)})')
        connection.execute(f'''CREATE TABLE IF NOT EXISTS raw_{table} (
            audit_id INTEGER PRIMARY KEY, natural_key TEXT NOT NULL,
            payload_json TEXT NOT NULL, source_updated_at TEXT NOT NULL,
            batch_id TEXT NOT NULL, source_file TEXT NOT NULL, source_row INTEGER NOT NULL)''')
        connection.execute(f'CREATE INDEX IF NOT EXISTS raw_{table}_key_time ON raw_{table}(natural_key, source_updated_at)')
    connection.commit()
    sql_path = Path(__file__).resolve().parents[1] / 'sql' / 'local'
    for path in sorted(sql_path.glob('*.sql')):
        connection.executescript(path.read_text(encoding='utf-8'))
    return connection


def read_batch(directory):
    result = {}
    for table, columns in COLUMNS.items():
        file = Path(directory) / (table + '.csv')
        with file.open(newline='', encoding='utf-8') as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames != columns + ['source_updated_at', 'batch_id']:
                raise ValueError(f'{file}: CSV header does not match contract')
            rows = []
            for number, raw in enumerate(reader, 2):
                if None in raw or any(value is None for value in raw.values()):
                    raise ValueError(f'{file}:{number}: malformed CSV row')
                row = dict(raw)
                for col in columns:
                    value = row[col]
                    if value == '' and table == 'invoice_lines' and col == 'po_line_id':
                        row[col] = None
                    elif col in INTEGER_COLUMNS:
                        if not re.fullmatch(r'[0-9]+', value) or int(value) > MAX_INTEGER:
                            raise ValueError(f'{file}:{number}: {col} must be nonnegative integer within SQLite range')
                        row[col] = int(value)
                    elif col in DATE_COLUMNS:
                        try:
                            parsed_date = dt.date.fromisoformat(value)
                            if parsed_date.isoformat() != value or parsed_date.year != 2025:
                                raise ValueError('noncanonical date')
                        except ValueError as error:
                            raise ValueError(f'{file}:{number}: invalid {col}') from error
                    elif not value.strip():
                        raise ValueError(f'{file}:{number}: {col} must be nonempty text')
                try:
                    timestamp = dt.datetime.strptime(row['source_updated_at'], '%Y-%m-%dT%H:%M:%S')
                    if timestamp.isoformat() != row['source_updated_at']:
                        raise ValueError('noncanonical timestamp')
                except ValueError as error:
                    raise ValueError(f'{file}:{number}: invalid source_updated_at') from error
                if row['batch_id'] not in ('BASE', 'CORRECTION'):
                    raise ValueError(f'{file}:{number}: invalid batch_id')
                if 'quantity' in row and row['quantity'] * row['unit_price_cents'] > MAX_INTEGER:
                    raise ValueError(f'{file}:{number}: extended amount exceeds integer range')
                rows.append((number, row))
            result[table] = rows
    return result


def validate_parents(connection):
    checks = [
        ('purchase_orders', 'suppliers', 'supplier_id', 'supplier_id'),
        ('invoices', 'suppliers', 'supplier_id', 'supplier_id'),
        ('po_lines', 'purchase_orders', 'po_id', 'po_id'),
        ('invoice_lines', 'invoices', 'invoice_id', 'invoice_id'),
        ('payments', 'invoices', 'invoice_id', 'invoice_id'),
    ]
    for child, parent, child_key, parent_key in checks:
        bad = connection.execute(f'''SELECT c.{child_key} FROM {child} c WHERE NOT EXISTS
            (SELECT 1 FROM {parent} p WHERE p.{parent_key} = c.{child_key}) LIMIT 1''').fetchone()
        if bad:
            raise ValueError(f'{child}: missing {parent} parent {bad[0]}')
    for header, lines, key in [('purchase_orders', 'po_lines', 'po_id'), ('invoices', 'invoice_lines', 'invoice_id')]:
        if connection.execute(f'SELECT 1 FROM {header} h WHERE NOT EXISTS (SELECT 1 FROM {lines} l WHERE l.{key}=h.{key}) LIMIT 1').fetchone():
            raise ValueError(f'{header}: document has no lines')
        if connection.execute(f'SELECT 1 FROM {lines} GROUP BY {key},line_number HAVING COUNT(*) > 1 LIMIT 1').fetchone():
            raise ValueError(f'{lines}: duplicate document line_number')
    for fact in ['fact_purchasing', 'fact_invoice', 'fact_payment']:
        if connection.execute(f'SELECT 1 FROM {fact} WHERE supplier_key IS NULL LIMIT 1').fetchone():
            raise ValueError(f'{fact}: no supplier version effective on fact date')


def load_batch(connection, directory):
    batch = read_batch(directory)
    applied = 0
    with connection:
        for table, rows in batch.items():
            columns = COLUMNS[table] + ['source_updated_at', 'batch_id']
            where = ' AND '.join(f'{key}=?' for key in KEYS[table])
            for number, row in rows:
                key_values = [row[key] for key in KEYS[table]]
                natural_key = json.dumps(key_values, separators=(',', ':'))
                payload = json.dumps({col: row[col] for col in COLUMNS[table]}, sort_keys=True, separators=(',', ':'))
                conflicts = connection.execute(f'''SELECT 1 FROM raw_{table} WHERE natural_key=?
                    AND source_updated_at=? AND payload_json<>? LIMIT 1''',
                    (natural_key, row['source_updated_at'], payload)).fetchone()
                if conflicts:
                    raise ValueError(f'{table}: conflicting payload at same timestamp for {natural_key}')
                old = connection.execute(f'SELECT * FROM {table} WHERE {where}', key_values).fetchone()
                if old is not None and row['batch_id'] == 'CORRECTION' and row['source_updated_at'] < old['source_updated_at']:
                    seen = connection.execute(f'''SELECT 1 FROM raw_{table} WHERE natural_key=?
                        AND source_updated_at=? AND payload_json=? LIMIT 1''',
                        (natural_key, row['source_updated_at'], payload)).fetchone()
                    if seen is None:
                        raise ValueError(f'{table}: previously unseen stale correction for {natural_key}')
                if old is not None and old['source_updated_at'] == row['source_updated_at']:
                    if any(old[col] != row[col] for col in COLUMNS[table]):
                        raise ValueError(f'{table}: conflicting payload at same timestamp for {natural_key}')
                if old is None or old['source_updated_at'] < row['source_updated_at']:
                    placeholders = ','.join('?' for _ in columns)
                    updates = ','.join(f'{col}=excluded.{col}' for col in columns if col not in KEYS[table])
                    connection.execute(f'''INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders})
                        ON CONFLICT ({','.join(KEYS[table])}) DO UPDATE SET {updates}''', [row[col] for col in columns])
                    applied += 1
                connection.execute(f'''INSERT INTO raw_{table}
                    (natural_key,payload_json,source_updated_at,batch_id,source_file,source_row) VALUES (?,?,?,?,?,?)''',
                    (natural_key, payload, row['source_updated_at'], row['batch_id'], str(Path(directory) / (table + '.csv')), number))
        validate_parents(connection)
    return {'input_rows': sum(len(rows) for rows in batch.values()), 'applied_rows': applied,
            'raw_rows': {table: connection.execute(f'SELECT COUNT(*) FROM raw_{table}').fetchone()[0] for table in COLUMNS}}


def records(connection, query):
    return [dict(row) for row in connection.execute(query)]


def snapshot_metrics(connection):
    source = {}
    for table in COLUMNS:
        rows = records(connection, f'SELECT * FROM {table} ORDER BY {",".join(KEYS[table])}')
        cents = 0
        if table in ('po_lines', 'invoice_lines'):
            cents = sum(row['quantity'] * row['unit_price_cents'] for row in rows)
        elif table == 'invoices':
            cents = sum(row['invoice_total_cents'] for row in rows)
        elif table == 'payments':
            cents = sum(row['amount_cents'] for row in rows)
        source[table] = {'count': len(rows), 'cents': cents,
                         'sha256': hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()}
    facts = {}
    for table, amount in [('fact_purchasing', 'ordered_amount_cents'), ('fact_invoice', 'invoiced_amount_cents'), ('fact_payment', 'amount_cents')]:
        rows = records(connection, f'SELECT * FROM {table} ORDER BY 1')
        facts[table] = {'count': len(rows), 'cents': sum(row[amount] for row in rows),
                        'sha256': hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()}
    return {'source': source, 'facts': facts,
            'balances': records(connection, 'SELECT * FROM v_invoice_balance ORDER BY invoice_id'),
            'supplier_versions': records(connection, 'SELECT * FROM dim_supplier ORDER BY supplier_id,valid_from'),
            'supplier_spend': records(connection, 'SELECT * FROM v_supplier_spend ORDER BY supplier_id'),
            'concentration': records(connection, 'SELECT * FROM v_supplier_concentration'),
            'unmatched_spend': records(connection, 'SELECT * FROM v_unmatched_spend'),
            'payment_performance': records(connection, 'SELECT * FROM v_payment_performance ORDER BY invoice_id'),
            'overdue_aging': records(connection, 'SELECT * FROM v_overdue_aging ORDER BY invoice_id'),
            'exceptions': records(connection, '''SELECT invoice_id, MAX(header_total_mismatch) AS header_total_mismatch,
               MAX(duplicate_invoice_number) AS duplicate_invoice_number, MAX(no_po) AS no_po,
               MAX(invalid_po_reference) AS invalid_po_reference, MAX(supplier_mismatch) AS supplier_mismatch,
               MAX(price_mismatch) AS price_mismatch FROM fact_invoice GROUP BY invoice_id ORDER BY invoice_id''')}


def expected_source_metrics(latest):
    result = {}
    for table, keyed in latest.items():
        rows = list(keyed.values())
        if table in ('po_lines', 'invoice_lines'):
            cents = sum(row['quantity'] * row['unit_price_cents'] for row in rows)
        elif table == 'invoices':
            cents = sum(row['invoice_total_cents'] for row in rows)
        elif table == 'payments':
            cents = sum(row['amount_cents'] for row in rows)
        else:
            cents = 0
        result[table] = {'count': len(rows), 'cents': cents}
    return result


def check_generator_expectations(connection, snapshot, expected, phase, check):
    label = 'base' if phase.startswith('base') else 'corrected'
    batch_label = 'BASE' if label == 'base' else 'MERGED'
    for filename, metrics in expected['batches'][batch_label].items():
        actual = snapshot['source'][filename.removesuffix('.csv')]
        expected_cents = sum(metrics['monetary_sums'].values())
        check(phase + ':expected:' + filename,
              actual['count'] == metrics['row_count'] and actual['cents'] == expected_cents,
              {'expected': metrics, 'actual': actual})
    balances = {row['invoice_id']: row for row in snapshot['payment_performance']}
    exceptions = {row['invoice_id']: row for row in snapshot['exceptions']}
    metric_names = {'line_amount_cents': 'line_total_cents', 'header_total_cents': 'invoice_total_cents',
                    'paid_to_date_cents': 'paid_to_date_cents', 'balance_cents': 'balance_cents',
                    'overdue': 'is_overdue', 'paid_in_full_date': 'paid_in_full_date', 'days_late': 'days_late'}
    for name, fixture in expected['fixtures'].items():
        invoice_id = fixture['invoice_id']
        actual = balances[invoice_id]
        wanted = fixture[label]
        observed = {metric: actual[column] for metric, column in metric_names.items()}
        observed['future_payment_cents'] = connection.execute(
            "SELECT COALESCE(SUM(amount_cents),0) FROM payments WHERE invoice_id=? AND payment_date > ?",
            (invoice_id, REPORTING_DATE)).fetchone()[0]
        check(phase + ':fixture:' + name, all(value == wanted[metric] for metric, value in observed.items()),
              {'expected': wanted, 'actual': observed})
        flags = sorted(key.upper() for key, value in exceptions[invoice_id].items() if key != 'invoice_id' and value)
        wanted_flags = sorted(fixture['expected_flags' if label == 'base' else 'corrected_expected_flags'])
        check(phase + ':fixture_flags:' + name, flags == wanted_flags, {'expected': wanted_flags, 'actual': flags})
    for change in expected['corrections']['row_changes']:
        table = change['file'].removesuffix('.csv')
        key = change['natural_key']
        if table not in COLUMNS or change['field'] not in COLUMNS[table] or set(key) != set(KEYS[table]):
            raise ValueError('expected.json correction references unknown table, field or key')
        row = connection.execute(f'SELECT {change["field"]} FROM {table} WHERE ' +
                                 ' AND '.join(f'{col}=?' for col in key), list(key.values())).fetchone()
        value = row[0] if row else None
        wanted = change['before' if label == 'base' else 'after']
        check(phase + ':correction_field:' + table + ':' + json.dumps(key, sort_keys=True), value == wanted,
              {'field': change['field'], 'expected': wanted, 'actual': value})


def run_validation(data, output):
    data, output = Path(data), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    database = output / 'local.sqlite'
    if database.exists():
        raise ValueError(f'{database} already exists; choose a fresh output directory to retain previous evidence')
    connection = connect_database(database)
    report = {'execution_engine': 'Python sqlite3; local evidence, not Snowflake execution',
              'reporting_date': REPORTING_DATE, 'database': str(database), 'phases': [], 'checks': []}
    latest = {table: {} for table in COLUMNS}
    snapshots = {}
    def check(name, passed, evidence):
        report['checks'].append({'name': name, 'passed': bool(passed), 'evidence': evidence})
    try:
        expected_file = data / 'expected.json'
        if expected_file.exists():
            report['generator_expectations'] = json.loads(expected_file.read_text(encoding='utf-8'))
        for name, folder in [('base', 'base'), ('base_replay', 'base'), ('correction', 'corrections'), ('correction_replay', 'corrections')]:
            batch = read_batch(data / folder)
            for table, rows in batch.items():
                for _, row in rows:
                    key = tuple(row[col] for col in KEYS[table])
                    old = latest[table].get(key)
                    if old is None or row['source_updated_at'] > old['source_updated_at']:
                        latest[table][key] = row
            load = load_batch(connection, data / folder)
            snapshot = snapshot_metrics(connection)
            snapshots[name] = snapshot
            report['phases'].append({'phase': name, 'load': load, 'snapshot': snapshot})
            if 'generator_expectations' in report:
                check_generator_expectations(connection, snapshot, report['generator_expectations'], name, check)
            expected = expected_source_metrics(latest)
            for table, metrics in expected.items():
                actual = {key: snapshot['source'][table][key] for key in ('count', 'cents')}
                check(name + ':source:' + table, actual == metrics, {'expected': metrics, 'actual': actual})
            for source, target in [('po_lines', 'fact_purchasing'), ('invoice_lines', 'fact_invoice'), ('payments', 'fact_payment')]:
                actual = {key: snapshot['facts'][target][key] for key in ('count', 'cents')}
                check(name + ':mart:' + target, actual == expected[source], {'expected': expected[source], 'actual': actual})
            balances = {row['invoice_id']: row for row in snapshot['balances']}
            flags = {row['invoice_id']: row for row in snapshot['exceptions']}
            check(name + ':header_mismatches_classified', all(flags[key]['header_total_mismatch'] == int(value['header_difference_cents'] != 0)
                  for key, value in balances.items()), {'mismatched_invoice_ids': [key for key, value in balances.items() if value['header_difference_cents'] != 0]})
            if name.endswith('replay'):
                prior = 'base' if name == 'base_replay' else 'correction'
                check(name + ':idempotent', snapshot == snapshots[prior] and load['applied_rows'] == 0,
                      {'same_snapshot': snapshot == snapshots[prior], 'applied_rows': load['applied_rows'], 'raw_audit_appended': load['input_rows']})
        report['correction_changes'] = {table: {'base': snapshots['base']['source'][table], 'corrected': snapshots['correction']['source'][table]}
                                        for table in COLUMNS if snapshots['base']['source'][table] != snapshots['correction']['source'][table]}
        check('correction:changes_present', bool(report['correction_changes']), list(report['correction_changes']))
        report['passed'] = all(item['passed'] for item in report['checks'])
    except (ValueError, KeyError, TypeError, sqlite3.Error, OSError) as error:
        report['passed'] = False
        report['error'] = str(error)
    finally:
        connection.close()
    (output / 'reconciliation.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    text = ['# Local reconciliation', '', report['execution_engine'], '', 'Reporting date: ' + REPORTING_DATE,
            'Result: ' + ('PASS' if report['passed'] else 'FAIL'), '', '| Check | Result |', '| --- | --- |']
    text.extend('| ' + item['name'] + ' | ' + ('PASS' if item['passed'] else 'FAIL') + ' |' for item in report['checks'])
    text.extend(['', '## Snapshot totals', '', '| Phase | Source | Rows | USD cents | USD |', '| --- | --- | ---: | ---: | ---: |'])
    for phase in report['phases']:
        for table, metrics in phase['snapshot']['source'].items():
            text.append(f'| {phase["phase"]} | {table} | {metrics["count"]} | {metrics["cents"]} | {Decimal(metrics["cents"]) / Decimal(100):.2f} |')
    text.extend(['', 'Raw audit rows append on every replay; source and mart snapshots remain unchanged.',
                 'Header differences are classified exceptions, not a requirement for header/line equality.',
                 'Full snapshots, flags, correction changes and supplied generator expectations are in reconciliation.json.'])
    if 'error' in report:
        text.extend(['', 'Error: ' + report['error']])
    (output / 'reconciliation.md').write_text('\n'.join(text) + '\n', encoding='utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, default=Path('data'))
    parser.add_argument('--output', type=Path, default=Path('artifacts'))
    args = parser.parse_args()
    try:
        report = run_validation(args.data, args.output)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps({'passed': report['passed'], 'report': str(args.output / 'reconciliation.json')}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
