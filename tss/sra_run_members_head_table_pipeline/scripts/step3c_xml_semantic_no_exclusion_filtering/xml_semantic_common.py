#!/usr/bin/env python3
"""Shared XML parsing and semantic helper rules for Step 3b/Step 3c.

This module is intentionally small and dependency-light. It contains the
rules that must be identical between generic-index filtering and fixture
tests. Step 3c still detects exclusion-like terms for QC, but the caller
decides whether those terms are a hard exclusion gate.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


LIBRARY_SELECTION_ALLOWLIST = [
    "PCR",
    "RANDOM",
    "cDNA",
    "RT-PCR",
    "PolyA",
    "RANDOM PCR",
    "Oligo-dT",
    "cDNA_oligo_dT",
]
LIBRARY_SELECTION_CANONICAL = {value.casefold(): value for value in LIBRARY_SELECTION_ALLOWLIST}

A_TAGS = {
    "genotype",
    "genotype/variation",
    "phenotype",
    "host_genotype",
    "host genotype",
    "host_phenotype",
    "donor genotype",
    "donor_genotype",
    "full_genotype",
    "sample_genotype",
    "strain/genotype",
    "background genotype",
    "mouse genotype",
    "cell genotype",
    "biol_stat",
    "arrayexpress-phenotype",
    "arrayexpress-genotype",
}
B_TAGS = {
    "strain",
    "isolate",
    "cultivar",
    "ecotype",
    "breed",
    "genetic_mod",
}

WILDTYPE_EXACT_VALUES = {
    "wt",
    "wild type",
    "wild-type",
    "wildtype",
    "wild type genotype",
    "wild-type genotype",
    "wildtype genotype",
    "wild type control",
    "wild-type control",
    "wildtype control",
    "wt/wt",
}
SHORT_WT_RE = re.compile(
    r"^(?:wt|wild[ -]?type)(?:[-_\s]?(?:rep|replicate|control|ctrl)?[-_\s]?\d*)?$",
    re.IGNORECASE,
)
SHORT_LABEL_WILDTYPE_RE = re.compile(
    r"^[A-Za-z0-9_.:+/-]+(?:\s+[A-Za-z0-9_.:+/-]+){0,5}\s+"
    r"(?:WT|wt|wild[ -]?type|Wild[ -]?type|wildtype|Wildtype)$"
)
EXCLUSION_RE = re.compile(
    r"(?<![a-z0-9])mutant(?![a-z0-9])|"
    r"(?<![a-z0-9])mutation(?![a-z0-9])|"
    r"(?<![a-z0-9])knockout(?![a-z0-9])|"
    r"(?<![a-z0-9])knock-out(?![a-z0-9])|"
    r"(?<![a-z0-9])ko(?![a-z0-9])|"
    r"(?<![a-z0-9])transgenic(?![a-z0-9])|"
    r"(?<![a-z0-9])transformed(?![a-z0-9])|"
    r"(?<![a-z0-9])overexpression(?![a-z0-9])|"
    r"(?<![a-z0-9])edited(?![a-z0-9])|"
    r"(?<![a-z0-9])crispr(?![a-z0-9])|"
    r"(?<![a-z0-9])rnai(?![a-z0-9])|"
    r"(?<![a-z0-9])sirna(?![a-z0-9])|"
    r"(?<![a-z0-9])shrna(?![a-z0-9])|"
    r"(?<![a-z0-9])treated(?![a-z0-9])|"
    r"(?<![a-z0-9])disease(?![a-z0-9])|"
    r"(?<![a-z0-9])tumou?r(?![a-z0-9])|"
    r"(?<![a-z0-9])cancer(?![a-z0-9])|"
    r"(?<![a-z0-9])infection(?![a-z0-9])|"
    r"(?<![a-z0-9])stress(?![a-z0-9])|"
    r"(?<![a-z0-9])perturbation(?![a-z0-9])|"
    r"(?<![a-z0-9])mcherry(?![a-z0-9])|"
    r"(?<![a-z0-9])gfp(?![a-z0-9])|"
    r"(?<![a-z0-9])egfp(?![a-z0-9])|"
    r"(?<![a-z0-9])cre(?![a-z0-9])|"
    r"(?<![a-z0-9])ires(?![a-z0-9])|"
    r"(?<![a-z0-9])tdtomato(?![a-z0-9])|"
    r"(?<![a-z0-9])flox(?:ed)?(?![a-z0-9])|"
    r"(?<![a-z0-9])loxp(?![a-z0-9])|"
    r"(?<![a-z0-9])reporter(?![a-z0-9])|"
    r"(?<![a-z0-9])tm\d+(?![a-z0-9])",
    re.IGNORECASE,
)
EXCLUSION_TAGS = {
    "treatment",
    "stimulus",
    "disease",
    "disease state",
    "disease status",
    "infection",
    "stress",
    "perturbation",
}
BENIGN_EXCLUSION_VALUES = {
    "none",
    "no",
    "not treated",
    "untreated",
    "no treatment",
    "not applicable",
    "na",
    "n/a",
    "control",
}


@dataclass(frozen=True)
class ExperimentFields:
    library_strategy: str | None
    library_source: str | None
    library_selection: str | None
    parse_status: str


@dataclass(frozen=True)
class SampleFields:
    taxon_id: str | None
    attributes: list[tuple[str, str]]
    parse_status: str


@dataclass(frozen=True)
class WildtypeEvidence:
    has_ab_evidence: bool
    has_exclusion: bool
    evidence_levels: list[str]
    evidence_tags: list[str]
    evidence_values: list[str]


def collapse_spaces(value: str | None) -> str:
    """Normalize whitespace while preserving the literal biological value."""
    if value is None:
        return ""
    return " ".join(str(value).strip().split())


def normalize_text(value: str | None) -> str | None:
    """Return normalized text, using None for known missing-value sentinels.

    SRA metadata sometimes represents missing values as '-' or 'null'. Treating
    those as real strings would make fields such as TAXON_ID look present and
    could incorrectly pass the sample gate.
    """
    normalized = collapse_spaces(value)
    if normalized == "" or normalized == "-" or normalized.casefold() == "null":
        return None
    return normalized


def normalize_tag(value: str | None) -> str:
    """Normalize SAMPLE_ATTRIBUTE TAG names for rule lookup."""
    return collapse_spaces(value).casefold()


def local_name(tag: str) -> str:
    """Strip XML namespace from an ElementTree tag."""
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def find_entity(root: ET.Element, entity_tag: str, accession: str | None) -> ET.Element | None:
    """Find EXPERIMENT or SAMPLE by accession, with single-entity fallback."""
    entities = [element for element in root.iter() if local_name(element.tag) == entity_tag]
    if not entities:
        return None
    if accession:
        for element in entities:
            if element.attrib.get("accession") == accession:
                return element
    if len(entities) == 1:
        return entities[0]
    return None


def first_child_text(element: ET.Element, tag_name: str) -> str | None:
    """Return the first descendant text matching a local tag name."""
    for child in element.iter():
        if local_name(child.tag) == tag_name:
            return normalize_text(child.text)
    return None


def parse_xml(path: Path) -> ET.Element | None:
    """Read an XML file; callers convert missing/failed parsing into QC states."""
    try:
        return ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return None


def parse_experiment_xml(path: Path, experiment_accession: str | None) -> ExperimentFields:
    """Extract LIBRARY_STRATEGY/SOURCE/SELECTION from one experiment XML file."""
    if not path.exists():
        return ExperimentFields(None, None, None, "missing_xml")
    root = parse_xml(path)
    if root is None:
        return ExperimentFields(None, None, None, "parse_failed")
    experiment = find_entity(root, "EXPERIMENT", experiment_accession)
    if experiment is None:
        return ExperimentFields(None, None, None, "experiment_not_found")
    return ExperimentFields(
        first_child_text(experiment, "LIBRARY_STRATEGY"),
        first_child_text(experiment, "LIBRARY_SOURCE"),
        first_child_text(experiment, "LIBRARY_SELECTION"),
        "ok",
    )


def parse_sample_xml(path: Path, sample_accession: str | None) -> SampleFields:
    """Extract TAXON_ID and SAMPLE_ATTRIBUTE tag/value pairs from sample XML."""
    if not path.exists():
        return SampleFields(None, [], "missing_xml")
    root = parse_xml(path)
    if root is None:
        return SampleFields(None, [], "parse_failed")
    sample = find_entity(root, "SAMPLE", sample_accession)
    if sample is None:
        return SampleFields(None, [], "sample_not_found")

    attributes: list[tuple[str, str]] = []
    for attr in sample.iter():
        if local_name(attr.tag) != "SAMPLE_ATTRIBUTE":
            continue
        tag = first_child_text(attr, "TAG")
        value = first_child_text(attr, "VALUE")
        if tag is not None and value is not None:
            attributes.append((tag, value))
    return SampleFields(first_child_text(sample, "TAXON_ID"), attributes, "ok")


def is_strategy_rnaseq(value: str | None) -> bool:
    return value is not None and collapse_spaces(value).casefold() == "rna-seq"


def is_source_transcriptomic(value: str | None) -> bool:
    return value is not None and collapse_spaces(value).casefold() == "transcriptomic"


def is_selection_allowed(value: str | None) -> bool:
    if value is None:
        return False
    return collapse_spaces(value).casefold() in LIBRARY_SELECTION_CANONICAL


def is_explicit_wildtype_value(value: str) -> bool:
    """Accept only short, explicit WT labels instead of broad substring matches."""
    normalized = collapse_spaces(value)
    folded = normalized.casefold()
    if folded in WILDTYPE_EXACT_VALUES:
        return True
    if SHORT_WT_RE.match(normalized):
        return True
    if len(normalized) <= 80 and SHORT_LABEL_WILDTYPE_RE.match(normalized):
        return True
    return False


def has_exclusion_value(value: str) -> bool:
    """Return whether a free-text value carries mutant/treatment/risk language."""
    return bool(EXCLUSION_RE.search(collapse_spaces(value)))


def is_exclusion_attribute(tag: str, value: str) -> bool:
    """Treat exclusion-like tags as risk unless their value is explicitly benign."""
    normalized_tag = normalize_tag(tag)
    normalized_value = collapse_spaces(value).casefold()
    if has_exclusion_value(value):
        return True
    if normalized_tag in EXCLUSION_TAGS and normalized_value not in BENIGN_EXCLUSION_VALUES:
        return True
    return False


def evaluate_wildtype(attributes: list[tuple[str, str]]) -> WildtypeEvidence:
    """Evaluate strong A/B wildtype evidence and separately flag exclusion terms."""
    levels: list[str] = []
    tags: list[str] = []
    values: list[str] = []
    has_exclusion = False
    for tag, value in attributes:
        if is_exclusion_attribute(tag, value):
            has_exclusion = True
        normalized_tag = normalize_tag(tag)
        level: str | None = None
        if normalized_tag in A_TAGS:
            level = "A"
        elif normalized_tag in B_TAGS:
            level = "B"
        if level and is_explicit_wildtype_value(value):
            levels.append(level)
            tags.append(tag)
            values.append(value)
    return WildtypeEvidence(
        bool(levels),
        has_exclusion,
        unique_preserve_order(levels),
        unique_preserve_order(tags),
        unique_preserve_order(values),
    )


def unique_preserve_order(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def join_set(values: Iterable[str]) -> str:
    return ";".join(unique_preserve_order(value for value in values if value))


def xml_path(xml_root: Path, submission: str | None, kind: str) -> Path:
    """Build the canonical XML path from a Submission accession."""
    if not submission:
        return xml_root / "__missing_submission__" / f"__missing_submission__.{kind}.xml"
    return xml_root / submission / f"{submission}.{kind}.xml"
