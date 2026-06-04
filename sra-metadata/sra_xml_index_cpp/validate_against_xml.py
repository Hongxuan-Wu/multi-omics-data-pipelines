#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import json
import random
import re
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import duckdb


VALUE_LIMIT = 2000
DESIGN_DESCRIPTION_LIMIT = 2000


def norm(value: Any) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value)).strip()


def trunc(value: str, limit: int = VALUE_LIMIT) -> tuple[str, bool]:
    value = norm(value)
    if len(value) <= limit:
        return value, False
    return value[:limit], True


def lname(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def children(elem: ET.Element, name: str | None = None) -> list[ET.Element]:
    out = [c for c in list(elem) if name is None or lname(c.tag) == name]
    return out


def first_child(elem: ET.Element, name: str) -> ET.Element | None:
    for child in elem.iter():
        if child is elem:
            continue
        if lname(child.tag) == name:
            return child
    return None


def first_text(elem: ET.Element, name: str) -> str:
    node = first_child(elem, name)
    if node is None:
        return ""
    return norm("".join(node.itertext()))


def attr(elem: ET.Element | None, name: str) -> str:
    if elem is None:
        return ""
    return norm(elem.attrib.get(name, ""))


def accession_of(elem: ET.Element, tag_name: str) -> str:
    acc = attr(elem, "accession")
    if acc:
        return acc
    return first_text(elem, "PRIMARY_ID")


def child_attr_accession(elem: ET.Element, tag_name: str) -> str:
    node = first_child(elem, tag_name)
    return attr(node, "accession")


def external_id(elem: ET.Element, namespace: str) -> str:
    for node in elem.iter():
        if lname(node.tag) == "EXTERNAL_ID" and attr(node, "namespace") == namespace:
            return norm("".join(node.itertext()))
    return ""


def xref_label_for_db(elem: ET.Element, db_name: str) -> str:
    for node in elem.iter():
        if lname(node.tag) != "XREF_LINK":
            continue
        db = first_text(node, "DB")
        if db == db_name or db == "bioproject":
            label = first_text(node, "LABEL")
            return label or first_text(node, "ID")
    return ""


def platform_child(elem: ET.Element) -> str:
    platform = first_child(elem, "PLATFORM")
    if platform is None:
        return ""
    for child in list(platform):
        return lname(child.tag)
    return ""


def instrument_model(elem: ET.Element) -> str:
    platform = first_child(elem, "PLATFORM")
    if platform is not None:
        for child in list(platform):
            model = attr(child, "instrument_model")
            if model:
                return model
    return first_text(elem, "INSTRUMENT_MODEL")


def library_layout(elem: ET.Element) -> str:
    text = ET.tostring(elem, encoding="unicode")
    if "<PAIRED" in text:
        return "PAIRED"
    if "<SINGLE" in text:
        return "SINGLE"
    return ""


def entities(root: ET.Element, tag_name: str) -> list[ET.Element]:
    return [node for node in root.iter() if lname(node.tag) == tag_name]


def parse_expected(file_path: str) -> dict[str, list[dict[str, str]]]:
    tree = ET.parse(file_path)
    root = tree.getroot()
    expected: dict[str, list[dict[str, str]]] = {
        "run_core": [],
        "experiment_core": [],
        "sample_core": [],
        "study_core": [],
        "submission_core": [],
        "analysis_core": [],
        "relations": [],
        "sample_attribute_core": [],
    }

    for elem in entities(root, "RUN"):
        acc = accession_of(elem, "RUN")
        exp = child_attr_accession(elem, "EXPERIMENT_REF")
        expected["run_core"].append({
            "run_accession": acc,
            "alias": attr(elem, "alias"),
            "experiment_accession": exp,
        })
        if acc and exp:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "RUN",
                "relation_type": "RUN_TO_EXPERIMENT",
                "dst_accession": exp,
                "dst_type": "EXPERIMENT",
            })

    for elem in entities(root, "EXPERIMENT"):
        acc = accession_of(elem, "EXPERIMENT")
        study = child_attr_accession(elem, "STUDY_REF")
        sample = child_attr_accession(elem, "SAMPLE_DESCRIPTOR")
        design, design_truncated = trunc(first_text(elem, "DESIGN_DESCRIPTION"), DESIGN_DESCRIPTION_LIMIT)
        expected["experiment_core"].append({
            "experiment_accession": acc,
            "alias": attr(elem, "alias"),
            "title": first_text(elem, "TITLE"),
            "study_accession": study,
            "sample_accession": sample,
            "library_strategy": first_text(elem, "LIBRARY_STRATEGY"),
            "library_source": first_text(elem, "LIBRARY_SOURCE"),
            "library_selection": first_text(elem, "LIBRARY_SELECTION"),
            "library_layout": library_layout(elem),
            "platform": platform_child(elem),
            "instrument_model": instrument_model(elem),
            "design_description": design,
            "design_description_truncated": "true" if design_truncated else "false",
            "center_name": attr(elem, "center_name"),
        })
        if acc and sample:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "EXPERIMENT",
                "relation_type": "EXPERIMENT_TO_SAMPLE",
                "dst_accession": sample,
                "dst_type": "SAMPLE",
            })
        if acc and study:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "EXPERIMENT",
                "relation_type": "EXPERIMENT_TO_STUDY",
                "dst_accession": study,
                "dst_type": "STUDY",
            })

    for elem in entities(root, "SAMPLE"):
        acc = accession_of(elem, "SAMPLE")
        biosample = external_id(elem, "BioSample")
        bioproject = xref_label_for_db(elem, "bioproject")
        taxon = first_text(elem, "TAXON_ID")
        expected["sample_core"].append({
            "sample_accession": acc,
            "alias": attr(elem, "alias"),
            "bio_sample_id": biosample,
            "taxon_id": taxon,
            "scientific_name": first_text(elem, "SCIENTIFIC_NAME"),
            "bioproject_id": bioproject,
        })
        if acc and biosample:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "SAMPLE",
                "relation_type": "SAMPLE_TO_BIOSAMPLE",
                "dst_accession": biosample,
                "dst_type": "BioSample",
            })
        if acc and taxon:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "SAMPLE",
                "relation_type": "SAMPLE_TO_TAXON",
                "dst_accession": taxon,
                "dst_type": "Taxon",
            })
        if acc and bioproject:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "SAMPLE",
                "relation_type": "SAMPLE_XREF_bioproject",
                "dst_accession": bioproject,
                "dst_type": "BioProject",
            })
        ordinal = 0
        for attr_node in entities(elem, "SAMPLE_ATTRIBUTE"):
            ordinal += 1
            value, value_truncated = trunc(first_text(attr_node, "VALUE"))
            expected["sample_attribute_core"].append({
                "sample_accession": acc,
                "bio_sample_id": biosample,
                "tag": first_text(attr_node, "TAG"),
                "value": value,
                "attribute_ordinal": str(ordinal),
                "value_truncated": "true" if value_truncated else "false",
            })

    for elem in entities(root, "STUDY"):
        acc = accession_of(elem, "STUDY")
        bp = external_id(elem, "BioProject")
        study_type_node = first_child(elem, "STUDY_TYPE")
        existing_study_type = attr(study_type_node, "existing_study_type")
        study_type = first_text(elem, "STUDY_TYPE") or existing_study_type
        expected["study_core"].append({
            "study_accession": acc,
            "alias": attr(elem, "alias"),
            "bioproject_id": bp,
            "study_title": first_text(elem, "STUDY_TITLE"),
            "study_abstract": first_text(elem, "STUDY_ABSTRACT"),
            "study_type": study_type,
            "existing_study_type": existing_study_type,
        })
        if acc and bp:
            expected["relations"].append({
                "src_accession": acc,
                "src_type": "STUDY",
                "relation_type": "STUDY_TO_BIOPROJECT",
                "dst_accession": bp,
                "dst_type": "BioProject",
            })

    if lname(root.tag) == "SUBMISSION" or entities(root, "SUBMISSION"):
        submission_nodes = entities(root, "SUBMISSION") or [root]
        for elem in submission_nodes[:1]:
            expected["submission_core"].append({
                "submission_accession": attr(elem, "accession"),
                "alias": attr(elem, "alias"),
                "center_name": attr(elem, "center_name"),
                "lab_name": attr(elem, "lab_name"),
            })

    for elem in entities(root, "ANALYSIS"):
        acc = accession_of(elem, "ANALYSIS")
        expected["analysis_core"].append({
            "analysis_accession": acc,
            "alias": attr(elem, "alias"),
            "center_name": attr(elem, "center_name"),
            "title": first_text(elem, "TITLE"),
        })

    return expected


@dataclass
class Metric:
    checks: int = 0
    matches: int = 0
    mismatches: list[dict[str, Any]] = field(default_factory=list)

    @property
    def accuracy(self) -> float | None:
        if self.checks == 0:
            return None
        return self.matches / self.checks

    def add(self, ok: bool, detail: dict[str, Any], max_examples: int) -> None:
        self.checks += 1
        if ok:
            self.matches += 1
        elif len(self.mismatches) < max_examples:
            self.mismatches.append(detail)


def rows_by_key(rows: list[dict[str, Any]], key_cols: tuple[str, ...]) -> dict[tuple[str, ...], dict[str, str]]:
    out: dict[tuple[str, ...], dict[str, str]] = {}
    for row in rows:
        key = tuple(norm(row.get(col)) for col in key_cols)
        out[key] = {k: norm(v) for k, v in row.items()}
    return out


def row_multiset(rows: list[dict[str, str]], cols: tuple[str, ...]) -> collections.Counter[tuple[str, ...]]:
    return collections.Counter(tuple(norm(row.get(col)) for col in cols) for row in rows)


def fetch_rows(con: duckdb.DuckDBPyConnection, root: Path, table: str, file_ids: list[str]) -> list[dict[str, Any]]:
    if not file_ids:
        return []
    path = root / table / "data.parquet"
    placeholders = ",".join(["?"] * len(file_ids))
    cur = con.execute(
        f"SELECT * FROM read_parquet('{path}') WHERE file_id IN ({placeholders})",
        file_ids,
    )
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def compare_entity_table(
    metric: Metric,
    expected_rows: list[dict[str, str]],
    indexed_rows: list[dict[str, Any]],
    key_col: str,
    columns: list[str],
    file_id: str,
    table_name: str,
    max_examples: int,
) -> None:
    indexed = rows_by_key(indexed_rows, (key_col,))
    for expected in expected_rows:
        key = norm(expected.get(key_col))
        actual = indexed.get((key,))
        if actual is None:
            metric.add(False, {"table": table_name, "file_id": file_id, "key": key, "reason": "missing_index_row"}, max_examples)
            continue
        for col in columns:
            exp = norm(expected.get(col))
            got = norm(actual.get(col))
            metric.add(
                exp == got,
                {"table": table_name, "file_id": file_id, "key": key, "column": col, "expected": exp, "actual": got},
                max_examples,
            )


def compare_special_ids(
    metric: Metric,
    expected_samples: list[dict[str, str]],
    indexed_samples: list[dict[str, Any]],
    expected_studies: list[dict[str, str]],
    indexed_studies: list[dict[str, Any]],
    file_id: str,
    max_examples: int,
) -> None:
    compare_entity_table(metric, expected_samples, indexed_samples, "sample_accession", ["bio_sample_id", "bioproject_id"], file_id, "sample_core", max_examples)
    compare_entity_table(metric, expected_studies, indexed_studies, "study_accession", ["bioproject_id"], file_id, "study_core", max_examples)


def compare_relations(
    metric: Metric,
    expected_rows: list[dict[str, str]],
    indexed_rows: list[dict[str, Any]],
    file_id: str,
    max_examples: int,
) -> None:
    cols = ("src_accession", "src_type", "relation_type", "dst_accession", "dst_type")
    exp = row_multiset(expected_rows, cols)
    got = row_multiset([{k: norm(v) for k, v in row.items()} for row in indexed_rows], cols)
    for key, n in exp.items():
        matched = min(n, got.get(key, 0))
        for _ in range(matched):
            metric.add(True, {"file_id": file_id, "relation": key}, max_examples)
        for _ in range(n - matched):
            metric.add(False, {"file_id": file_id, "relation": key, "reason": "missing_or_wrong_index_relation"}, max_examples)
    for key, n in (got - exp).items():
        for _ in range(n):
            metric.add(False, {"file_id": file_id, "relation": key, "reason": "extra_index_relation"}, max_examples)


def compare_sample_attributes(
    metric: Metric,
    expected_rows: list[dict[str, str]],
    indexed_rows: list[dict[str, Any]],
    file_id: str,
    max_examples: int,
) -> None:
    cols = ("sample_accession", "bio_sample_id", "tag", "value", "attribute_ordinal", "value_truncated")
    exp = row_multiset(expected_rows, cols)
    got = row_multiset([{k: norm(v) for k, v in row.items()} for row in indexed_rows], cols)
    for key, n in exp.items():
        matched = min(n, got.get(key, 0))
        for _ in range(matched):
            metric.add(True, {"file_id": file_id, "sample_attribute": key}, max_examples)
        for _ in range(n - matched):
            metric.add(False, {"file_id": file_id, "sample_attribute": key, "reason": "missing_or_wrong_index_attribute"}, max_examples)
    for key, n in (got - exp).items():
        for _ in range(n):
            metric.add(False, {"file_id": file_id, "sample_attribute": key, "reason": "extra_index_attribute"}, max_examples)


def load_sampled_files(con: duckdb.DuckDBPyConnection, root: Path, sample_size: int, seed: int) -> list[dict[str, Any]]:
    path = root / "file_index" / "data.parquet"
    rows = con.execute(
        f"""
        SELECT file_id, directory_accession, xml_kind, file_path
        FROM read_parquet('{path}')
        WHERE parse_status = 'ok'
        """
    ).fetchall()
    rng = random.Random(seed)
    rng.shuffle(rows)
    rows = rows[:sample_size]
    return [
        {
            "file_id": norm(file_id),
            "directory_accession": norm(directory_accession),
            "xml_kind": norm(xml_kind),
            "file_path": norm(file_path),
        }
        for file_id, directory_accession, xml_kind, file_path in rows
    ]


def metric_to_dict(metric: Metric) -> dict[str, Any]:
    return {
        "checks": metric.checks,
        "matches": metric.matches,
        "mismatches": metric.checks - metric.matches,
        "accuracy": metric.accuracy,
        "examples": metric.mismatches,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate SRA XML Parquet index against original XML files.")
    parser.add_argument("--parquet-root", required=True, type=Path)
    parser.add_argument("--sample-size", type=int, default=200)
    parser.add_argument("--seed", type=int, default=20260604)
    parser.add_argument("--out-json", required=True, type=Path)
    parser.add_argument("--out-md", required=True, type=Path)
    parser.add_argument("--core-threshold", type=float, default=0.999)
    parser.add_argument("--relation-threshold", type=float, default=0.999)
    parser.add_argument("--external-id-threshold", type=float, default=0.995)
    parser.add_argument("--max-examples", type=int, default=50)
    args = parser.parse_args()

    t0 = time.time()
    con = duckdb.connect()
    sampled_files = load_sampled_files(con, args.parquet_root, args.sample_size, args.seed)
    file_ids = [row["file_id"] for row in sampled_files]

    indexed = {
        "run_core": fetch_rows(con, args.parquet_root, "core/run_core", file_ids),
        "experiment_core": fetch_rows(con, args.parquet_root, "core/experiment_core", file_ids),
        "sample_core": fetch_rows(con, args.parquet_root, "core/sample_core", file_ids),
        "study_core": fetch_rows(con, args.parquet_root, "core/study_core", file_ids),
        "submission_core": fetch_rows(con, args.parquet_root, "core/submission_core", file_ids),
        "analysis_core": fetch_rows(con, args.parquet_root, "core/analysis_core", file_ids),
        "sample_attribute_core": fetch_rows(con, args.parquet_root, "core/sample_attribute_core", file_ids),
        "relations": fetch_rows(con, args.parquet_root, "relation_index", file_ids),
    }
    indexed_by_file: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for table, rows in indexed.items():
        for row in rows:
            indexed_by_file.setdefault(norm(row["file_id"]), {}).setdefault(table, []).append(row)

    metrics = {
        "core_fields": Metric(),
        "relation_fields": Metric(),
        "biosample_bioproject": Metric(),
        "sample_attributes": Metric(),
    }
    parse_errors: list[dict[str, str]] = []
    entity_counts: collections.Counter[str] = collections.Counter()

    for file_row in sampled_files:
        file_id = file_row["file_id"]
        file_path = file_row["file_path"]
        try:
            expected = parse_expected(file_path)
        except Exception as exc:
            parse_errors.append({"file_id": file_id, "file_path": file_path, "error": repr(exc)})
            continue

        per_file = indexed_by_file.get(file_id, {})
        for table, rows in expected.items():
            entity_counts[table] += len(rows)

        compare_entity_table(
            metrics["core_fields"],
            expected["run_core"],
            per_file.get("run_core", []),
            "run_accession",
            ["alias", "experiment_accession"],
            file_id,
            "run_core",
            args.max_examples,
        )
        compare_entity_table(
            metrics["core_fields"],
            expected["experiment_core"],
            per_file.get("experiment_core", []),
            "experiment_accession",
            [
                "alias",
                "title",
                "study_accession",
                "sample_accession",
                "library_strategy",
                "library_source",
                "library_selection",
                "library_layout",
                "platform",
                "instrument_model",
                "design_description",
                "design_description_truncated",
                "center_name",
            ],
            file_id,
            "experiment_core",
            args.max_examples,
        )
        compare_entity_table(
            metrics["core_fields"],
            expected["sample_core"],
            per_file.get("sample_core", []),
            "sample_accession",
            ["alias", "taxon_id", "scientific_name"],
            file_id,
            "sample_core",
            args.max_examples,
        )
        compare_entity_table(
            metrics["core_fields"],
            expected["study_core"],
            per_file.get("study_core", []),
            "study_accession",
            ["alias", "study_title", "study_abstract", "study_type", "existing_study_type"],
            file_id,
            "study_core",
            args.max_examples,
        )
        compare_entity_table(
            metrics["core_fields"],
            expected["submission_core"],
            per_file.get("submission_core", []),
            "submission_accession",
            ["alias", "center_name", "lab_name"],
            file_id,
            "submission_core",
            args.max_examples,
        )
        compare_entity_table(
            metrics["core_fields"],
            expected["analysis_core"],
            per_file.get("analysis_core", []),
            "analysis_accession",
            ["alias", "center_name", "title"],
            file_id,
            "analysis_core",
            args.max_examples,
        )
        compare_special_ids(
            metrics["biosample_bioproject"],
            expected["sample_core"],
            per_file.get("sample_core", []),
            expected["study_core"],
            per_file.get("study_core", []),
            file_id,
            args.max_examples,
        )
        compare_relations(metrics["relation_fields"], expected["relations"], per_file.get("relations", []), file_id, args.max_examples)
        compare_sample_attributes(
            metrics["sample_attributes"],
            expected["sample_attribute_core"],
            per_file.get("sample_attribute_core", []),
            file_id,
            args.max_examples,
        )

    result = {
        "parquet_root": str(args.parquet_root),
        "sample_size_requested": args.sample_size,
        "sample_size_loaded": len(sampled_files),
        "seed": args.seed,
        "elapsed_seconds": time.time() - t0,
        "parse_errors": parse_errors,
        "entity_counts_in_sample": dict(entity_counts),
        "metrics": {name: metric_to_dict(metric) for name, metric in metrics.items()},
        "thresholds": {
            "core_fields": args.core_threshold,
            "relation_fields": args.relation_threshold,
            "biosample_bioproject": args.external_id_threshold,
        },
    }

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_md.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    md = [
        "# SRA XML Index Validation Against Original XML",
        "",
        f"- Parquet root: `{args.parquet_root}`",
        f"- Sample size requested: {args.sample_size}",
        f"- Sample size loaded: {len(sampled_files)}",
        f"- Seed: {args.seed}",
        f"- XML parse errors during validation: {len(parse_errors)}",
        f"- Elapsed seconds: {result['elapsed_seconds']:.2f}",
        "",
        "## Accuracy",
    ]
    for name, metric in result["metrics"].items():
        md.append(
            f"- {name}: accuracy={metric['accuracy']}, "
            f"checks={metric['checks']}, mismatches={metric['mismatches']}"
        )
    md.append("")
    md.append("## Entity Counts In Sample")
    for name, count in sorted(entity_counts.items()):
        md.append(f"- {name}: {count}")
    md.append("")
    md.append("## Mismatch Examples")
    for name, metric in result["metrics"].items():
        examples = metric["examples"]
        md.append(f"### {name}")
        if not examples:
            md.append("- none")
        else:
            for example in examples[:10]:
                md.append(f"- `{json.dumps(example, ensure_ascii=False)}`")
    args.out_md.write_text("\n".join(md) + "\n", encoding="utf-8")

    failed = False
    if metrics["core_fields"].checks and (metrics["core_fields"].accuracy or 0.0) < args.core_threshold:
        failed = True
    if metrics["relation_fields"].checks and (metrics["relation_fields"].accuracy or 0.0) < args.relation_threshold:
        failed = True
    if metrics["biosample_bioproject"].checks and (metrics["biosample_bioproject"].accuracy or 0.0) < args.external_id_threshold:
        failed = True
    if parse_errors:
        failed = True

    print(json.dumps({
        "out_json": str(args.out_json),
        "out_md": str(args.out_md),
        "failed": failed,
        "metrics": {name: metric_to_dict(metric) for name, metric in metrics.items()},
    }, ensure_ascii=False, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
