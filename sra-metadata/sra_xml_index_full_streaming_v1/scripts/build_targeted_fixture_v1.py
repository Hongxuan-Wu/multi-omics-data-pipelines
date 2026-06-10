#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import heapq
import hashlib
import json
import os
import random
import shutil
import socket
import subprocess
import time
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq

from validate_schema import expected_arrow_schema, load_contract


ROOT_TAG_TO_KIND = {
    "RUN_SET": "run",
    "EXPERIMENT_SET": "experiment",
    "SAMPLE_SET": "sample",
    "STUDY_SET": "study",
    "SUBMISSION_SET": "submission",
    "ANALYSIS_SET": "analysis",
}
ENTITY_TYPES = ["RUN", "EXPERIMENT", "SAMPLE", "STUDY", "SUBMISSION", "ANALYSIS"]
PARSER_VERSION = "v1.0.0-targeted-min"
GLOBAL_TABLES = {"build_manifest", "chunk_status_summary"}


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def digest_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def digest_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def stable_id(*parts: str) -> str:
    return hashlib.sha1("\x1f".join(parts).encode("utf-8")).hexdigest()


def lname(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def clean(value: Any) -> str:
    if value is None:
        return ""
    return " ".join(str(value).split())


def text_of(elem: ET.Element | None) -> str:
    if elem is None:
        return ""
    return clean("".join(elem.itertext()))


def first_child(elem: ET.Element, name: str) -> ET.Element | None:
    for node in elem.iter():
        if node is elem:
            continue
        if lname(node.tag) == name:
            return node
    return None


def first_text(elem: ET.Element, name: str) -> str:
    return text_of(first_child(elem, name))


def attr(elem: ET.Element | None, name: str) -> str:
    if elem is None:
        return ""
    return clean(elem.attrib.get(name, ""))


def accession_of(elem: ET.Element) -> tuple[str, str]:
    acc = attr(elem, "accession")
    if acc:
        return acc, "@accession"
    primary = first_text(elem, "PRIMARY_ID")
    if primary:
        return primary, "PRIMARY_ID"
    return "", ""


def child_accession(elem: ET.Element, name: str) -> str:
    return attr(first_child(elem, name), "accession")


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


def external_id(elem: ET.Element, namespace: str) -> str:
    for node in elem.iter():
        if lname(node.tag) == "EXTERNAL_ID" and attr(node, "namespace") == namespace:
            return text_of(node)
    return ""


def xref_label_for_db(elem: ET.Element, db_name: str) -> str:
    for node in elem.iter():
        if lname(node.tag) != "XREF_LINK":
            continue
        db = first_text(node, "DB")
        if db == db_name or db == "bioproject":
            return first_text(node, "LABEL") or first_text(node, "ID")
    return ""


def xml_kind_from_filename(path: Path) -> str:
    name = path.name
    for kind in ["run", "experiment", "sample", "study", "submission", "analysis"]:
        if name.endswith(f".{kind}.xml"):
            return kind
    return "unknown"


def entity_path(entity_type: str, ordinal: int) -> str:
    return f"//{entity_type}[{ordinal}]"


def iter_entities(root: ET.Element, entity_type: str) -> list[ET.Element]:
    return [node for node in root.iter() if lname(node.tag) == entity_type]


def table_schema(contract: dict[str, Any], table_name: str) -> pa.Schema:
    return expected_arrow_schema(contract, table_name)


def empty_row_store(contract: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    return {name: [] for name in contract["tables"]}


def coerce_rows(rows: list[dict[str, Any]], schema: pa.Schema) -> pa.Table:
    arrays = []
    for field in schema:
        values = [row.get(field.name) for row in rows]
        arrays.append(pa.array(values, type=field.type))
    return pa.Table.from_arrays(arrays, schema=schema)


def write_table(contract: dict[str, Any], root: Path, table_name: str, rows: list[dict[str, Any]]) -> int:
    spec = contract["tables"][table_name]
    path = root / spec["path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    schema = table_schema(contract, table_name)
    pq.write_table(coerce_rows(rows, schema), path)
    return len(rows)


def write_all_tables(contract: dict[str, Any], root: Path, rows: dict[str, list[dict[str, Any]]]) -> dict[str, int]:
    counts = {}
    for table_name in sorted(contract["tables"]):
        counts[table_name] = write_table(contract, root, table_name, rows.get(table_name, []))
    return counts


def read_fixture_accessions(path: Path) -> list[str]:
    accessions: list[str] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            acc = row["directory_accession"].strip()
            if acc and acc not in accessions:
                accessions.append(acc)
    return sorted(accessions)


def read_all_directory_accessions(xml_root: Path) -> list[str]:
    accessions = []
    with os.scandir(xml_root) as entries:
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                accessions.append(entry.name)
    return sorted(accessions)


def select_prefix_stratified_accessions(all_accessions: list[str], sample_size: int, rng: random.Random) -> list[str]:
    if sample_size <= 0:
        return []
    if sample_size > len(all_accessions):
        raise ValueError(f"--sample-size {sample_size} exceeds directory count {len(all_accessions)}")
    groups: dict[str, list[str]] = defaultdict(list)
    for acc in all_accessions:
        groups[acc[:3]].append(acc)
    selected: list[str] = []
    prefixes = sorted(groups)
    total = len(all_accessions)
    quotas = {p: int(round(len(groups[p]) / total * sample_size)) for p in prefixes}
    for p in prefixes:
        if groups[p] and quotas[p] == 0:
            quotas[p] = 1
    while sum(quotas.values()) > sample_size:
        p = max(prefixes, key=lambda x: quotas[x])
        quotas[p] -= 1
    while sum(quotas.values()) < sample_size:
        p = max(prefixes, key=lambda x: len(groups[x]) - quotas[x])
        quotas[p] += 1
    for p in prefixes:
        selected.extend(rng.sample(groups[p], min(quotas[p], len(groups[p]))))
    return selected


def directory_xml_size(directory: Path) -> int:
    total = 0
    for xml_file in directory.glob("*.xml"):
        try:
            total += xml_file.stat().st_size
        except OSError:
            continue
    return total


def select_large_file_enriched_accessions(xml_root: Path, all_accessions: list[str], sample_size: int, rng: random.Random) -> list[str]:
    if sample_size <= 0:
        return []
    candidate_size = min(len(all_accessions), max(sample_size * 5, 5000))
    candidates = rng.sample(all_accessions, candidate_size)
    heap: list[tuple[int, str]] = []
    for acc in candidates:
        size = directory_xml_size(xml_root / acc)
        item = (size, acc)
        if len(heap) < sample_size:
            heapq.heappush(heap, item)
        elif item > heap[0]:
            heapq.heapreplace(heap, item)
    return [acc for _, acc in sorted(heap, reverse=True)]


def select_stress_mixed_accessions(xml_root: Path, all_accessions: list[str], sample_size: int, seed: int) -> list[str]:
    if sample_size <= 0:
        raise ValueError("--sample-size must be positive for stress_mixed")
    if sample_size > len(all_accessions):
        raise ValueError(f"--sample-size {sample_size} exceeds directory count {len(all_accessions)}")
    rng = random.Random(seed)
    large_rng = random.Random(seed + 1009)
    prefix_n = int(sample_size * 0.70)
    large_n = int(sample_size * 0.20)
    selected: list[str] = []
    selected_set: set[str] = set()
    for acc in select_prefix_stratified_accessions(all_accessions, prefix_n, rng):
        if acc not in selected_set:
            selected.append(acc)
            selected_set.add(acc)
    for acc in select_large_file_enriched_accessions(xml_root, all_accessions, large_n, large_rng):
        if acc not in selected_set:
            selected.append(acc)
            selected_set.add(acc)
    remaining_pool = [acc for acc in all_accessions if acc not in selected_set]
    rng.shuffle(remaining_pool)
    for acc in remaining_pool:
        if len(selected) >= sample_size:
            break
        selected.append(acc)
        selected_set.add(acc)
    return sorted(selected)


def select_manifest_accessions(args: argparse.Namespace) -> list[str]:
    if args.manifest_subset_type == "targeted":
        return read_fixture_accessions(args.fixture)
    if args.manifest_subset_type == "full":
        if args.sample_size not in (0, None):
            raise ValueError("--sample-size must be 0 or omitted for full")
        return read_all_directory_accessions(args.xml_root)
    if args.manifest_subset_type == "deterministic_random":
        all_accessions = read_all_directory_accessions(args.xml_root)
        if args.sample_size <= 0:
            raise ValueError("--sample-size must be positive for deterministic_random")
        if args.sample_size > len(all_accessions):
            raise ValueError(f"--sample-size {args.sample_size} exceeds directory count {len(all_accessions)}")
        rng = random.Random(args.seed)
        return sorted(rng.sample(all_accessions, args.sample_size))
    if args.manifest_subset_type == "prefix_stratified":
        all_accessions = read_all_directory_accessions(args.xml_root)
        if args.sample_size <= 0:
            raise ValueError("--sample-size must be positive for prefix_stratified")
        rng = random.Random(args.seed)
        return sorted(select_prefix_stratified_accessions(all_accessions, args.sample_size, rng))
    if args.manifest_subset_type == "stress_mixed":
        all_accessions = read_all_directory_accessions(args.xml_root)
        return select_stress_mixed_accessions(args.xml_root, all_accessions, args.sample_size, args.seed)
    raise ValueError(f"unsupported manifest subset type for this builder: {args.manifest_subset_type}")


def make_directory_manifest(xml_root: Path, accessions: list[str], snapshot: str) -> list[dict[str, Any]]:
    rows = []
    for idx, acc in enumerate(sorted(accessions)):
        absolute = xml_root / acc
        relative = acc
        rows.append({
            "source_snapshot_id": snapshot,
            "manifest_row_id": idx,
            "directory_id": stable_id(snapshot, relative),
            "directory_accession": acc,
            "directory_prefix": acc[:3],
            "relative_directory_path": relative,
            "absolute_directory_path": str(absolute),
        })
    return rows


def make_chunk_manifest(directory_rows: list[dict[str, Any]], chunk_size: int) -> list[dict[str, Any]]:
    if not directory_rows:
        return []
    chunks = []
    for start in range(0, len(directory_rows), chunk_size):
        subset = directory_rows[start:start + chunk_size]
        chunks.append({
            "chunk_id": f"chunk_{subset[0]['manifest_row_id']:08d}_{subset[-1]['manifest_row_id']:08d}",
            "start_row": int(subset[0]["manifest_row_id"]),
            "row_count": len(subset),
            "manifest_row_id_start": int(subset[0]["manifest_row_id"]),
            "manifest_row_id_end": int(subset[-1]["manifest_row_id"]),
            "expected_directory_count": len(subset),
        })
    return chunks


def scan_xml_paths(root: ET.Element, file_id: str, snapshot: str, xml_kind: str, root_tag: str) -> list[dict[str, Any]]:
    stats: dict[tuple[str, str | None, bool], dict[str, Any]] = {}

    def visit(elem: ET.Element, path: str, entity_type: str | None, entity_accession: str | None) -> None:
        key = (path, entity_type, False)
        value = text_of(elem)
        item = stats.setdefault(key, {
            "source_snapshot_id": snapshot,
            "xml_kind": xml_kind,
            "root_tag": root_tag,
            "entity_type": entity_type,
            "path_abs": path,
            "path_entity_relative": path.split(f"/{entity_type}", 1)[-1] if entity_type and f"/{entity_type}" in path else None,
            "is_attribute": False,
            "node_occurrence_count": 0,
            "non_empty_occurrence_count": 0,
            "entity_values": set(),
            "file_values": set(),
            "max_value_length": 0,
            "example_value": None,
            "example_value_truncated": False,
            "example_file_id": None,
            "example_entity_accession": None,
        })
        item["node_occurrence_count"] += 1
        item["file_values"].add(file_id)
        if entity_accession:
            item["entity_values"].add(entity_accession)
        if value:
            item["non_empty_occurrence_count"] += 1
            item["max_value_length"] = max(item["max_value_length"], len(value))
            if item["example_value"] is None:
                item["example_value"] = value[:500]
                item["example_value_truncated"] = len(value) > 500
                item["example_file_id"] = file_id
                item["example_entity_accession"] = entity_accession

        for name, raw in elem.attrib.items():
            attr_path = f"{path}/@{name}"
            key = (attr_path, entity_type, True)
            val = clean(raw)
            attr_item = stats.setdefault(key, {
                "source_snapshot_id": snapshot,
                "xml_kind": xml_kind,
                "root_tag": root_tag,
                "entity_type": entity_type,
                "path_abs": attr_path,
                "path_entity_relative": attr_path.split(f"/{entity_type}", 1)[-1] if entity_type and f"/{entity_type}" in attr_path else None,
                "is_attribute": True,
                "node_occurrence_count": 0,
                "non_empty_occurrence_count": 0,
                "entity_values": set(),
                "file_values": set(),
                "max_value_length": 0,
                "example_value": None,
                "example_value_truncated": False,
                "example_file_id": None,
                "example_entity_accession": None,
            })
            attr_item["node_occurrence_count"] += 1
            attr_item["file_values"].add(file_id)
            if entity_accession:
                attr_item["entity_values"].add(entity_accession)
            if val:
                attr_item["non_empty_occurrence_count"] += 1
                attr_item["max_value_length"] = max(attr_item["max_value_length"], len(val))
                if attr_item["example_value"] is None:
                    attr_item["example_value"] = val[:500]
                    attr_item["example_value_truncated"] = len(val) > 500
                    attr_item["example_file_id"] = file_id
                    attr_item["example_entity_accession"] = entity_accession

        next_entity_type = entity_type
        next_entity_accession = entity_accession
        tag_name = lname(elem.tag)
        if tag_name in ENTITY_TYPES:
            acc, _ = accession_of(elem)
            next_entity_type = tag_name
            next_entity_accession = acc or entity_accession
        for child in list(elem):
            visit(child, f"{path}/{lname(child.tag)}", next_entity_type, next_entity_accession)

    visit(root, f"/{lname(root.tag)}", None, None)
    out = []
    for item in stats.values():
        entity_values = item.pop("entity_values")
        file_values = item.pop("file_values")
        item["entity_coverage_count"] = len(entity_values)
        item["file_coverage_count"] = len(file_values)
        out.append(item)
    return out


def parse_chunk(directory_rows: list[dict[str, Any]], snapshot: str, contract: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    rows = empty_row_store(contract)
    entity_records: list[dict[str, Any]] = []
    relations: list[dict[str, Any]] = []
    external_rows: list[dict[str, Any]] = []
    file_rows: list[dict[str, Any]] = []
    directory_rows_out: list[dict[str, Any]] = []
    inventory_rows: list[dict[str, Any]] = []
    core_raw = {name: [] for name in ["run_core_raw", "experiment_core_raw", "sample_core_raw", "study_core_raw", "sample_attribute_core"]}

    for drow in directory_rows:
        directory_path = Path(drow["absolute_directory_path"])
        xml_files = sorted(directory_path.glob("*.xml"))
        kind_counts = Counter()
        parse_success = 0
        parse_failed = 0
        for xml_file in xml_files:
            kind_from_filename = xml_kind_from_filename(xml_file)
            kind_counts[kind_from_filename if kind_from_filename in ROOT_TAG_TO_KIND.values() else "other"] += 1
            rel_file = f"{drow['relative_directory_path']}/{xml_file.name}"
            file_id = stable_id(snapshot, rel_file)
            stat = xml_file.stat()
            root = None
            root_tag = ""
            xml_kind_root = "unknown"
            parse_status = "ok"
            error_type = "none"
            error_message = None
            warning_count = 0
            entity_count = 0
            try:
                if stat.st_size == 0:
                    raise ValueError("empty_file")
                root = ET.parse(xml_file).getroot()
                root_tag = lname(root.tag)
                xml_kind_root = ROOT_TAG_TO_KIND.get(root_tag, "unknown")
                if xml_kind_root == "unknown":
                    parse_status = "unsupported_root"
                    error_type = "unexpected_root"
                if kind_from_filename != "unknown" and xml_kind_root != "unknown" and kind_from_filename != xml_kind_root:
                    warning_count += 1
                entity_count = sum(1 for typ in ENTITY_TYPES for _ in iter_entities(root, typ))
            except Exception as exc:
                if str(exc) == "empty_file":
                    parse_status = "empty_file"
                    error_type = "unknown"
                    error_message = "empty file"
                else:
                    parse_status = "xml_parse_error"
                    error_type = "xml_syntax"
                    error_message = repr(exc)
            xml_kind = xml_kind_root if xml_kind_root != "unknown" else kind_from_filename
            consistency = "consistent" if kind_from_filename == xml_kind_root else "mismatch" if xml_kind_root != "unknown" else "unknown"
            file_rows.append({
                "source_snapshot_id": snapshot,
                "file_id": file_id,
                "directory_id": drow["directory_id"],
                "directory_accession": drow["directory_accession"],
                "xml_kind": xml_kind,
                "xml_kind_from_filename": kind_from_filename,
                "xml_kind_from_root_tag": xml_kind_root,
                "xml_kind_consistency_status": consistency,
                "file_name": xml_file.name,
                "relative_file_path": rel_file,
                "absolute_file_path": str(xml_file),
                "file_size": stat.st_size,
                "mtime": datetime.fromtimestamp(stat.st_mtime, timezone.utc).replace(tzinfo=None),
                "parse_status": parse_status,
                "root_tag": root_tag,
                "root_entity_set_type": root_tag,
                "entity_count": entity_count,
                "error_type": error_type,
                "error_message": error_message,
                "parser_warning_count": warning_count,
            })
            if parse_status == "ok":
                parse_success += 1
            else:
                parse_failed += 1
            if root is None or parse_status not in {"ok", "unsupported_root"}:
                continue

            inventory_rows.extend(scan_xml_paths(root, file_id, snapshot, xml_kind, root_tag))
            for entity_type in ENTITY_TYPES:
                for ordinal, elem in enumerate(iter_entities(root, entity_type), start=1):
                    acc, acc_path = accession_of(elem)
                    role = "primary"
                    record_id = stable_id(snapshot, file_id, entity_type, str(ordinal), acc or "missing")
                    status = "ok" if acc else "missing_accession"
                    entity_records.append({
                        "source_snapshot_id": snapshot,
                        "entity_record_id": record_id,
                        "entity_accession": acc or None,
                        "entity_type": entity_type,
                        "occurrence_role": role,
                        "directory_id": drow["directory_id"],
                        "directory_accession": drow["directory_accession"],
                        "file_id": file_id,
                        "xml_kind": xml_kind,
                        "root_tag": root_tag,
                        "entity_path": entity_path(entity_type, ordinal),
                        "entity_ordinal": ordinal,
                        "accession_source_path": acc_path or None,
                        "alias": attr(elem, "alias") or None,
                        "primary_id": first_text(elem, "PRIMARY_ID") or None,
                        "submitter_id": first_text(elem, "SUBMITTER_ID") or None,
                        "parse_status": status,
                    })
                    if entity_type == "RUN":
                        exp = child_accession(elem, "EXPERIMENT_REF")
                        core_raw["run_core_raw"].append({
                            "source_snapshot_id": snapshot,
                            "entity_record_id": record_id,
                            "file_id": file_id,
                            "run_accession": acc,
                            "alias": attr(elem, "alias") or None,
                            "experiment_accession": exp or None,
                        })
                        if acc and exp:
                            relations.append(make_relation(snapshot, record_id, acc, "RUN", "RUN_TO_EXPERIMENT", exp, "EXPERIMENT", drow, file_id, len(relations) + 1))
                    elif entity_type == "EXPERIMENT":
                        sample = child_accession(elem, "SAMPLE_DESCRIPTOR")
                        study = child_accession(elem, "STUDY_REF")
                        core_raw["experiment_core_raw"].append({
                            "source_snapshot_id": snapshot,
                            "entity_record_id": record_id,
                            "file_id": file_id,
                            "experiment_accession": acc,
                            "sample_accession": sample or None,
                            "study_accession": study or None,
                            "library_strategy": first_text(elem, "LIBRARY_STRATEGY") or None,
                            "library_source": first_text(elem, "LIBRARY_SOURCE") or None,
                            "library_selection": first_text(elem, "LIBRARY_SELECTION") or None,
                            "platform": platform_child(elem) or None,
                            "instrument_model": instrument_model(elem) or None,
                        })
                        if acc and sample:
                            relations.append(make_relation(snapshot, record_id, acc, "EXPERIMENT", "EXPERIMENT_TO_SAMPLE", sample, "SAMPLE", drow, file_id, len(relations) + 1))
                        if acc and study:
                            relations.append(make_relation(snapshot, record_id, acc, "EXPERIMENT", "EXPERIMENT_TO_STUDY", study, "STUDY", drow, file_id, len(relations) + 1))
                    elif entity_type == "SAMPLE":
                        biosample = external_id(elem, "BioSample")
                        bioproject = xref_label_for_db(elem, "bioproject")
                        taxon = first_text(elem, "TAXON_ID")
                        core_raw["sample_core_raw"].append({
                            "source_snapshot_id": snapshot,
                            "entity_record_id": record_id,
                            "file_id": file_id,
                            "sample_accession": acc,
                            "bio_sample_id": biosample or None,
                            "taxon_id": taxon or None,
                            "scientific_name": first_text(elem, "SCIENTIFIC_NAME") or None,
                        })
                        if acc and biosample:
                            external_rows.append(make_external(snapshot, record_id, acc, "SAMPLE", "BioSample", biosample, "EXTERNAL_ID", "SAMPLE/IDENTIFIERS/EXTERNAL_ID", drow, file_id))
                            relations.append(make_relation(snapshot, record_id, acc, "SAMPLE", "SAMPLE_TO_BIOSAMPLE", biosample, "BioSample", drow, file_id, len(relations) + 1, False))
                        if acc and bioproject:
                            external_rows.append(make_external(snapshot, record_id, acc, "SAMPLE", "BioProject", bioproject, "XREF_LINK", "SAMPLE/SAMPLE_LINKS/XREF_LINK", drow, file_id))
                            relations.append(make_relation(snapshot, record_id, acc, "SAMPLE", "SAMPLE_XREF_bioproject", bioproject, "BioProject", drow, file_id, len(relations) + 1, False))
                        if acc and taxon:
                            external_rows.append(make_external(snapshot, record_id, acc, "SAMPLE", "Taxon", taxon, "TAXON_ID", "SAMPLE/SAMPLE_NAME/TAXON_ID", drow, file_id))
                            relations.append(make_relation(snapshot, record_id, acc, "SAMPLE", "SAMPLE_TO_TAXON", taxon, "Taxon", drow, file_id, len(relations) + 1, False))
                        for attr_ordinal, attr_node in enumerate(iter_entities(elem, "SAMPLE_ATTRIBUTE"), start=1):
                            value = first_text(attr_node, "VALUE")
                            core_raw["sample_attribute_core"].append({
                                "source_snapshot_id": snapshot,
                                "entity_record_id": record_id,
                                "file_id": file_id,
                                "sample_accession": acc or None,
                                "bio_sample_id": biosample or None,
                                "tag": first_text(attr_node, "TAG"),
                                "value": value[:2000] if value else None,
                                "attribute_ordinal": attr_ordinal,
                                "value_truncated": len(value) > 2000 if value else False,
                            })
                    elif entity_type == "STUDY":
                        bioproject = external_id(elem, "BioProject") or xref_label_for_db(elem, "bioproject")
                        core_raw["study_core_raw"].append({
                            "source_snapshot_id": snapshot,
                            "entity_record_id": record_id,
                            "file_id": file_id,
                            "study_accession": acc,
                            "bioproject_id": bioproject or None,
                            "study_type": first_text(elem, "STUDY_TYPE") or attr(first_child(elem, "STUDY_TYPE"), "existing_study_type") or None,
                            "study_title": first_text(elem, "STUDY_TITLE") or None,
                        })
                        if acc and bioproject:
                            external_rows.append(make_external(snapshot, record_id, acc, "STUDY", "BioProject", bioproject, "EXTERNAL_ID", "STUDY/IDENTIFIERS/EXTERNAL_ID", drow, file_id))
                            relations.append(make_relation(snapshot, record_id, acc, "STUDY", "STUDY_TO_BIOPROJECT", bioproject, "BioProject", drow, file_id, len(relations) + 1, False))
        directory_rows_out.append({
            "source_snapshot_id": snapshot,
            "directory_id": drow["directory_id"],
            "directory_accession": drow["directory_accession"],
            "directory_prefix": drow["directory_prefix"],
            "relative_directory_path": drow["relative_directory_path"],
            "absolute_directory_path": drow["absolute_directory_path"],
            "file_count": len(xml_files),
            "run_xml_count": kind_counts["run"],
            "experiment_xml_count": kind_counts["experiment"],
            "sample_xml_count": kind_counts["sample"],
            "study_xml_count": kind_counts["study"],
            "submission_xml_count": kind_counts["submission"],
            "analysis_xml_count": kind_counts["analysis"],
            "other_xml_count": kind_counts["other"],
            "parse_success_file_count": parse_success,
            "parse_failed_file_count": parse_failed,
            "scan_status": "ok" if parse_failed == 0 else "partial",
        })

    rows["directory_index"] = directory_rows_out
    rows["file_index"] = file_rows
    rows["entity_record_index"] = entity_records
    rows["external_accession_index"] = external_rows
    rows["relation_index"] = close_relations(relations, entity_records)
    for table_name, table_rows in core_raw.items():
        rows[table_name] = table_rows
    rows["run_core"] = list(core_raw["run_core_raw"])
    rows["experiment_core"] = list(core_raw["experiment_core_raw"])
    rows["sample_core"] = list(core_raw["sample_core_raw"])
    rows["study_core"] = list(core_raw["study_core_raw"])
    rows["entity_index"] = build_entity_index(snapshot, entity_records)
    rows["xml_path_inventory"] = merge_inventory(inventory_rows)
    add_qc(rows, snapshot)
    return rows


def make_external(snapshot: str, entity_record_id: str, entity_accession: str, entity_type: str, namespace: str, value: str, id_type: str, source_path: str, drow: dict[str, Any], file_id: str) -> dict[str, Any]:
    return {
        "source_snapshot_id": snapshot,
        "external_record_id": stable_id(snapshot, entity_record_id, namespace, value, source_path),
        "entity_record_id": entity_record_id,
        "entity_accession": entity_accession,
        "entity_type": entity_type,
        "namespace": namespace,
        "external_accession": value,
        "external_id_type": id_type,
        "raw_value": value,
        "source_path": source_path,
        "directory_id": drow["directory_id"],
        "directory_accession": drow["directory_accession"],
        "file_id": file_id,
    }


def make_relation(snapshot: str, src_record_id: str, src_acc: str, src_type: str, rel_type: str, dst_acc: str, dst_type: str, drow: dict[str, Any], file_id: str, ordinal: int, internal: bool = True) -> dict[str, Any]:
    return {
        "source_snapshot_id": snapshot,
        "relation_id": stable_id(snapshot, src_record_id, rel_type, dst_acc, str(ordinal)),
        "src_entity_record_id": src_record_id,
        "src_accession": src_acc,
        "src_type": src_type,
        "relation_type": rel_type,
        "dst_accession": dst_acc,
        "dst_type": dst_type,
        "dst_namespace": None if internal else dst_type,
        "dst_is_internal_entity": internal,
        "dst_entity_record_id": None,
        "dst_primary_exists": False,
        "dst_entity_index_status": "not_checked",
        "dst_raw_value": dst_acc,
        "relation_source_path": rel_type,
        "relation_ordinal": ordinal,
        "directory_id": drow["directory_id"],
        "directory_accession": drow["directory_accession"],
        "file_id": file_id,
        "closure_status": "not_checked",
    }


def close_relations(relations: list[dict[str, Any]], entity_records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    primary = {}
    for row in entity_records:
        acc = row["entity_accession"]
        if acc and row["parse_status"] == "ok" and row["occurrence_role"] == "primary":
            primary.setdefault((row["entity_type"], acc), row)
    for rel in relations:
        if not rel["dst_is_internal_entity"]:
            rel["closure_status"] = "external_reference"
            rel["dst_entity_index_status"] = "external_reference"
            continue
        target = primary.get((rel["dst_type"], rel["dst_accession"]))
        if target:
            rel["dst_entity_record_id"] = target["entity_record_id"]
            rel["dst_primary_exists"] = True
            rel["dst_entity_index_status"] = "primary_present"
            rel["closure_status"] = "closed"
        else:
            rel["dst_primary_exists"] = False
            rel["dst_entity_index_status"] = "missing_dst_entity"
            rel["closure_status"] = "missing_dst_entity"
    return relations


def build_entity_index(snapshot: str, entity_records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in entity_records:
        if not row["entity_accession"]:
            continue
        grouped[(row["entity_type"], row["entity_accession"])].append(row)
    out = []
    for (entity_type, accession), records in sorted(grouped.items()):
        primary_records = [r for r in records if r["occurrence_role"] == "primary" and r["parse_status"] == "ok"]
        canonical = primary_records[0] if primary_records else records[0]
        out.append({
            "source_snapshot_id": snapshot,
            "entity_accession": accession,
            "entity_type": entity_type,
            "record_count": len(records),
            "primary_record_count": len(primary_records),
            "reference_record_count": len(records) - len(primary_records),
            "has_primary_record": bool(primary_records),
            "has_reference_record": len(records) > len(primary_records),
            "entity_presence_status": "primary_present" if primary_records else "reference_only",
            "file_count": len({r["file_id"] for r in records}),
            "directory_count": len({r["directory_id"] for r in records}),
            "canonical_entity_record_id": canonical["entity_record_id"] if primary_records else None,
            "canonical_file_id": canonical["file_id"] if primary_records else None,
            "canonical_directory_id": canonical["directory_id"] if primary_records else None,
            "canonical_rule": "first_primary_by_manifest_order" if primary_records else "none_reference_only",
            "has_conflict": False,
            "conflict_type": None,
            "conflict_field_count": 0,
        })
    return out


def merge_inventory(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], dict[str, Any]] = {}
    for row in rows:
        key = (row["source_snapshot_id"], row["xml_kind"], row["root_tag"], row["entity_type"], row["path_abs"], row["path_entity_relative"], row["is_attribute"])
        item = grouped.get(key)
        if item is None:
            item = {**row, "_files": set(), "_entities": set()}
            item["node_occurrence_count"] = 0
            item["non_empty_occurrence_count"] = 0
            item["max_value_length"] = 0
            item["example_value"] = None
            item["example_value_truncated"] = False
            item["example_file_id"] = None
            item["example_entity_accession"] = None
            grouped[key] = item
        item["node_occurrence_count"] += row["node_occurrence_count"]
        item["non_empty_occurrence_count"] += row["non_empty_occurrence_count"]
        item["max_value_length"] = max(item["max_value_length"], row["max_value_length"])
        if item.get("example_value") is None and row.get("example_value") is not None:
            item["example_value"] = row["example_value"]
            item["example_value_truncated"] = row["example_value_truncated"]
            item["example_file_id"] = row["example_file_id"]
            item["example_entity_accession"] = row["example_entity_accession"]
        if row.get("example_file_id"):
            item["_files"].add(row["example_file_id"])
        if row.get("example_entity_accession"):
            item["_entities"].add(row["example_entity_accession"])
    out = []
    for item in grouped.values():
        item["file_coverage_count"] = max(item["file_coverage_count"], len(item.pop("_files")))
        item["entity_coverage_count"] = max(item["entity_coverage_count"], len(item.pop("_entities")))
        out.append(item)
    return sorted(out, key=lambda r: (r["xml_kind"], r["root_tag"], r["path_abs"]))


def add_qc(rows: dict[str, list[dict[str, Any]]], snapshot: str) -> None:
    by_kind = Counter(row["xml_kind"] for row in rows["file_index"])
    ok_by_kind = Counter(row["xml_kind"] for row in rows["file_index"] if row["parse_status"] == "ok")
    rows["parse_qc_summary"] = [{
        "source_snapshot_id": snapshot,
        "xml_kind": kind,
        "file_count": count,
        "parse_success_count": ok_by_kind[kind],
        "parse_failed_count": count - ok_by_kind[kind],
        "severity": "warning" if count - ok_by_kind[kind] > 0 else "report_only",
    } for kind, count in sorted(by_kind.items())]

    by_entity = defaultdict(list)
    for row in rows["entity_record_index"]:
        by_entity[row["entity_type"]].append(row)
    rows["entity_qc_summary"] = [{
        "source_snapshot_id": snapshot,
        "entity_type": typ,
        "entity_record_count": len(items),
        "unique_entity_accession_count": len({r["entity_accession"] for r in items if r["entity_accession"]}),
        "missing_accession_count": sum(1 for r in items if not r["entity_accession"]),
        "severity": "warning" if any(not r["entity_accession"] for r in items) else "report_only",
    } for typ, items in sorted(by_entity.items())]

    rows["relation_closure_qc"] = build_relation_closure_qc(snapshot, rows["relation_index"])

    missing_qc = []
    for table in ["run_core", "experiment_core", "sample_core", "study_core"]:
        if not rows[table]:
            continue
        for field in rows[table][0].keys():
            if field in {"source_snapshot_id", "entity_record_id", "file_id"}:
                continue
            total = len(rows[table])
            missing = sum(1 for r in rows[table] if r.get(field) in (None, ""))
            missing_qc.append({
                "source_snapshot_id": snapshot,
                "table_name": table,
                "field_name": field,
                "missing_count": missing,
                "total_count": total,
                "missing_rate": missing / total if total else None,
                "severity": "report_only",
            })
    rows["core_missingness_qc"] = missing_qc
    rows["core_conflict_qc"] = []
    rows["directory_file_consistency_qc"] = [{
        "source_snapshot_id": snapshot,
        "directory_id": row["directory_id"],
        "directory_accession": row["directory_accession"],
        "observed_xml_count": row["file_count"],
        "xml_kind_consistency_status": "report_only",
        "severity": "report_only",
    } for row in rows["directory_index"]]


def build_relation_closure_qc(snapshot: str, relation_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rel_groups = defaultdict(list)
    for rel in relation_rows:
        rel_groups[(rel["relation_type"], rel["src_type"], rel["dst_type"])].append(rel)
    qc_rel = []
    for (rel_type, src_type, dst_type), items in sorted(rel_groups.items()):
        internal = [r for r in items if r["dst_is_internal_entity"]]
        closed = [r for r in internal if r["closure_status"] == "closed"]
        rate = (len(closed) / len(internal)) if internal else None
        core = rel_type in {"RUN_TO_EXPERIMENT", "EXPERIMENT_TO_SAMPLE", "EXPERIMENT_TO_STUDY"}
        severity = "hard_fail" if core and len(internal) > 0 and len(closed) == 0 else "report_only"
        qc_rel.append({
            "source_snapshot_id": snapshot,
            "relation_type": rel_type,
            "src_type": src_type,
            "dst_type": dst_type,
            "internal_relation_count": len(internal),
            "closed_count": len(closed),
            "closure_rate": rate,
            "severity": severity,
        })
    return qc_rel


def write_failed_chunks(path: Path, failures: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["chunk_id", "start_row", "row_count", "exit_code", "error_type", "log_path", "retry_count"], delimiter="\t")
        writer.writeheader()
        writer.writerows(failures)


def process_chunk_job(job: dict[str, Any]) -> dict[str, Any]:
    contract = job["contract"]
    output_root = Path(job["output_root"])
    chunk = job["chunk"]
    chunk_dirs = job["chunk_dirs"]
    snapshot = job["source_snapshot_id"]
    parser_version = job["parser_version"]
    schema_version = job["schema_version"]
    manifest_hash = job["manifest_hash"]
    chunk_id = chunk["chunk_id"]
    running = output_root / "tmp" / f"{chunk_id}.running.{os.getpid()}"
    done = output_root / "chunks" / f"{chunk_id}.done"
    chunk_started = utc_now()
    try:
        if running.exists():
            shutil.rmtree(running)
        if done.exists():
            shutil.rmtree(done)
        running.mkdir(parents=True)
        chunk_rows = empty_row_store(contract)
        parsed_rows = parse_chunk(chunk_dirs, snapshot, contract)
        for key, val in parsed_rows.items():
            if key not in {"build_manifest", "directory_manifest", "chunk_manifest", "chunk_status_summary"}:
                chunk_rows[key] = val
        chunk_rows["directory_manifest"] = chunk_dirs
        chunk_rows["chunk_manifest"] = [chunk]
        row_counts = write_all_tables(contract, running, chunk_rows)
        chunk_finished = utc_now()
        status = {
            "chunk_id": chunk_id,
            "start_row": chunk["start_row"],
            "row_count": chunk["row_count"],
            "started_at": chunk_started.isoformat() + "Z",
            "finished_at": chunk_finished.isoformat() + "Z",
            "exit_code": 0,
            "parser_version": parser_version,
            "schema_version": schema_version,
            "input_manifest_hash": manifest_hash,
            "output_tables": sorted(contract["tables"].keys()),
            "row_counts_by_table": row_counts,
            "warning_count": sum(row.get("parser_warning_count", 0) for row in chunk_rows["file_index"]),
            "error_count": sum(1 for row in chunk_rows["file_index"] if row.get("parse_status") != "ok"),
        }
        (running / "chunk_status.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
        running.rename(done)
        return {"ok": True, "done_root": str(done), "status": status, "row_counts": row_counts}
    except Exception as exc:
        chunk_finished = utc_now()
        status = {
            "chunk_id": chunk_id,
            "start_row": chunk["start_row"],
            "row_count": chunk["row_count"],
            "started_at": chunk_started.isoformat() + "Z",
            "finished_at": chunk_finished.isoformat() + "Z",
            "exit_code": 1,
            "parser_version": parser_version,
            "schema_version": schema_version,
            "input_manifest_hash": manifest_hash,
            "output_tables": [],
            "row_counts_by_table": {},
            "warning_count": 0,
            "error_count": 1,
            "error_type": type(exc).__name__,
            "error_message": repr(exc),
        }
        try:
            running.mkdir(parents=True, exist_ok=True)
            (running / "chunk_status.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception as status_exc:
            status["status_write_error"] = repr(status_exc)
        return {"ok": False, "status": status, "row_counts": {}, "error_type": type(exc).__name__, "error_message": repr(exc)}


def chunk_status_summary_row(status: dict[str, Any]) -> dict[str, Any]:
    return {
        "chunk_id": status["chunk_id"],
        "start_row": status["start_row"],
        "row_count": status["row_count"],
        "started_at": datetime.fromisoformat(status["started_at"].rstrip("Z")),
        "finished_at": datetime.fromisoformat(status["finished_at"].rstrip("Z")),
        "exit_code": status["exit_code"],
        "parser_version": status["parser_version"],
        "schema_version": status["schema_version"],
        "input_manifest_hash": status["input_manifest_hash"],
        "output_tables": json.dumps(status["output_tables"], sort_keys=True),
        "row_counts_by_table": json.dumps(status["row_counts_by_table"], sort_keys=True),
        "warning_count": status["warning_count"],
        "error_count": status["error_count"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the v1 targeted fixture output for the SRA XML light index.")
    parser.add_argument("--xml-root", type=Path, default=Path("/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516"))
    parser.add_argument("--output-root", type=Path, default=Path("/data3/shared/sra_xml_index/builds/20260516/targeted_fixture_v1"))
    parser.add_argument("--fixture", type=Path, default=Path(__file__).resolve().parents[1] / "fixtures" / "targeted_dirs.tsv")
    parser.add_argument("--schema", type=Path, default=Path(__file__).resolve().parents[1] / "schema" / "v1" / "schema.json")
    parser.add_argument("--source-snapshot-id", default="20260516")
    parser.add_argument("--build-scope", default="fixture", choices=["fixture", "smoke", "pilot", "stress", "full"])
    parser.add_argument("--build-label", default="targeted_fixture_v1")
    parser.add_argument("--manifest-subset-type", default="targeted", choices=["targeted", "deterministic_random", "prefix_stratified", "stress_mixed", "full"])
    parser.add_argument("--sample-size", type=int, default=0)
    parser.add_argument("--seed", type=int, default=20260608)
    parser.add_argument("--chunk-size", type=int, default=1000)
    parser.add_argument("--schema-version", default="v1")
    parser.add_argument("--parser-version", default=PARSER_VERSION)
    parser.add_argument("--threads", type=int, default=64)
    parser.add_argument("--stage", default="chunks", choices=["chunks", "all"], help="chunks writes only resumable chunk outputs; all also invokes the finalizer.")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    if args.output_root.exists() and args.overwrite:
        shutil.rmtree(args.output_root)
    args.output_root.mkdir(parents=True, exist_ok=True)
    for name in ["tmp", "chunks", "final", "logs", "manifest"]:
        (args.output_root / name).mkdir(parents=True, exist_ok=True)

    total_t0 = time.time()
    timings: dict[str, float] = {}
    contract = load_contract(args.schema)
    started = utc_now()
    git_commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[3], text=True, capture_output=True, check=False).stdout.strip() or "unknown"
    manifest_t0 = time.time()
    accessions = select_manifest_accessions(args)
    missing = [acc for acc in accessions if not (args.xml_root / acc).is_dir()]
    if missing:
        raise SystemExit(f"fixture directories not found: {missing}")

    directory_manifest = make_directory_manifest(args.xml_root, accessions, args.source_snapshot_id)
    chunk_manifest = make_chunk_manifest(directory_manifest, args.chunk_size)
    timings["manifest_seconds"] = time.time() - manifest_t0
    rows = empty_row_store(contract)
    rows["directory_manifest"] = directory_manifest
    rows["chunk_manifest"] = chunk_manifest
    schema_hash = digest_file(args.schema)
    manifest_hash = digest_text(json.dumps(directory_manifest, sort_keys=True))
    chunk_manifest_hash = digest_text(json.dumps(chunk_manifest, sort_keys=True))
    parser_config_hash = digest_text(json.dumps({
        "source_snapshot_id": args.source_snapshot_id,
        "schema_version": args.schema_version,
        "parser_version": args.parser_version,
        "enable_selected_field_long": False,
        "fixture": str(args.fixture),
        "build_scope": args.build_scope,
        "build_label": args.build_label,
        "manifest_subset_type": args.manifest_subset_type,
        "sample_size": args.sample_size,
        "seed": args.seed,
        "chunk_size": args.chunk_size,
        "threads": args.threads,
    }, sort_keys=True))

    def build_manifest(status: str, finished: datetime | None) -> list[dict[str, Any]]:
        return [{
            "source_snapshot_id": args.source_snapshot_id,
            "build_scope": args.build_scope,
            "build_label": args.build_label,
            "manifest_subset_type": args.manifest_subset_type,
            "manifest_row_count": len(directory_manifest),
            "source_root": str(args.xml_root),
            "output_root": str(args.output_root),
            "schema_version": args.schema_version,
            "parser_version": args.parser_version,
            "parser_git_commit": git_commit,
            "build_status": status,
            "started_at": started,
            "finished_at": finished,
            "thread_count": args.threads,
            "enable_selected_field_long": False,
            "manifest_hash": manifest_hash,
            "chunk_manifest_hash": chunk_manifest_hash,
            "schema_contract_hash": schema_hash,
            "parser_config_hash": parser_config_hash,
        }]

    rows["build_manifest"] = build_manifest("running", None)
    write_table(contract, args.output_root, "build_manifest", rows["build_manifest"])
    failures: list[dict[str, Any]] = []
    status_rows: list[dict[str, Any]] = []
    write_failed_chunks(args.output_root / "failed_chunks.tsv", failures)
    try:
        chunk_t0 = time.time()
        done_roots: list[Path] = []
        chunk_row_counts: Counter[str] = Counter()
        jobs = [{
            "contract": contract,
            "output_root": str(args.output_root),
            "chunk": chunk,
            "chunk_dirs": directory_manifest[chunk["start_row"]:chunk["start_row"] + chunk["row_count"]],
            "source_snapshot_id": args.source_snapshot_id,
            "parser_version": args.parser_version,
            "schema_version": args.schema_version,
            "manifest_hash": manifest_hash,
        } for chunk in chunk_manifest]
        if args.threads <= 1:
            results = [process_chunk_job(job) for job in jobs]
        else:
            results = []
            with concurrent.futures.ProcessPoolExecutor(max_workers=args.threads) as executor:
                future_to_chunk = {executor.submit(process_chunk_job, job): job["chunk"] for job in jobs}
                for future in concurrent.futures.as_completed(future_to_chunk):
                    chunk = future_to_chunk[future]
                    try:
                        results.append(future.result())
                    except Exception as exc:
                        results.append({
                            "ok": False,
                            "status": {
                                "chunk_id": chunk["chunk_id"],
                                "start_row": chunk["start_row"],
                                "row_count": chunk["row_count"],
                                "started_at": utc_now().isoformat() + "Z",
                                "finished_at": utc_now().isoformat() + "Z",
                                "exit_code": 1,
                                "parser_version": args.parser_version,
                                "schema_version": args.schema_version,
                                "input_manifest_hash": manifest_hash,
                                "output_tables": [],
                                "row_counts_by_table": {},
                                "warning_count": 0,
                                "error_count": 1,
                            },
                            "row_counts": {},
                            "error_type": type(exc).__name__,
                            "error_message": repr(exc),
                        })
        results.sort(key=lambda item: item["status"]["start_row"])
        for result in results:
            status = result["status"]
            status_rows.append(chunk_status_summary_row(status))
            if not result["ok"]:
                failures.append({
                    "chunk_id": status["chunk_id"],
                    "start_row": status["start_row"],
                    "row_count": status["row_count"],
                    "exit_code": 1,
                    "error_type": result.get("error_type", "unknown"),
                    "log_path": str(args.output_root / "logs"),
                    "retry_count": 0,
                })
                continue
            row_counts = result["row_counts"]
            row_counts["chunk_status_summary"] = 0
            done_roots.append(Path(result["done_root"]))
            for table_name, count in row_counts.items():
                if table_name not in GLOBAL_TABLES:
                    chunk_row_counts[table_name] += count
        write_failed_chunks(args.output_root / "failed_chunks.tsv", failures)
        timings["chunks_seconds"] = time.time() - chunk_t0
        final_rows = empty_row_store(contract)
        final_rows["directory_manifest"] = directory_manifest
        final_rows["chunk_manifest"] = chunk_manifest
        final_rows["chunk_status_summary"] = status_rows
        for table_name in ["directory_manifest", "chunk_manifest", "chunk_status_summary"]:
            write_table(contract, args.output_root, table_name, final_rows[table_name])
        if failures:
            timings["total_seconds"] = time.time() - total_t0
            (args.output_root / "chunk_timing.json").write_text(json.dumps(timings, ensure_ascii=False, indent=2), encoding="utf-8")
            raise RuntimeError(f"{len(failures)} chunk(s) failed")
        timings["total_seconds"] = time.time() - total_t0
        (args.output_root / "chunk_timing.json").write_text(json.dumps(timings, ensure_ascii=False, indent=2), encoding="utf-8")
        if args.stage == "all":
            finalizer = Path(__file__).resolve().with_name("finalize_stress_build.py")
            subprocess.run([
                "python3",
                str(finalizer),
                "--output-root",
                str(args.output_root),
                "--schema",
                str(args.schema),
                "--source-snapshot-id",
                args.source_snapshot_id,
            ], check=True)
    except Exception as exc:
        if not failures:
            failures.append({
                "chunk_id": chunk_manifest[0]["chunk_id"] if chunk_manifest else "none",
                "start_row": chunk_manifest[0]["start_row"] if chunk_manifest else 0,
                "row_count": chunk_manifest[0]["row_count"] if chunk_manifest else 0,
                "exit_code": 1,
                "error_type": type(exc).__name__,
                "log_path": str(args.output_root / "logs"),
                "retry_count": 0,
            })
        write_failed_chunks(args.output_root / "failed_chunks.tsv", failures)
        rows["build_manifest"] = build_manifest("failed", utc_now())
        write_table(contract, args.output_root, "build_manifest", rows["build_manifest"])
        raise

    print(json.dumps({
        "output_root": str(args.output_root),
        "directories": len(directory_manifest),
        "failed_chunks": len(failures),
        "build_status": "succeeded",
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
