"""Generate fictional, reproducible purchase-to-pay source batches (stdlib only)."""

import argparse
import csv
import json
import random
from datetime import date, timedelta
from pathlib import Path


REPORTING_DATE = "2025-03-31"
BASE_TIMESTAMP = "2025-03-01T00:00:00"
CORRECTION_TIMESTAMP = "2025-03-15T00:00:00"
SCHEMAS = {
    "suppliers.csv": (
        "supplier_id", "supplier_name", "category", "country",
        "payment_terms_days", "effective_from",
    ),
    "purchase_orders.csv": ("po_id", "supplier_id", "order_date", "status"),
    "po_lines.csv": (
        "po_line_id", "po_id", "line_number", "description", "quantity",
        "unit_price_cents",
    ),
    "invoices.csv": (
        "invoice_id", "supplier_id", "invoice_date", "due_date",
        "invoice_number", "invoice_total_cents",
    ),
    "invoice_lines.csv": (
        "invoice_line_id", "invoice_id", "line_number", "po_line_id",
        "description", "quantity", "unit_price_cents",
    ),
    "payments.csv": ("payment_id", "invoice_id", "payment_date", "amount_cents"),
}
NATURAL_KEYS = {
    "suppliers.csv": ("supplier_id", "effective_from"),
    "purchase_orders.csv": ("po_id",),
    "po_lines.csv": ("po_line_id",),
    "invoices.csv": ("invoice_id",),
    "invoice_lines.csv": ("invoice_line_id",),
    "payments.csv": ("payment_id",),
}


def _row(filename, values, batch="BASE"):
    result = dict(zip(SCHEMAS[filename], values))
    if len(values) != len(SCHEMAS[filename]):
        raise ValueError("Incorrect column count for " + filename)
    result["source_updated_at"] = (
        BASE_TIMESTAMP if batch == "BASE" else CORRECTION_TIMESTAMP
    )
    result["batch_id"] = batch
    return result


def _line_amount(row):
    return row["quantity"] * row["unit_price_cents"]


def _summaries(tables):
    summaries = {}
    for filename, rows in tables.items():
        sums = {}
        if filename in ("po_lines.csv", "invoice_lines.csv"):
            sums["extended_amount_cents"] = sum(_line_amount(row) for row in rows)
        elif filename == "invoices.csv":
            sums["invoice_total_cents"] = sum(row["invoice_total_cents"] for row in rows)
        elif filename == "payments.csv":
            sums["amount_cents"] = sum(row["amount_cents"] for row in rows)
        summaries[filename] = {"row_count": len(rows), "monetary_sums": sums}
    return summaries


def _merge(base, corrections):
    merged = {}
    for filename in SCHEMAS:
        keys = NATURAL_KEYS[filename]
        latest = {tuple(row[key] for key in keys): row for row in base[filename]}
        for row in corrections[filename]:
            latest[tuple(row[key] for key in keys)] = row
        merged[filename] = list(latest.values())
    return merged


def _invoice_state(tables, invoice_id):
    header = next(row for row in tables["invoices.csv"] if row["invoice_id"] == invoice_id)
    lines = [row for row in tables["invoice_lines.csv"] if row["invoice_id"] == invoice_id]
    payments = [row for row in tables["payments.csv"] if row["invoice_id"] == invoice_id]
    line_total = sum(_line_amount(row) for row in lines)
    paid = sum(row["amount_cents"] for row in payments if row["payment_date"] <= REPORTING_DATE)
    cumulative = 0
    paid_in_full_date = header["invoice_date"] if line_total == 0 else None
    for payment in sorted(payments, key=lambda row: (row["payment_date"], row["payment_id"])):
        if payment["payment_date"] > REPORTING_DATE:
            continue
        cumulative += payment["amount_cents"]
        if cumulative >= line_total and paid_in_full_date is None:
            paid_in_full_date = payment["payment_date"]
    balance = line_total - paid
    return {
        "invoice_id": invoice_id,
        "invoice_line_ids": [row["invoice_line_id"] for row in lines],
        "payment_ids": [row["payment_id"] for row in payments],
        "line_amount_cents": line_total,
        "header_total_cents": header["invoice_total_cents"],
        "paid_to_date_cents": paid,
        "future_payment_cents": sum(row["amount_cents"] for row in payments if row["payment_date"] > REPORTING_DATE),
        "balance_cents": balance,
        "overdue": header["due_date"] < REPORTING_DATE and balance > 0,
        "paid_in_full_date": paid_in_full_date,
        "days_late": (date.fromisoformat(paid_in_full_date) - date.fromisoformat(header["due_date"])).days if paid_in_full_date else None,
    }


def _validate(tables):
    """Fail before writing if generated source rows violate the contract."""
    for filename, rows in tables.items():
        keys = NATURAL_KEYS[filename]
        seen = set()
        for row in rows:
            key = tuple(row[column] for column in keys)
            if key in seen:
                raise ValueError("Duplicate natural key: " + str(key))
            seen.add(key)
            for column, value in row.items():
                if column.endswith("_date") or column == "effective_from":
                    if date.fromisoformat(value).year != 2025:
                        raise ValueError("Date outside 2025: " + value)
                if column in ("quantity", "unit_price_cents", "amount_cents", "invoice_total_cents"):
                    if not isinstance(value, int) or value < 0:
                        raise ValueError("Invalid nonnegative integer: " + column)
    suppliers = {row["supplier_id"] for row in tables["suppliers.csv"]}
    pos = {row["po_id"] for row in tables["purchase_orders.csv"]}
    invoices = {row["invoice_id"] for row in tables["invoices.csv"]}
    for filename in ("purchase_orders.csv", "invoices.csv"):
        if any(row["supplier_id"] not in suppliers for row in tables[filename]):
            raise ValueError("Missing supplier")
    for filename, parent, parents in (
        ("po_lines.csv", "po_id", pos),
        ("invoice_lines.csv", "invoice_id", invoices),
    ):
        seen = set()
        for row in tables[filename]:
            key = (row[parent], row["line_number"])
            if row[parent] not in parents or key in seen:
                raise ValueError("Invalid line parent or duplicate line number")
            seen.add(key)
        if {row[parent] for row in tables[filename]} != parents:
            raise ValueError("Document without lines")
    if any(row["invoice_id"] not in invoices for row in tables["payments.csv"]):
        raise ValueError("Missing payment invoice")


def build_dataset(seed=42):
    """Return (base tables, partial correction tables, expected metadata)."""
    rng = random.Random(seed)
    base = {filename: [] for filename in SCHEMAS}
    corrections = {filename: [] for filename in SCHEMAS}

    def add(filename, *values):
        row = _row(filename, values)
        base[filename].append(row)
        return row

    categories = ("OFFICE", "TECHNOLOGY", "FACILITIES", "PROFESSIONAL SERVICES")
    for index in range(1, 25):
        add("suppliers.csv", "SUP_%03d" % index, "  Fictional Supplier %02d  " % index,
            categories[(index - 1) % len(categories)], "US", 30, "2025-01-01")
    add("suppliers.csv", "SUP_FIX_VERSION", "  Fictional Versioned Supplier  ",
        "FACILITIES", "US", 30, "2025-01-01")
    add("suppliers.csv", "SUP_FIX_VERSION", "fictional versioned supplier",
        "OFFICE", "US", 20, "2025-02-01")

    for tag, supplier, quantity, price in (
        ("MAIN", "SUP_001", 100, 5000),
        ("OTHER", "SUP_002", 100, 5000),
        ("VERSION", "SUP_FIX_VERSION", 100, 10000),
    ):
        add("purchase_orders.csv", "PO_FIX_" + tag, supplier, "2025-01-01", "OPEN")
        add("po_lines.csv", "POL_FIX_" + tag, "PO_FIX_" + tag, 1,
            "Fictional fixture purchase " + tag, quantity, price)

    fixtures = {}

    def fixture(name, tag, lines, payments=(), flags=(), supplier="SUP_001",
                invoice_date="2025-01-10", due_date="2025-02-09", number=None,
                header_adjustment=0):
        invoice_id = "INV_FIX_" + tag
        add("invoices.csv", invoice_id, supplier, invoice_date, due_date,
            number if number is not None else "FIX-" + tag,
            sum(quantity * price for _, quantity, price in lines) + header_adjustment)
        for index, (reference, quantity, price) in enumerate(lines, 1):
            add("invoice_lines.csv", "LINE_FIX_%s_%d" % (tag, index), invoice_id,
                index, reference, "Fictional fixture line", quantity, price)
        for payment_id, payment_date, amount in payments:
            add("payments.csv", payment_id, invoice_id, payment_date, amount)
        fixtures[name] = {
            "invoice_id": invoice_id, "supplier_id": supplier,
            "expected_flags": list(flags),
        }

    fixture("no_po", "NO_PO", [("", 2, 2500)], flags=("NO_PO",))
    fixture("invalid_po", "INVALID_PO", [("POL_DOES_NOT_EXIST", 1, 7000)],
            flags=("INVALID_PO_REFERENCE",))
    fixture("supplier_mismatch", "SUPPLIER_MISMATCH", [("POL_FIX_OTHER", 1, 5000)],
            flags=("SUPPLIER_MISMATCH",))
    fixture("price_mismatch", "PRICE_MISMATCH", [("POL_FIX_MAIN", 1, 5500)],
            flags=("PRICE_MISMATCH",))
    fixture("header_mismatch", "HEADER_MISMATCH", [("POL_FIX_MAIN", 1, 5000), ("POL_FIX_MAIN", 2, 5000)],
            flags=("HEADER_TOTAL_MISMATCH",), header_adjustment=100)
    fixture("duplicate_a", "DUPLICATE_A", [("POL_FIX_MAIN", 1, 5000)],
            number="  duP-2025-001  ", flags=("DUPLICATE_INVOICE_NUMBER",))
    fixture("duplicate_b", "DUPLICATE_B", [("POL_FIX_MAIN", 2, 5000)],
            number="DUP-2025-001", flags=("DUPLICATE_INVOICE_NUMBER",))
    fixture("unpaid_overdue", "UNPAID_OVERDUE", [("POL_FIX_MAIN", 1, 5000), ("POL_FIX_MAIN", 1, 5000)])
    fixture("partial", "PARTIAL", [("POL_FIX_MAIN", 2, 5000), ("POL_FIX_MAIN", 1, 5000)],
            payments=(("PAY_FIX_PARTIAL", "2025-02-01", 4000), ("PAY_FIX_PARTIAL_2", "2025-02-10", 2000)))
    fixture("future", "FUTURE", [("POL_FIX_MAIN", 2, 5000)],
            payments=(("PAY_FIX_FUTURE", "2025-04-10", 10000),))
    fixture("overpayment", "OVERPAYMENT", [("POL_FIX_MAIN", 2, 5000)],
            payments=(("PAY_FIX_OVERPAYMENT_1", "2025-01-20", 6000), ("PAY_FIX_OVERPAYMENT_2", "2025-02-01", 6500)))
    fixture("clean", "CLEAN", [("POL_FIX_MAIN", 1, 5000), ("POL_FIX_MAIN", 2, 5000)],
            payments=(("PAY_FIX_CLEAN_1", "2025-01-20", 5000), ("PAY_FIX_CLEAN_2", "2025-02-01", 10000)))
    fixture("correction", "CORRECTION", [("POL_FIX_VERSION", 1, 10000), ("POL_FIX_VERSION", 1, 10000)],
            supplier="SUP_FIX_VERSION", invoice_date="2025-02-10", due_date="2025-03-02")
    fixture("version_before", "VERSION_BEFORE", [("POL_FIX_VERSION", 1, 10000)],
            supplier="SUP_FIX_VERSION", invoice_date="2025-01-20", due_date="2025-02-19")
    fixture("overlapping_flags", "OVERLAP", [("POL_FIX_OTHER", 1, 5500), ("", 1, 2500)],
            flags=("SUPPLIER_MISMATCH", "PRICE_MISMATCH", "NO_PO", "HEADER_TOTAL_MISMATCH"), header_adjustment=200)
    fixture("paid_late", "PAID_LATE", [("POL_FIX_MAIN", 1, 5000)],
            payments=(("PAY_FIX_LATE", "2025-02-15", 5000),))
    fixture("due_on_report_date", "DUE_TODAY", [("POL_FIX_MAIN", 1, 5000)], due_date=REPORTING_DATE)
    fixture("zero_amount", "ZERO", [("POL_FIX_MAIN", 0, 5000)])

    # Isolated random IDs cannot alter fixture duplicate groups or allocations.
    for index in range(1, 121):
        supplier = "SUP_%03d" % rng.randint(1, 24)
        po_id = "PO_RND_%04d" % index
        invoice_id = "INV_RND_%04d" % index
        ordered_on = date(2025, 1, 1) + timedelta(days=rng.randrange(65))
        invoiced_on = ordered_on + timedelta(days=rng.randrange(1, 12))
        due_on = invoiced_on + timedelta(days=30)
        add("purchase_orders.csv", po_id, supplier, ordered_on.isoformat(), "OPEN")
        total = 0
        for line_number in range(1, rng.randint(2, 4) + 1):
            po_line_id = "POL_RND_%04d_%d" % (index, line_number)
            quantity = rng.randint(1, 12)
            price = rng.randint(100, 15000)
            add("po_lines.csv", po_line_id, po_id, line_number,
                "Fictional random purchase", quantity + rng.randint(0, 5), price)
            reference = "" if rng.random() < 0.08 else po_line_id
            invoice_price = price + 100 if rng.random() < 0.08 else price
            add("invoice_lines.csv", "LINE_RND_%04d_%d" % (index, line_number),
                invoice_id, line_number, reference, "Fictional random invoice line",
                quantity, invoice_price)
            total += quantity * invoice_price
        add("invoices.csv", invoice_id, supplier, invoiced_on.isoformat(), due_on.isoformat(),
            "RND-%04d" % index, total)
        payment_mode = rng.randrange(5)
        if payment_mode:
            payment_date = due_on + timedelta(days=rng.randint(-15, 20))
            if payment_mode == 1:
                amounts = (total // 3,)
            elif payment_mode == 2:
                amounts = (total // 2, total - total // 2)
            elif payment_mode == 3:
                amounts = (total + 500,)
            else:
                amounts = (total,)
            for allocation, amount in enumerate(amounts, 1):
                add("payments.csv", "PAY_RND_%04d_%d" % (index, allocation),
                    invoice_id, (payment_date + timedelta(days=allocation - 1)).isoformat(), amount)

    changes = (
        ("payments.csv", "payment_id", "PAY_FIX_PARTIAL", "amount_cents", 5000),
        ("invoice_lines.csv", "invoice_line_id", "LINE_FIX_CORRECTION_1", "unit_price_cents", 12000),
        ("invoices.csv", "invoice_id", "INV_FIX_CORRECTION", "invoice_total_cents", 22000),
        ("suppliers.csv", "supplier_id", "SUP_FIX_VERSION", "category", "TECHNOLOGY"),
    )
    row_changes = []
    for filename, key, identifier, field, new_value in changes:
        before = next(row for row in base[filename] if row[key] == identifier
                      and (filename != "suppliers.csv" or row["effective_from"] == "2025-02-01"))
        after = dict(before)
        after.update({field: new_value, "source_updated_at": CORRECTION_TIMESTAMP, "batch_id": "CORRECTION"})
        corrections[filename].append(after)
        row_changes.append({
            "file": filename,
            "natural_key": {column: before[column] for column in NATURAL_KEYS[filename]},
            "field": field, "before": before[field], "after": after[field],
            "delta": after[field] - before[field] if isinstance(new_value, int) else None,
        })
    merged = _merge(base, corrections)
    _validate(base)
    _validate(merged)
    for fixture_data in fixtures.values():
        invoice_id = fixture_data["invoice_id"]
        fixture_data["base"] = _invoice_state(base, invoice_id)
        fixture_data["corrected"] = _invoice_state(merged, invoice_id)
        fixture_data["corrected_expected_flags"] = list(fixture_data["expected_flags"])
    fixtures["correction"]["corrected_expected_flags"] = ["PRICE_MISMATCH"]
    base_summary = _summaries(base)
    merged_summary = _summaries(merged)
    monetary_deltas = {
        filename: {
            metric: value - base_summary[filename]["monetary_sums"][metric]
            for metric, value in summary["monetary_sums"].items()
        }
        for filename, summary in merged_summary.items()
    }
    expected = {
        "schema_version": 1,
        "seed": seed,
        "reporting_date": REPORTING_DATE,
        "source_timestamps": {"BASE": BASE_TIMESTAMP, "CORRECTION": CORRECTION_TIMESTAMP},
        "schemas": {filename: list(columns) + ["source_updated_at", "batch_id"] for filename, columns in SCHEMAS.items()},
        "fixtures": fixtures,
        "corrections": {
            "row_changes": row_changes,
            "monetary_deltas": monetary_deltas,
            "invoice_deltas": {
                name: {
                    metric: fixture_data["corrected"][metric] - fixture_data["base"][metric]
                    for metric in ("line_amount_cents", "header_total_cents", "paid_to_date_cents", "balance_cents")
                }
                for name, fixture_data in fixtures.items()
                if fixture_data["base"] != fixture_data["corrected"]
            },
            "supplier_version": {
                "supplier_id": "SUP_FIX_VERSION", "effective_from": "2025-02-01",
                "before_category": row_changes[-1]["before"],
                "after_category": row_changes[-1]["after"],
                "affected_fixture_invoice_ids": ["INV_FIX_CORRECTION"],
                "unaffected_fixture_invoice_ids": ["INV_FIX_VERSION_BEFORE"],
                "version_count_delta": len(merged["suppliers.csv"]) - len(base["suppliers.csv"]),
            },
        },
        "batches": {
            "BASE": base_summary,
            "CORRECTION": _summaries(corrections),
            "MERGED": merged_summary,
        },
    }
    return base, corrections, expected


def generate(output, seed=42):
    """Write six CSVs per batch and expected.json; return expected metadata."""
    base, corrections, expected = build_dataset(seed)
    output = Path(output)
    for directory, tables in (("base", base), ("corrections", corrections)):
        batch_directory = output / directory
        batch_directory.mkdir(parents=True, exist_ok=True)
        for filename, rows in tables.items():
            with (batch_directory / filename).open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=list(SCHEMAS[filename]) + ["source_updated_at", "batch_id"], lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
    (output / "expected.json").write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data"))
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    expected = generate(args.output, args.seed)
    print("Generated %d fictional invoices in %s (seed=%d)" % (
        expected["batches"]["BASE"]["invoices.csv"]["row_count"], args.output, args.seed))


if __name__ == "__main__":
    main()
