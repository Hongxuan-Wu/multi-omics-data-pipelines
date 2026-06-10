#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Any

try:
    import pyarrow as pa
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
except ImportError as exc:
    raise SystemExit(
        "validate_schema.py requires pyarrow. Install projects/sra_xml_snapshot_index/requirements.txt first."
    ) from exc


TYPE_MAP = {
    "string": pa.string(),
    "int64": pa.int64(),
    "bool": pa.bool_(),
    "double": pa.float64(),
    "timestamp": pa.timestamp("us"),
}


def load_contract(path: Path) -> dict[str, Any]:
    contract = json.loads(path.read_text(encoding="utf-8"))
    tables = contract.get("tables")
    if not isinstance(tables, dict) or not tables:
        raise ValueError(f"schema contract has no tables: {path}")
    return contract


def resolve_table(contract: dict[str, Any], table_name: str) -> dict[str, Any]:
    table = dict(contract["tables"][table_name])
    if "like" in table:
        base = resolve_table(contract, table["like"])
        table["fields"] = base["fields"]
    return table


def expected_arrow_schema(contract: dict[str, Any], table_name: str) -> pa.Schema:
    table = resolve_table(contract, table_name)
    fields = []
    for spec in table["fields"]:
        if spec["type"] not in TYPE_MAP:
            raise ValueError(f"unsupported type for {table_name}.{spec['name']}: {spec['type']}")
        fields.append(pa.field(spec["name"], TYPE_MAP[spec["type"]], nullable=bool(spec.get("nullable", True))))
    return pa.schema(fields)


def normalized_type(data_type: pa.DataType) -> str:
    if pa.types.is_timestamp(data_type):
        return "timestamp"
    if pa.types.is_string(data_type):
        return "string"
    if pa.types.is_int64(data_type):
        return "int64"
    if pa.types.is_boolean(data_type):
        return "bool"
    if pa.types.is_float64(data_type):
        return "double"
    return str(data_type)


def validate_one_table(contract: dict[str, Any], output_root: Path, table_name: str, check_values: bool) -> list[str]:
    errors: list[str] = []
    table = resolve_table(contract, table_name)
    path = output_root / table["path"]
    if table.get("required", True) and not path.exists():
        return [f"{table_name}: missing required parquet {path}"]
    if not path.exists():
        return []

    actual_schema = pq.read_schema(path)
    actual_by_name = {field.name: field for field in actual_schema}
    expected_names = {field["name"] for field in table["fields"]}

    for spec in table["fields"]:
        field = actual_by_name.get(spec["name"])
        if field is None:
            errors.append(f"{table_name}: missing column {spec['name']}")
            continue
        actual_type = normalized_type(field.type)
        if actual_type != spec["type"]:
            errors.append(f"{table_name}.{spec['name']}: type {actual_type} != {spec['type']}")
        expected_nullable = bool(spec.get("nullable", True))
        if field.nullable != expected_nullable:
            errors.append(f"{table_name}.{spec['name']}: nullable {field.nullable} != {expected_nullable}")

    extra = sorted(set(actual_schema.names) - expected_names)
    if extra:
        errors.append(f"{table_name}: unexpected columns {extra}")

    if check_values:
        arrow_table = pq.read_table(path)
        for spec in table["fields"]:
            enum_values = spec.get("enum")
            if not enum_values or spec["name"] not in arrow_table.column_names or arrow_table.num_rows == 0:
                continue
            values = pc.unique(arrow_table[spec["name"]]).to_pylist()
            bad = sorted({value for value in values if value is not None and value not in enum_values})
            if bad:
                errors.append(f"{table_name}.{spec['name']}: enum violations {bad}")
    return errors


def validate_output_root(contract_path: Path, output_root: Path, check_values: bool) -> list[str]:
    contract = load_contract(contract_path)
    errors: list[str] = []
    for table_name in sorted(contract["tables"]):
        errors.extend(validate_one_table(contract, output_root, table_name, check_values))
    return errors


def write_empty_fixture(contract_path: Path, output_root: Path) -> None:
    contract = load_contract(contract_path)
    for table_name in sorted(contract["tables"]):
        table = resolve_table(contract, table_name)
        schema = expected_arrow_schema(contract, table_name)
        path = output_root / table["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        arrays = [pa.array([], type=field.type) for field in schema]
        pq.write_table(pa.Table.from_arrays(arrays, schema=schema), path)
    (output_root / "failed_chunks.tsv").write_text(
        "chunk_id\tstart_row\trow_count\texit_code\terror_type\tlog_path\tretry_count\n",
        encoding="utf-8",
    )


def self_test(contract_path: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        ok_root = tmp / "ok"
        write_empty_fixture(contract_path, ok_root)
        ok_errors = validate_output_root(contract_path, ok_root, check_values=True)
        if ok_errors:
            raise AssertionError(f"empty fixture should pass: {ok_errors}")

        bad_root = tmp / "bad"
        write_empty_fixture(contract_path, bad_root)
        (bad_root / "file_index.parquet").unlink()
        bad_errors = validate_output_root(contract_path, bad_root, check_values=True)
        if not any("file_index" in error and "missing required" in error for error in bad_errors):
            raise AssertionError(f"missing table should fail: {bad_errors}")
    print("validate_schema self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate SRA XML index Parquet outputs against schema/v1.")
    parser.add_argument("--schema", type=Path, default=Path(__file__).resolve().parents[1] / "schema" / "v1" / "schema.json")
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--check-values", action="store_true", help="Validate enum values in non-empty tables.")
    parser.add_argument("--write-empty-fixture", type=Path, help="Write an empty output-root fixture matching the schema.")
    parser.add_argument("--self-test", action="store_true", help="Verify that valid empty data passes and missing tables fail.")
    args = parser.parse_args()

    if args.self_test:
        self_test(args.schema)
        return 0
    if args.write_empty_fixture:
        write_empty_fixture(args.schema, args.write_empty_fixture)
        return 0
    if args.output_root is None:
        parser.error("--output-root is required unless --self-test or --write-empty-fixture is set")

    errors = validate_output_root(args.schema, args.output_root, check_values=args.check_values)
    if errors:
        print(json.dumps({"status": "failed", "errors": errors}, ensure_ascii=False, indent=2))
        return 1
    print(json.dumps({"status": "ok", "output_root": str(args.output_root)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
