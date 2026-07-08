#!/usr/bin/env python3
"""第二阶段 Step 2：把 Step 1 头表与 SRA_Accessions 的 RUN visibility 连接。

流程位置：
    02_stage2_run_members_head_table / Step 2

本脚本在整个 SRA 处理流程中的职责：
    1. 输入 Step 1 生成的 member-level hard-filter 头表。
    2. 输入既有 SRA_Accessions Parquet 索引中的 Type=RUN 记录。
    3. 按 Run == SRA_Accessions.Accession 连接。
    4. 只把 SRA_Accessions.Visibility == public 作为本阶段 gate。
    5. 同时输出 member-level 表和一行一个 Run 的 run-level 表。

本脚本明确不做的事情：
    - 不重新判断 SRA_Run_Members.Status/Spots/Bases，因为这些已经在 Step 1 完成。
    - 不把 Accessions.Status 作为硬 gate；它只作为审计字段和 QC 字段。
    - 不读取 run.xml / experiment.xml / sample.xml。
    - 不做普通转录组、wildtype、untreated、normal 等生物学筛选。

输入：
    tables/sra_run_members_hard_filtered_member_level.parquet
    SRA_Accessions Type=RUN Parquet

输出：
    tables/sra_run_members_live_nonzero_public_member_level.parquet
    tables/sra_run_members_live_nonzero_public_run_level.parquet
    qc/*.tsv
    sql/join_visibility.sql
    manifest.json

安全边界：
    默认是 dry-run 计划模式；必须显式传入 --execute 才会读取输入并写结果。
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_MEMBER_HEAD = Path(
    "/data3/m252202014/SRA/filtered_tables/"
    "sra_run_members_hard_filtered_20260703/tables/"
    "sra_run_members_hard_filtered_member_level.parquet"
)
DEFAULT_ACCESSIONS_RUN = Path(
    "/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/"
    "sra_parquet/sra_accessions_by_type/Type=RUN/data_0.parquet"
)
DEFAULT_OUTDIR = Path(
    "/data3/m252202014/SRA/filtered_tables/"
    "sra_run_members_live_nonzero_public_20260703"
)

MEMBER_REQUIRED_COLUMNS = [
    "Run",
    "Member_Name",
    "Experiment",
    "Sample",
    "BioSample",
    "Study",
    "Spots",
    "Bases",
    "Status",
]

ACCESSIONS_REQUIRED_COLUMNS = [
    "Accession",
    "Status",
    "Visibility",
    "Experiment",
    "Sample",
    "Study",
    "Spots",
    "Bases",
    "BioSample",
    "BioProject",
    "Type",
]

MEMBER_PUBLIC_OUTPUT_COLUMNS = [
    "Run",
    "Member_Name",
    "Experiment",
    "Sample",
    "BioSample",
    "Study",
    "Spots",
    "Bases",
    "Status",
    "Accessions_Visibility",
    "Accessions_Status",
    "Accessions_BioProject",
    "Accessions_Experiment",
    "Accessions_Sample",
    "Accessions_Study",
    "Accessions_BioSample",
    "Accessions_Spots",
    "Accessions_Bases",
    "Accessions_Type",
]


def utc_now() -> str:
    """返回当前 UTC 时间字符串。

    流程位置：
        manifest 生成阶段。
    输入：
        无。
    输出：
        ISO 8601 格式 UTC 时间字符串。
    """
    return datetime.now(timezone.utc).isoformat()


def sql_quote(value: str | Path) -> str:
    """转义 DuckDB SQL 字符串字面量中的单引号。

    流程位置：
        所有需要把路径写入 DuckDB SQL 的阶段。
    输入：
        文件路径或普通字符串。
    输出：
        可安全放入单引号 SQL 字符串的文本。
    """
    return str(value).replace("'", "''")


def norm_expr(column: str) -> str:
    """生成字段缺失值规范化表达式。

    流程位置：
        member head 与 SRA_Accessions 读入后的规范化层。
    输入：
        DuckDB 列名，例如 Run、Accession、Visibility。
    输出：
        SQL 表达式，把空字符串、-、null/NULL/Null 统一变成 SQL NULL。

    为什么这么写：
        两个官方文件都可能用 '-' 或文本 null 表示缺失。如果不提前转成 SQL NULL，
        后续的非空判断、join QC、mismatch QC 会把占位符误认为真实 accession。
    """
    # Parquet schema may store Spots/Bases as numeric in future snapshots or tests.
    # Casting to VARCHAR before TRIM keeps the missing-value normalization reusable
    # across text and numeric columns.
    text_value = f"CAST({column} AS VARCHAR)"
    trimmed = f"TRIM({text_value})"
    return (
        "CASE "
        f"WHEN {column} IS NULL THEN NULL "
        f"WHEN LOWER({trimmed}) IN ('', '-', 'null') THEN NULL "
        f"ELSE {trimmed} "
        "END"
    )


def parquet_source(path: Path) -> str:
    """把输入路径转换成 DuckDB read_parquet 可读的 source 字符串。

    流程位置：
        执行前输入解析阶段。
    输入：
        Parquet 文件路径，或包含 parquet 文件的目录。
    输出：
        文件路径；如果输入是目录，则返回目录下递归 parquet glob。

    为什么支持目录：
        SRA_Accessions 索引有时按 Type 分区保存为目录。脚本接受文件和目录，
        可以避免为了不同索引布局维护两套命令。
    """
    if path.is_dir():
        return str(path / "**" / "*.parquet")
    return str(path)


def describe_parquet(con: Any, source: str) -> list[str]:
    """读取 Parquet schema 并返回列名列表。

    流程位置：
        --execute 后、正式建表前的输入 schema gate。
    输入：
        DuckDB 连接和 read_parquet source。
    输出：
        Parquet 中的字段名列表。
    失败条件：
        如果 parquet 不存在、glob 没匹配、或 schema 无法读取，DuckDB 会直接报错。
    """
    rows = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{sql_quote(source)}')").fetchall()
    return [row[0] for row in rows]


def validate_columns(actual: list[str], required: list[str], label: str) -> None:
    """确认输入表包含本阶段需要的字段。

    流程位置：
        输入 schema gate。
    输入：
        actual：实际字段名。
        required：必需字段名。
        label：错误消息中使用的输入表标签。
    输出：
        无返回值；字段缺失时 fail fast。
    """
    missing = [column for column in required if column not in actual]
    if missing:
        raise SystemExit(f"{label} is missing required columns: {', '.join(missing)}")


def prepare_outdir(outdir: Path, overwrite: bool) -> dict[str, Path]:
    """准备本次运行的输出目录。

    流程位置：
        写任何产物之前的安全 gate。
    输入：
        outdir：本次结果根目录。
        overwrite：是否允许替换已存在的非空目录。
    输出：
        tables/qc/sql/work 子目录路径字典。

    为什么不直接覆盖：
        这个阶段会同时写 member-level、run-level、QC、manifest。如果只覆盖部分文件，
        很容易留下旧结果并造成 lineage 混乱。因此默认拒绝非空目录；显式 overwrite
        时也先整体重命名旧目录，而不是删除。
    """
    if outdir.exists() and any(outdir.iterdir()) and not overwrite:
        raise SystemExit(f"Output directory already exists and is not empty: {outdir}. Use --overwrite to replace.")
    if outdir.exists() and any(outdir.iterdir()) and overwrite:
        backup = outdir.with_name(f"{outdir.name}.previous_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        outdir.rename(backup)

    paths = {
        "tables": outdir / "tables",
        "qc": outdir / "qc",
        "sql": outdir / "sql",
        "work": outdir / "work",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def build_member_table_sql(member_source: str) -> str:
    """生成 SQL：读取 Step 1 member-level 头表并规范化字段。

    流程位置：
        Step 2 的第一段：把 Step 1 输出变成 DuckDB 中间表 member_head。
    输入：
        member_source：Step 1 hard-filter parquet 的 read_parquet source。
    输出：
        创建 member_head 表的 SQL。

    阶段边界：
        这里只接收 Step 1 已筛过的记录，不再重复执行 live/nonzero/BioSample 非空 gate。
        这些硬条件是否成立由 Step 1 manifest 和 Step 1 QC 负责。
    """
    return f"""
DROP TABLE IF EXISTS member_head;

CREATE TABLE member_head AS
SELECT
    {norm_expr("Run")} AS Run,
    {norm_expr("Member_Name")} AS Member_Name,
    {norm_expr("Experiment")} AS Experiment,
    {norm_expr("Sample")} AS Sample,
    {norm_expr("BioSample")} AS BioSample,
    {norm_expr("Study")} AS Study,
    TRY_CAST(Spots AS BIGINT) AS Spots,
    TRY_CAST(Bases AS BIGINT) AS Bases,
    {norm_expr("Status")} AS Status
FROM read_parquet('{sql_quote(member_source)}');
"""


def build_accessions_table_sql(accessions_source: str) -> str:
    """生成 SQL：读取 SRA_Accessions 的 RUN 记录并规范化审计字段。

    流程位置：
        Step 2 的第二段：准备可以按 Accession join 的 RUN accession 表。
    输入：
        accessions_source：SRA_Accessions Type=RUN parquet 的 read_parquet source。
    输出：
        创建 acc_run_norm 表的 SQL。

    为什么仍然检查 Type=RUN：
        默认路径已经指向 Type=RUN 分区，但脚本也允许用户传目录或其他 parquet。
        这里再次保留 Type=RUN gate，可以防止误把 SAMPLE/EXPERIMENT 记录 join 进来。
    """
    return f"""
DROP TABLE IF EXISTS acc_run_norm;

CREATE TABLE acc_run_norm AS
SELECT
    {norm_expr("Accession")} AS Accession,
    {norm_expr("Status")} AS Accessions_Status,
    {norm_expr("Visibility")} AS Accessions_Visibility,
    {norm_expr("Experiment")} AS Accessions_Experiment,
    {norm_expr("Sample")} AS Accessions_Sample,
    {norm_expr("Study")} AS Accessions_Study,
    TRY_CAST({norm_expr("Spots")} AS BIGINT) AS Accessions_Spots,
    TRY_CAST({norm_expr("Bases")} AS BIGINT) AS Accessions_Bases,
    {norm_expr("BioSample")} AS Accessions_BioSample,
    {norm_expr("BioProject")} AS Accessions_BioProject,
    {norm_expr("Type")} AS Accessions_Type
FROM read_parquet('{sql_quote(accessions_source)}')
WHERE {norm_expr("Type")} = 'RUN';
"""


def build_join_views_sql() -> str:
    """生成 SQL：建立 all-join、public member-level、public run-level 三个视图。

    流程位置：
        Step 2 的核心 join 和输出视图阶段。
    输入：
        无显式参数；使用 member_head 和 acc_run_norm 两张中间表。
    输出：
        创建视图的 SQL 文本。

    关键设计：
        - 先 LEFT JOIN，保留缺失 accession 和非 public 情况用于 QC。
        - 再从 join_all 中筛 Visibility=public，形成本阶段主输出。
        - member-level 不 distinct Run，保留 pooled/multi-member 结构。
        - run-level 只在第二张输出表中聚合，用于后续下载和 XML 扫描入口。
    """
    member_columns = ",\n    ".join(MEMBER_PUBLIC_OUTPUT_COLUMNS)
    return f"""
DROP VIEW IF EXISTS rm_accessions_join_all;
DROP VIEW IF EXISTS rm_live_nonzero_public_member;
DROP VIEW IF EXISTS rm_live_nonzero_public_run;

CREATE VIEW rm_accessions_join_all AS
SELECT
    m.Run,
    m.Member_Name,
    m.Experiment,
    m.Sample,
    m.BioSample,
    m.Study,
    m.Spots,
    m.Bases,
    m.Status,
    a.Accession AS Accessions_Run,
    a.Accessions_Visibility,
    a.Accessions_Status,
    a.Accessions_BioProject,
    a.Accessions_Experiment,
    a.Accessions_Sample,
    a.Accessions_Study,
    a.Accessions_BioSample,
    a.Accessions_Spots,
    a.Accessions_Bases,
    a.Accessions_Type
FROM member_head AS m
LEFT JOIN acc_run_norm AS a
    ON m.Run = a.Accession;

-- 本阶段唯一新增硬 gate：SRA_Accessions.Visibility 必须严格等于 public。
-- Accessions.Status 保留为审计字段，不参与筛选，避免和 Step 1 的 Status gate 混层。
CREATE VIEW rm_live_nonzero_public_member AS
SELECT
    {member_columns}
FROM rm_accessions_join_all
WHERE COALESCE(Accessions_Visibility = 'public', FALSE);

CREATE VIEW rm_live_nonzero_public_run AS
SELECT
    Run,
    COUNT(*) AS member_rows,
    COUNT(DISTINCT Member_Name) AS member_name_count,
    COUNT(DISTINCT Experiment) AS experiment_count,
    COUNT(DISTINCT Sample) AS sample_count,
    COUNT(DISTINCT BioSample) AS biosample_count,
    COUNT(DISTINCT Study) AS study_count,
    COUNT(*) > 1 AS is_multi_member,
    COUNT(DISTINCT Sample) > 1 AS has_multiple_samples,
    COUNT(DISTINCT BioSample) > 1 AS has_multiple_biosamples,
    string_agg(DISTINCT Member_Name, ';' ORDER BY Member_Name) FILTER (WHERE Member_Name IS NOT NULL) AS Member_Name_Set,
    string_agg(DISTINCT Experiment, ';' ORDER BY Experiment) FILTER (WHERE Experiment IS NOT NULL) AS Experiment_Set,
    string_agg(DISTINCT Sample, ';' ORDER BY Sample) FILTER (WHERE Sample IS NOT NULL) AS Sample_Set,
    string_agg(DISTINCT BioSample, ';' ORDER BY BioSample) FILTER (WHERE BioSample IS NOT NULL) AS BioSample_Set,
    string_agg(DISTINCT Study, ';' ORDER BY Study) FILTER (WHERE Study IS NOT NULL) AS Study_Set,
    MIN(Spots) AS RunMembers_Spots_Min,
    MAX(Spots) AS RunMembers_Spots_Max,
    MIN(Bases) AS RunMembers_Bases_Min,
    MAX(Bases) AS RunMembers_Bases_Max,
    MAX(Accessions_Visibility) AS Accessions_Visibility,
    MAX(Accessions_Status) AS Accessions_Status,
    MAX(Accessions_BioProject) AS Accessions_BioProject,
    MAX(Accessions_BioSample) AS Accessions_BioSample,
    MAX(Accessions_Spots) AS Accessions_Spots,
    MAX(Accessions_Bases) AS Accessions_Bases
FROM rm_live_nonzero_public_member
GROUP BY Run;
"""


def build_full_sql(member_source: str, accessions_source: str) -> str:
    """生成完整 Step 2 SQL bundle。

    流程位置：
        sql/join_visibility.sql 追踪文件生成。
    输入：
        member_source：Step 1 parquet source。
        accessions_source：SRA_Accessions RUN parquet source。
    输出：
        包含中间表、join 视图、输出视图的完整 SQL 文本。
    """
    return (
        build_member_table_sql(member_source)
        + "\n"
        + build_accessions_table_sql(accessions_source)
        + "\n"
        + build_join_views_sql()
    )


def fetch_dicts(con: Any, sql: str) -> list[dict[str, Any]]:
    """执行查询并返回字典列表。

    流程位置：
        QC 和 manifest 辅助统计阶段。
    输入：
        con：DuckDB 连接。
        sql：返回小型结果集的查询。
    输出：
        每行一个 dict，key 为列名。
    """
    result = con.execute(sql)
    columns = [description[0] for description in result.description]
    return [dict(zip(columns, row)) for row in result.fetchall()]


def fetch_one(con: Any, sql: str) -> dict[str, Any]:
    """执行预期只返回一行的查询。

    流程位置：
        duplicate accession gate 和 manifest 统计。
    输入：
        con：DuckDB 连接。
        sql：预期单行查询。
    输出：
        单行结果 dict。
    失败条件：
        如果返回行数不是 1，说明 QC SQL 与调用方预期不一致，直接报错。
    """
    rows = fetch_dicts(con, sql)
    if len(rows) != 1:
        raise RuntimeError(f"Expected one row, got {len(rows)} for SQL:\n{sql}")
    return rows[0]


def write_tsv(path: Path, rows: list[dict[str, Any]]) -> None:
    """把小型 QC 结果写成 TSV。

    流程位置：
        QC 输出阶段。
    输入：
        path：目标 TSV 路径。
        rows：字典列表。
    输出：
        UTF-8 TSV 文件。
    注意：
        这个函数只用于 QC 小表；主数据表由 DuckDB COPY 直接写 Parquet/TSV.GZ。
    """
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def check_accession_uniqueness(con: Any, allow_duplicate_accessions: bool) -> list[dict[str, Any]]:
    """检查 SRA_Accessions RUN accession 是否会放大本阶段 join。

    流程位置：
        join 之前的 cardinality safety gate。
    输入：
        con：已经创建 acc_run_norm 后的 DuckDB 连接。
        allow_duplicate_accessions：是否允许重复 accession 继续运行。
    输出：
        accession 唯一性统计。包括全局 Type=RUN 范围，以及与 member_head 相交的范围。

    为什么这是硬 gate：
        真正会造成 join 放大的，不是 Accessions 全表任意 RUN key 重复，
        而是重复 key 恰好与 Step 1 member_head.Run 相交。全局重复仍记录进 QC，
        但只有相交重复默认阻断运行。
    """
    stats = fetch_dicts(
        con,
        """
        SELECT
            'global_accessions_run' AS scope,
            COUNT(*) AS accessions_run_rows,
            COUNT(DISTINCT Accession) AS accessions_run_distinct_accessions,
            COUNT(*) - COUNT(DISTINCT Accession) AS duplicate_accession_rows,
            SUM(CASE WHEN Accession IS NULL THEN 1 ELSE 0 END) AS missing_accession_rows
        FROM acc_run_norm
        UNION ALL
        SELECT
            'matched_member_runs' AS scope,
            COUNT(*) AS accessions_run_rows,
            COUNT(DISTINCT Accession) AS accessions_run_distinct_accessions,
            COUNT(*) - COUNT(DISTINCT Accession) AS duplicate_accession_rows,
            SUM(CASE WHEN Accession IS NULL THEN 1 ELSE 0 END) AS missing_accession_rows
        FROM acc_run_norm AS a
        INNER JOIN (SELECT DISTINCT Run FROM member_head) AS m
            ON a.Accession = m.Run
        ORDER BY scope
        """,
    )
    global_stats = next(row for row in stats if row["scope"] == "global_accessions_run")
    matched_stats = next(row for row in stats if row["scope"] == "matched_member_runs")
    if global_stats["missing_accession_rows"]:
        raise SystemExit(
            f"SRA_Accessions RUN table has missing Accession rows: {global_stats['missing_accession_rows']}"
        )
    if matched_stats["duplicate_accession_rows"] and not allow_duplicate_accessions:
        examples = fetch_dicts(
            con,
            """
            SELECT Accession, COUNT(*) AS rows
            FROM acc_run_norm AS a
            INNER JOIN (SELECT DISTINCT Run FROM member_head) AS m
                ON a.Accession = m.Run
            GROUP BY Accession
            HAVING COUNT(*) > 1
            ORDER BY rows DESC, Accession
            LIMIT 20
            """,
        )
        raise SystemExit(
            "SRA_Accessions RUN table has duplicate Accession keys that match member_head.Run. "
            "Refusing to join because matched member rows would be duplicated. "
            f"Examples: {examples}"
        )
    return stats


def write_sql_bundle(paths: dict[str, Path], sql_text: str) -> Path:
    """写出本阶段 SQL bundle。

    流程位置：
        正式执行前的可追溯性记录。
    输入：
        paths：输出目录字典。
        sql_text：完整 SQL。
    输出：
        sql/join_visibility.sql 路径。
    """
    sql_path = paths["sql"] / "join_visibility.sql"
    sql_path.write_text(sql_text, encoding="utf-8")
    return sql_path


def write_outputs(con: Any, paths: dict[str, Path], write_tsv_gz: bool) -> dict[str, str | None]:
    """写出 member-level 和 run-level 主表。

    流程位置：
        Step 2 主结果输出阶段。
    输入：
        con：已建立输出视图的 DuckDB 连接。
        paths：输出目录字典。
        write_tsv_gz：是否额外输出压缩 TSV。
    输出：
        各主表路径字典。

    为什么同时输出两种粒度：
        member-level 保留 pooled/multi-member 结构，适合审计和后续 sample set 解析；
        run-level 一行一个 Run，适合后续下载候选列表和大规模 XML 字段查询入口。
    """
    member_parquet = paths["tables"] / "sra_run_members_live_nonzero_public_member_level.parquet"
    run_parquet = paths["tables"] / "sra_run_members_live_nonzero_public_run_level.parquet"
    con.execute(
        f"COPY (SELECT * FROM rm_live_nonzero_public_member) "
        f"TO '{sql_quote(member_parquet)}' (FORMAT PARQUET)"
    )
    con.execute(
        f"COPY (SELECT * FROM rm_live_nonzero_public_run) "
        f"TO '{sql_quote(run_parquet)}' (FORMAT PARQUET)"
    )

    outputs: dict[str, str | None] = {
        "member_level_parquet": str(member_parquet),
        "run_level_parquet": str(run_parquet),
        "member_level_tsv_gz": None,
        "run_level_tsv_gz": None,
    }
    if write_tsv_gz:
        member_tsv = paths["tables"] / "sra_run_members_live_nonzero_public_member_level.tsv.gz"
        run_tsv = paths["tables"] / "sra_run_members_live_nonzero_public_run_level.tsv.gz"
        con.execute(
            f"COPY (SELECT * FROM rm_live_nonzero_public_member) "
            f"TO '{sql_quote(member_tsv)}' (FORMAT CSV, DELIMITER '\t', HEADER, COMPRESSION GZIP)"
        )
        con.execute(
            f"COPY (SELECT * FROM rm_live_nonzero_public_run) "
            f"TO '{sql_quote(run_tsv)}' (FORMAT CSV, DELIMITER '\t', HEADER, COMPRESSION GZIP)"
        )
        outputs["member_level_tsv_gz"] = str(member_tsv)
        outputs["run_level_tsv_gz"] = str(run_tsv)
    return outputs


def build_field_difference_qc_sql() -> str:
    """生成字段差异 QC SQL。

    流程位置：
        compute_qc() 内部的官方来源字段一致性审计。
    输入：
        无显式参数；使用 rm_accessions_join_all 视图。
    输出：
        每个字段一行的 SQL 查询文本。

    为什么不只统计两边都非空且不相等：
        对后续解释来说，一边有值、一边缺失也是官方来源差异。这里限定
        Accessions_Run IS NOT NULL，避免把“整个 accession 没匹配到”重复算进字段差异；
        整体缺失 accession 已经由 filter_funnel 单独解释。
    """
    pairs = [
        ("Status", "Status", "Accessions_Status"),
        ("Experiment", "Experiment", "Accessions_Experiment"),
        ("Sample", "Sample", "Accessions_Sample"),
        ("Study", "Study", "Accessions_Study"),
        ("BioSample", "BioSample", "Accessions_BioSample"),
        ("Spots", "Spots", "Accessions_Spots"),
        ("Bases", "Bases", "Accessions_Bases"),
    ]
    selects = []
    for field, left, right in pairs:
        unequal = f"{left} IS NOT NULL AND {right} IS NOT NULL AND {left} <> {right}"
        left_missing = f"{left} IS NULL AND {right} IS NOT NULL"
        right_missing = f"{left} IS NOT NULL AND {right} IS NULL"
        any_difference = f"({unequal}) OR ({left_missing}) OR ({right_missing})"
        selects.append(
            f"""
            SELECT
                '{field}' AS field,
                SUM(CASE WHEN {unequal} THEN 1 ELSE 0 END) AS unequal_rows,
                SUM(CASE WHEN {left_missing} THEN 1 ELSE 0 END) AS member_missing_accessions_present_rows,
                SUM(CASE WHEN {right_missing} THEN 1 ELSE 0 END) AS member_present_accessions_missing_rows,
                SUM(CASE WHEN {any_difference} THEN 1 ELSE 0 END) AS any_difference_rows,
                COUNT(DISTINCT CASE WHEN {any_difference} THEN Run END) AS any_difference_distinct_runs
            FROM rm_accessions_join_all
            WHERE Accessions_Run IS NOT NULL
            """
        )
    return "\nUNION ALL\n".join(selects) + "\nORDER BY field"


def compute_qc(con: Any, accession_key_stats: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """计算 Step 2 的 QC 小表。

    流程位置：
        主表写出前后均可执行的审计统计阶段。
    输入：
        con：已建立中间表和输出视图的 DuckDB 连接。
        accession_key_stats：Accessions RUN key 唯一性统计，包含全局和相交范围。
    输出：
        多个 QC 表的字典。

    QC 设计：
        - filter_funnel 说明 Step 1 头表经过 Visibility gate 后保留/排除多少。
        - visibility/status counts 说明 Accessions 侧的状态分布。
        - field_mismatch_counts 不作为 gate，只暴露两个官方来源之间的字段差异。
        - run_level_summary 说明 run-level 聚合后的 multi-member 结构。
    """
    filter_funnel = fetch_dicts(
        con,
        """
        SELECT 'member_input' AS metric, COUNT(*) AS rows, COUNT(DISTINCT Run) AS distinct_runs
        FROM member_head
        UNION ALL
        SELECT 'accessions_matched', COUNT(*) AS rows, COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_accessions_join_all
        WHERE Accessions_Run IS NOT NULL
        UNION ALL
        SELECT 'visibility_public', COUNT(*) AS rows, COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_accessions_join_all
        WHERE COALESCE(Accessions_Visibility = 'public', FALSE)
        UNION ALL
        SELECT 'visibility_not_public_or_missing', COUNT(*) AS rows, COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_accessions_join_all
        WHERE NOT COALESCE(Accessions_Visibility = 'public', FALSE)
        UNION ALL
        SELECT 'missing_accession', COUNT(*) AS rows, COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_accessions_join_all
        WHERE Accessions_Run IS NULL
        """,
    )

    accessions_key_qc = accession_key_stats

    accessions_visibility_counts = fetch_dicts(
        con,
        """
        SELECT
            CASE
                WHEN Accessions_Run IS NULL THEN '__missing_accession__'
                WHEN Accessions_Visibility IS NULL THEN '__matched_visibility_missing__'
                ELSE Accessions_Visibility
            END AS visibility,
            COUNT(*) AS rows,
            COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_accessions_join_all
        GROUP BY visibility
        ORDER BY rows DESC, visibility
        """,
    )

    accessions_status_counts_public = fetch_dicts(
        con,
        """
        SELECT
            COALESCE(Accessions_Status, '__missing__') AS accessions_status,
            COUNT(*) AS rows,
            COUNT(DISTINCT Run) AS distinct_runs
        FROM rm_live_nonzero_public_member
        GROUP BY accessions_status
        ORDER BY rows DESC, accessions_status
        """,
    )

    field_mismatch_counts = fetch_dicts(con, build_field_difference_qc_sql())

    public_field_completeness = fetch_dicts(
        con,
        """
        SELECT 'Run' AS field, COUNT(Run) AS present_rows, COUNT(*) - COUNT(Run) AS missing_rows
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Experiment', COUNT(Experiment), COUNT(*) - COUNT(Experiment)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Sample', COUNT(Sample), COUNT(*) - COUNT(Sample)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'BioSample', COUNT(BioSample), COUNT(*) - COUNT(BioSample)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Visibility', COUNT(Accessions_Visibility), COUNT(*) - COUNT(Accessions_Visibility)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Status', COUNT(Accessions_Status), COUNT(*) - COUNT(Accessions_Status)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_BioProject', COUNT(Accessions_BioProject), COUNT(*) - COUNT(Accessions_BioProject)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Experiment', COUNT(Accessions_Experiment), COUNT(*) - COUNT(Accessions_Experiment)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Sample', COUNT(Accessions_Sample), COUNT(*) - COUNT(Accessions_Sample)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_BioSample', COUNT(Accessions_BioSample), COUNT(*) - COUNT(Accessions_BioSample)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Spots', COUNT(Accessions_Spots), COUNT(*) - COUNT(Accessions_Spots)
        FROM rm_live_nonzero_public_member
        UNION ALL
        SELECT 'Accessions_Bases', COUNT(Accessions_Bases), COUNT(*) - COUNT(Accessions_Bases)
        FROM rm_live_nonzero_public_member
        """,
    )

    run_level_summary = fetch_dicts(
        con,
        """
        SELECT
            COUNT(*) AS public_distinct_runs,
            SUM(member_rows) AS public_member_rows,
            SUM(CASE WHEN member_rows = 1 THEN 1 ELSE 0 END) AS one_row_runs,
            SUM(CASE WHEN member_rows > 1 THEN 1 ELSE 0 END) AS multi_row_runs,
            MAX(member_rows) AS max_member_rows,
            SUM(CASE WHEN has_multiple_samples THEN 1 ELSE 0 END) AS runs_with_multiple_samples,
            SUM(CASE WHEN has_multiple_biosamples THEN 1 ELSE 0 END) AS runs_with_multiple_biosamples,
            SUM(CASE WHEN COALESCE(Accessions_Status = 'live', FALSE) THEN 0 ELSE 1 END)
                AS runs_with_accessions_status_not_live_or_missing
        FROM rm_live_nonzero_public_run
        """,
    )

    return {
        "filter_funnel": filter_funnel,
        "accessions_key_qc": accessions_key_qc,
        "accessions_visibility_counts": accessions_visibility_counts,
        "accessions_status_counts_public": accessions_status_counts_public,
        "field_mismatch_counts": field_mismatch_counts,
        "public_field_completeness": public_field_completeness,
        "run_level_summary": run_level_summary,
    }


def write_qc(paths: dict[str, Path], qc: dict[str, list[dict[str, Any]]]) -> dict[str, str]:
    """写出所有 QC TSV。

    流程位置：
        QC 落盘阶段。
    输入：
        paths：输出目录字典。
        qc：compute_qc() 返回的多个 QC 表。
    输出：
        QC 名称到文件路径的字典。
    """
    written: dict[str, str] = {}
    for name, rows in qc.items():
        path = paths["qc"] / f"{name}.tsv"
        write_tsv(path, rows)
        written[name] = str(path)
    return written


def build_manifest(
    member_head: Path,
    member_source: str,
    accessions_run: Path,
    accessions_source: str,
    outdir: Path,
    member_columns: list[str],
    accessions_columns: list[str],
    outputs: dict[str, str | None],
    qc_files: dict[str, str],
    sql_path: Path,
    write_tsv_gz: bool,
) -> dict[str, Any]:
    """生成 manifest.json 内容。

    流程位置：
        本阶段最后的 lineage 记录。
    输入：
        输入路径、schema、输出路径、QC 路径和运行参数。
    输出：
        可 JSON 序列化的 manifest 字典。
    """
    return {
        "generated_at_utc": utc_now(),
        "stage": "02_stage2_run_members_head_table.step2_join_accessions_visibility",
        "inputs": {
            "member_head": {
                "path": str(member_head),
                "duckdb_source": member_source,
                "columns": member_columns,
            },
            "accessions_run": {
                "path": str(accessions_run),
                "duckdb_source": accessions_source,
                "columns": accessions_columns,
            },
        },
        "join": {
            "left_key": "member_head.Run",
            "right_key": "SRA_Accessions.Accession",
            "right_type_gate": "SRA_Accessions.Type = 'RUN'",
        },
        "filter_conditions": {
            "Accessions_Visibility": "trim(Visibility) = 'public'",
            "Accessions_Status": "audit only; not used as a gate in this step",
        },
        "outputs": outputs,
        "qc_files": qc_files,
        "sql": str(sql_path),
        "outdir": str(outdir),
        "write_tsv_gz": write_tsv_gz,
        "notes": [
            "This step starts from Step 1 hard-filtered SRA_Run_Members member-level output.",
            "The only new hard gate is SRA_Accessions.Visibility = public.",
            "Accessions.Status and other Accessions fields are emitted for audit/QC but are not used as hard filters.",
            "XML field lookup and biological sample/wildtype interpretation are intentionally out of scope.",
        ],
    }


def print_plan(args: argparse.Namespace) -> None:
    """打印 dry-run 计划。

    流程位置：
        默认执行路径；未传 --execute 时只展示计划，不读大表。
    输入：
        命令行参数。
    输出：
        JSON 计划到 stdout。
    """
    payload = {
        "execute": False,
        "message": "Dry plan only. Re-run with --execute to join inputs and write outputs.",
        "member_head": str(args.member_head),
        "accessions_run": str(args.accessions_run),
        "outdir": str(args.outdir),
        "write_tsv_gz": args.write_tsv_gz,
        "overwrite": args.overwrite,
        "gate": "SRA_Accessions.Visibility = public",
        "planned_outputs": [
            str(args.outdir / "tables" / "sra_run_members_live_nonzero_public_member_level.parquet"),
            str(args.outdir / "tables" / "sra_run_members_live_nonzero_public_run_level.parquet"),
            str(args.outdir / "qc" / "filter_funnel.tsv"),
            str(args.outdir / "qc" / "accessions_key_qc.tsv"),
            str(args.outdir / "qc" / "accessions_visibility_counts.tsv"),
            str(args.outdir / "qc" / "accessions_status_counts_public.tsv"),
            str(args.outdir / "qc" / "field_mismatch_counts.tsv"),
            str(args.outdir / "qc" / "public_field_completeness.tsv"),
            str(args.outdir / "qc" / "run_level_summary.tsv"),
            str(args.outdir / "manifest.json"),
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def run(args: argparse.Namespace) -> None:
    """执行 Step 2 主流程。

    流程位置：
        CLI 入口之后的总控函数。
    输入：
        argparse 解析后的参数。
    输出：
        dry-run 时打印计划；execute 时写出表、QC、SQL 和 manifest。
    """
    if not args.execute:
        print_plan(args)
        return

    import duckdb

    member_source = parquet_source(args.member_head)
    accessions_source = parquet_source(args.accessions_run)

    con = duckdb.connect()
    member_columns = describe_parquet(con, member_source)
    accessions_columns = describe_parquet(con, accessions_source)
    validate_columns(member_columns, MEMBER_REQUIRED_COLUMNS, "member head input")
    validate_columns(accessions_columns, ACCESSIONS_REQUIRED_COLUMNS, "SRA_Accessions RUN input")
    con.close()

    paths = prepare_outdir(args.outdir, args.overwrite)
    db_path = paths["work"] / "sra_run_members_join_accessions_visibility.duckdb"
    con = duckdb.connect(str(db_path))
    try:
        sql_text = build_full_sql(member_source, accessions_source)
        sql_path = write_sql_bundle(paths, sql_text)
        con.execute(build_member_table_sql(member_source))
        con.execute(build_accessions_table_sql(accessions_source))
        accession_key_stats = check_accession_uniqueness(con, args.allow_duplicate_accessions)
        con.execute(build_join_views_sql())
        qc = compute_qc(con, accession_key_stats)
        outputs = write_outputs(con, paths, args.write_tsv_gz)
        qc_files = write_qc(paths, qc)
        manifest = build_manifest(
            args.member_head,
            member_source,
            args.accessions_run,
            accessions_source,
            args.outdir,
            member_columns,
            accessions_columns,
            outputs,
            qc_files,
            sql_path,
            args.write_tsv_gz,
        )
        manifest_path = args.outdir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"status": "done", "outdir": str(args.outdir), "manifest": str(manifest_path)}, indent=2))
    finally:
        con.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    """解析命令行参数。

    流程位置：
        CLI 参数入口。
    输入：
        argv：命令行参数列表。
    输出：
        argparse.Namespace。
    """
    parser = argparse.ArgumentParser(
        description="Join Step 1 SRA_Run_Members head table with SRA_Accessions RUN visibility."
    )
    parser.add_argument(
        "--member-head",
        type=Path,
        default=DEFAULT_MEMBER_HEAD,
        help="Step 1 member-level hard-filter parquet, or directory containing parquet files.",
    )
    parser.add_argument(
        "--accessions-run",
        type=Path,
        default=DEFAULT_ACCESSIONS_RUN,
        help="SRA_Accessions Type=RUN parquet, or directory containing RUN parquet files.",
    )
    parser.add_argument(
        "--outdir",
        type=Path,
        default=DEFAULT_OUTDIR,
        help="Output directory for Step 2 tables, QC, SQL, and manifest.",
    )
    parser.add_argument(
        "--write-tsv-gz",
        action="store_true",
        help="Also write member-level and run-level outputs as .tsv.gz.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Move any existing non-empty outdir to .previous_<timestamp> before writing.",
    )
    parser.add_argument(
        "--allow-duplicate-accessions",
        action="store_true",
        help="Do not fail if SRA_Accessions has duplicate RUN Accession keys. Not recommended.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually read inputs and write outputs. Without this flag, only print a dry-run plan.",
    )
    return parser.parse_args(argv)


def main() -> None:
    """CLI 入口。"""
    run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    main()
