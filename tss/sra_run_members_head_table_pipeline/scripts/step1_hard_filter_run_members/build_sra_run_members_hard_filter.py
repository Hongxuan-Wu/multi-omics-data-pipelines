#!/usr/bin/env python3
"""第二阶段 Step 1：只对 SRA_Run_Members 做自身硬筛选。

流程位置：
    02_stage2_run_members_head_table / Step 1

本脚本在整个 SRA 处理流程中的职责：
    1. 输入官方 `SRA_Run_Members` TSV。
    2. 只基于 `SRA_Run_Members` 自身字段做硬筛选。
    3. 输出 member-level 头表，作为后续 join SRA_Accessions.Visibility 的输入。

本脚本明确不做的事情：
    - 不 join `SRA_Accessions`，因此不判断 `Visibility=public`。
    - 不读取 run.xml / experiment.xml / sample.xml。
    - 不做普通转录组字段筛选。
    - 不做 wildtype / untreated / normal 判定。
    - 不把同一个 Run 提前压成一行。

输入：
    `SRA_Run_Members` TSV，至少包含：
    Run, Member_Name, Experiment, Sample, Study, Spots, Bases, Status, BioSample

输出：
    tables/sra_run_members_hard_filtered_member_level.parquet
    qc/*.tsv
    sql/hard_filter.sql
    manifest.json

安全边界：
    默认是 dry-run 计划模式；必须显式传入 --execute 才会扫描输入大文件并写结果。
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_INPUT = Path("/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516/SRA_Run_Members")
DEFAULT_OUTDIR = Path("/data3/m252202014/SRA/filtered_tables/sra_run_members_hard_filtered_20260703")

REQUIRED_INPUT_COLUMNS = [
    "Run",
    "Member_Name",
    "Experiment",
    "Sample",
    "Study",
    "Spots",
    "Bases",
    "Status",
    "BioSample",
]

OUTPUT_COLUMNS = [
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


def utc_now() -> str:
    """返回当前 UTC 时间字符串。

    流程位置：
        通用 manifest/QC 元数据生成。

    输入：
        无。

    输出：
        ISO 8601 格式 UTC 时间字符串，用于 `manifest.json` 的 `generated_at_utc`。
    """
    return datetime.now(timezone.utc).isoformat()


def sql_quote(value: str | Path) -> str:
    """对将要插入 DuckDB SQL 字符串字面量的路径做最小转义。

    流程位置：
        所有 DuckDB SQL 构造步骤。

    输入：
        文件路径或字符串。典型输入是 `SRA_Run_Members` 路径、Parquet 输出路径、
        TSV 输出路径、DuckDB temp/work 路径。

    输出：
        将单引号替换为两个单引号后的字符串，避免路径中的单引号破坏 SQL。

    注意：
        这个函数只负责 SQL 字符串字面量转义，不负责检查路径是否存在。
    """
    return str(value).replace("'", "''")


def read_header(path: Path) -> list[str]:
    """读取输入 TSV 的表头。

    流程位置：
        Step 1 执行前的输入 schema 校验。

    输入：
        `path`：`SRA_Run_Members` TSV 路径。

    输出：
        表头字段列表。

    失败条件：
        如果输入文件为空，没有任何 header 行，直接 fail fast。
        这样避免 DuckDB 后续读入时给出更难定位的错误。
    """
    with path.open("r", encoding="utf-8", newline="") as handle:
        try:
            return next(csv.reader(handle, delimiter="\t"))
        except StopIteration as exc:
            raise SystemExit(f"Input is empty and has no header: {path}") from exc


def validate_header(header: list[str]) -> None:
    """确认输入 TSV 包含 Step 1 所需的所有字段。

    流程位置：
        Step 1 执行前的输入 schema gate。

    输入：
        `header`：由 `read_header()` 读取出的字段名列表。

    输出：
        无返回值。校验通过则继续；校验失败则退出。

    校验目标：
        必须包含 `Run/Experiment/Sample/BioSample/Status/Spots/Bases` 等字段，
        否则不能保证硬筛选和输出字段含义正确。
    """
    missing = [column for column in REQUIRED_INPUT_COLUMNS if column not in header]
    if missing:
        raise SystemExit(f"Input is missing required columns: {', '.join(missing)}")


def norm_expr(column: str) -> str:
    """生成 DuckDB SQL 表达式，把字段值规范化成可筛选状态。

    流程位置：
        Step 1 的字段规范化层，在任何硬筛选之前执行。

    输入：
        `column`：DuckDB 中的原始列名，例如 `Run`、`Sample`、`Spots`。

    输出：
        SQL 表达式字符串。这个表达式会：
        - 去掉字段前后空格。
        - 把空字符串视为缺失。
        - 把 `-` 和带空格的 ` - ` 视为缺失。
        - 把 `null/NULL/Null` 视为缺失。
        - 其他值保留去空格后的文本。

    为什么需要这个函数：
        SRA 元数据里同一种“缺失”可能有不同文本写法。
        如果不先统一成 SQL NULL，`Run IS NOT NULL` 这类 gate 会把占位符误认为真实 ID。
    """
    trimmed = f"TRIM({column})"
    return (
        "CASE "
        f"WHEN {column} IS NULL THEN NULL "
        f"WHEN LOWER({trimmed}) IN ('', '-', 'null') THEN NULL "
        f"ELSE {trimmed} "
        "END"
    )


def build_normalized_table_sql(input_path: Path) -> str:
    """生成 SQL：从 SRA_Run_Members 读入并建立规范化中间表 `rm_norm`。

    流程位置：
        Step 1 的第一段：输入读取和字段规范化。

    输入：
        `input_path`：`SRA_Run_Members` TSV 路径。

    输出：
        一段 DuckDB SQL 字符串。执行后会创建 `rm_norm` 表。

    `rm_norm` 的字段含义：
        - `Run/Experiment/Sample/BioSample/Study/Member_Name/Status`：
          经过 `norm_expr()` 规范化后的文本字段。
        - `Spots/Bases`：
          经过 `TRY_CAST(... AS BIGINT)` 转成数值后的字段。

    阶段边界：
        这里只处理 SRA_Run_Members 自身字段。
        不能在这里加入 SRA_Accessions.Visibility，也不能加入 XML 字段。
    """
    return f"""
DROP TABLE IF EXISTS rm_norm;

-- Step 1 只保留 SRA_Run_Members 自身字段。
-- 这里不能混入 SRA_Accessions.Visibility，也不能混入 XML 派生字段。
CREATE TABLE rm_norm AS
SELECT
    {norm_expr("Run")} AS Run,
    {norm_expr("Member_Name")} AS Member_Name,
    {norm_expr("Experiment")} AS Experiment,
    {norm_expr("Sample")} AS Sample,
    {norm_expr("BioSample")} AS BioSample,
    {norm_expr("Study")} AS Study,
    TRY_CAST({norm_expr("Spots")} AS BIGINT) AS Spots,
    TRY_CAST({norm_expr("Bases")} AS BIGINT) AS Bases,
    {norm_expr("Status")} AS Status
FROM read_csv(
    '{sql_quote(input_path)}',
    delim='\\t',
    header=true,
    all_varchar=true,
    nullstr='-',
    sample_size=100000,
    ignore_errors=false
);
"""


FILTER_PREDICATE = """
-- COALESCE 是故意的：SQL 中 NULL 比较会得到 NULL。
-- 如果不转成 FALSE，rejected_rows 的 NOT(...) 统计会漏掉缺失字段导致的拒绝行。
COALESCE(Status = 'live', FALSE)
AND COALESCE(Spots > 0, FALSE)
AND COALESCE(Bases > 0, FALSE)
AND Run IS NOT NULL
AND Experiment IS NOT NULL
AND Sample IS NOT NULL
AND BioSample IS NOT NULL
"""


def build_filtered_view_sql() -> str:
    """生成 SQL：在规范化表上建立硬筛选 view。

    流程位置：
        Step 1 的第二段：根据硬筛选条件得到 member-level 候选头表。

    输入：
        无显式参数。使用模块级 `OUTPUT_COLUMNS` 和 `FILTER_PREDICATE`。

    输出：
        一段 DuckDB SQL 字符串。执行后会创建 `rm_hard_filtered` view。

    输出粒度：
        member-level。也就是说，同一个 Run 如果有多个 member 行，会全部保留。

    为什么不在这里 distinct Run：
        后续 wildtype 判定需要知道 RUN 关联的真实 biological sample set。
        如果这里提前压成一行，会丢掉 pooled/multi-member RUN 的样本结构。
    """
    columns = ",\n    ".join(OUTPUT_COLUMNS)
    return f"""
DROP VIEW IF EXISTS rm_hard_filtered;

-- 输出必须保持 member-level。
-- 不在这里 DISTINCT Run，因为 multi-member RUN 要留到后续样本集合解析阶段处理。
CREATE VIEW rm_hard_filtered AS
SELECT
    {columns}
FROM rm_norm
WHERE
    {FILTER_PREDICATE.strip()};
"""


def build_hard_filter_sql(input_path: Path) -> str:
    """生成完整的 Step 1 SQL 文本。

    流程位置：
        SQL 追溯文件生成。

    输入：
        `input_path`：`SRA_Run_Members` TSV 路径。

    输出：
        包含两段内容的 SQL：
        1. 创建 `rm_norm`。
        2. 创建 `rm_hard_filtered`。

    用途：
        写入 `sql/hard_filter.sql`，让本次筛选条件可以脱离 Python 代码被审计。
    """
    return build_normalized_table_sql(input_path) + "\n" + build_filtered_view_sql()


def fetch_dicts(con: Any, sql: str) -> list[dict[str, Any]]:
    """执行一段查询 SQL，并把结果转成字典列表。

    流程位置：
        QC 统计和 manifest 辅助数据生成。

    输入：
        `con`：DuckDB 连接。
        `sql`：返回表格结果的 SQL。

    输出：
        `list[dict]`，每一行用列名作为 key。

    为什么不用 DataFrame：
        这个脚本只需要写小型 QC TSV/JSON，使用 Python 标准数据结构即可，
        避免引入 pandas 之类额外依赖。
    """
    result = con.execute(sql)
    columns = [description[0] for description in result.description]
    return [dict(zip(columns, row)) for row in result.fetchall()]


def fetch_one(con: Any, sql: str) -> dict[str, Any]:
    """执行查询并要求结果必须恰好一行。

    流程位置：
        当前脚本保留的通用 QC helper。适合未来新增单行统计时使用。

    输入：
        `con`：DuckDB 连接。
        `sql`：预期只返回一行的 SQL。

    输出：
        单行结果字典。

    失败条件：
        如果返回 0 行或多于 1 行，说明 SQL 口径和调用方预期不一致，直接抛错。
    """
    rows = fetch_dicts(con, sql)
    if len(rows) != 1:
        raise RuntimeError(f"Expected one row, got {len(rows)} for SQL:\n{sql}")
    return rows[0]


def write_tsv(path: Path, rows: list[dict[str, Any]]) -> None:
    """把小型 QC 结果写成 TSV。

    流程位置：
        Step 1 的 QC 输出阶段。

    输入：
        `path`：目标 TSV 路径。
        `rows`：字典列表，通常来自 `fetch_dicts()`。

    输出：
        在磁盘写入一个 UTF-8 TSV 文件。

    注意：
        这个函数只用于小型 QC 表，不用于写主数据表。
        主数据表由 DuckDB `COPY` 直接导出为 Parquet 或 TSV.GZ。
    """
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def prepare_outdir(outdir: Path, overwrite: bool) -> dict[str, Path]:
    """准备本次运行的输出目录结构。

    流程位置：
        Step 1 执行前的输出安全 gate。

    输入：
        `outdir`：本次运行的输出根目录。
        `overwrite`：是否允许处理已有非空目录。

    输出：
        一个路径字典，包含 `tables/qc/sql/work` 四个子目录。

    安全策略：
        - 如果输出目录非空且没有 `--overwrite`，直接失败，防止覆盖旧结果。
        - 如果显式传入 `--overwrite`，不删除旧目录，而是整体重命名成
          `.previous_<timestamp>` 备份，再创建新的输出目录。

    为什么不直接清空旧目录：
        直接清空会丢失可追溯证据；只覆盖部分文件又可能让旧 TSV/QC 残留，
        造成 manifest 与实际目录不一致。
    """
    if outdir.exists() and any(outdir.iterdir()) and not overwrite:
        raise SystemExit(f"Output directory already exists and is not empty: {outdir}. Use --overwrite to replace.")
    if outdir.exists() and any(outdir.iterdir()) and overwrite:
        # 不直接清空旧目录，而是整体改名备份。
        # 这样既避免旧 TSV/QC 残留污染新 manifest，也保留回滚入口。
        backup = outdir.with_name(f"{outdir.name}.previous_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        if backup.exists():
            raise SystemExit(f"Refusing to overwrite because backup path already exists: {backup}")
        outdir.rename(backup)
    for name in ["tables", "qc", "sql", "work"]:
        (outdir / name).mkdir(parents=True, exist_ok=True)
    return {
        "tables": outdir / "tables",
        "qc": outdir / "qc",
        "sql": outdir / "sql",
        "work": outdir / "work",
    }


def write_sql_bundle(sql_dir: Path, input_path: Path) -> Path:
    """写出本次硬筛选的 SQL 复现文件。

    流程位置：
        Step 1 的可追溯性输出。

    输入：
        `sql_dir`：输出目录中的 `sql/` 子目录。
        `input_path`：本次使用的 `SRA_Run_Members` 路径。

    输出：
        `hard_filter.sql` 文件路径。

    用途：
        让后续审计者不读 Python 也能看到本次筛选的 SQL 条件。
    """
    sql_path = sql_dir / "hard_filter.sql"
    sql_path.write_text(build_hard_filter_sql(input_path), encoding="utf-8")
    return sql_path


def write_outputs(con: Any, tables_dir: Path, write_tsv_gz: bool) -> dict[str, str]:
    """导出 Step 1 主结果表。

    流程位置：
        Step 1 的主表输出阶段。

    输入：
        `con`：已创建 `rm_hard_filtered` view 的 DuckDB 连接。
        `tables_dir`：输出目录中的 `tables/` 子目录。
        `write_tsv_gz`：是否额外导出 gzipped TSV。

    输出：
        一个字典，记录生成的主表文件路径。

    默认输出：
        Parquet，ZSTD 压缩。

    可选输出：
        TSV.GZ。这个文件更方便人工查看或交给非 Parquet 工具，但体积通常更大，
        所以默认不生成。
    """
    parquet_path = tables_dir / "sra_run_members_hard_filtered_member_level.parquet"
    con.execute(
        f"""
        COPY rm_hard_filtered
        TO '{sql_quote(parquet_path)}'
        (FORMAT PARQUET, COMPRESSION ZSTD)
        """
    )
    outputs = {"parquet": str(parquet_path)}

    if write_tsv_gz:
        tsv_path = tables_dir / "sra_run_members_hard_filtered_member_level.tsv.gz"
        con.execute(
            f"""
            COPY rm_hard_filtered
            TO '{sql_quote(tsv_path)}'
            (HEADER, DELIMITER '\\t', COMPRESSION GZIP)
            """
        )
        outputs["tsv_gz"] = str(tsv_path)
    return outputs


def compute_qc(con: Any) -> dict[str, list[dict[str, Any]]]:
    """计算 Step 1 的所有 QC 表。

    流程位置：
        Step 1 的质量控制和审计输出阶段。

    输入：
        `con`：已经包含 `rm_norm` 表和 `rm_hard_filtered` view 的 DuckDB 连接。

    输出：
        字典：key 是 QC 表名，value 是该 QC 表的行列表。

    QC 表含义：
        - `filter_funnel`：输入、live、硬筛选通过、拒绝的 rows/distinct Run。
        - `field_completeness`：规范化之后各字段 present/missing 数。
        - `rejection_reason_counts`：各拒绝原因的非互斥计数。
        - `status_counts`：规范化后 Status 分布。
        - `filtered_run_multiplicity_summary`：通过硬筛选后 Run 的多行/member 情况。

    重要口径：
        `rejection_reason_counts` 不是互斥分类；精确拒绝总数以 `filter_funnel`
        里的 `rejected_rows` 为准。
    """
    qc: dict[str, list[dict[str, Any]]] = {}

    # funnel 同时报告 rows 和 distinct Run。
    # 原表是 member-level，一个 RUN 可能对应多行，只看 rows 或只看 Run 都不够。
    qc["filter_funnel"] = fetch_dicts(
        con,
        """
        SELECT 'input_rows' AS metric, COUNT(*)::BIGINT AS rows, COUNT(DISTINCT Run)::BIGINT AS distinct_runs FROM rm_norm
        UNION ALL
        SELECT 'status_live_rows', COUNT(*)::BIGINT, COUNT(DISTINCT Run)::BIGINT FROM rm_norm WHERE Status = 'live'
        UNION ALL
        SELECT 'hard_filtered_rows', COUNT(*)::BIGINT, COUNT(DISTINCT Run)::BIGINT FROM rm_hard_filtered
        UNION ALL
        SELECT 'rejected_rows', COUNT(*)::BIGINT, COUNT(DISTINCT Run)::BIGINT FROM rm_norm WHERE NOT (
            COALESCE(Status = 'live', FALSE)
            AND COALESCE(Spots > 0, FALSE)
            AND COALESCE(Bases > 0, FALSE)
            AND Run IS NOT NULL
            AND Experiment IS NOT NULL
            AND Sample IS NOT NULL
            AND BioSample IS NOT NULL
        )
        """,
    )

    # 字段完整性统计基于规范化后的值。
    # 因此 "-"、"null"、空字符串会被算作 missing，而不是 present。
    qc["field_completeness"] = fetch_dicts(
        con,
        """
        SELECT 'Run' AS field, SUM(CASE WHEN Run IS NOT NULL THEN 1 ELSE 0 END)::BIGINT AS present_rows, SUM(CASE WHEN Run IS NULL THEN 1 ELSE 0 END)::BIGINT AS missing_rows FROM rm_norm
        UNION ALL SELECT 'Experiment', SUM(CASE WHEN Experiment IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Experiment IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Sample', SUM(CASE WHEN Sample IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Sample IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'BioSample', SUM(CASE WHEN BioSample IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN BioSample IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Study', SUM(CASE WHEN Study IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Study IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Member_Name', SUM(CASE WHEN Member_Name IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Member_Name IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Spots_numeric', SUM(CASE WHEN Spots IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Spots IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Bases_numeric', SUM(CASE WHEN Bases IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Bases IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        UNION ALL SELECT 'Status', SUM(CASE WHEN Status IS NOT NULL THEN 1 ELSE 0 END)::BIGINT, SUM(CASE WHEN Status IS NULL THEN 1 ELSE 0 END)::BIGINT FROM rm_norm
        """,
    )

    # 拒绝原因不是互斥分类；同一行可能同时缺 BioSample 且 Spots 非数值。
    # 精确总拒绝数看 filter_funnel，这里用于诊断每类问题规模。
    qc["rejection_reason_counts"] = fetch_dicts(
        con,
        """
        SELECT 'status_not_live_or_missing' AS reason, COUNT(*)::BIGINT AS rows FROM rm_norm WHERE Status IS NULL OR Status <> 'live'
        UNION ALL SELECT 'run_missing', COUNT(*)::BIGINT FROM rm_norm WHERE Run IS NULL
        UNION ALL SELECT 'experiment_missing', COUNT(*)::BIGINT FROM rm_norm WHERE Experiment IS NULL
        UNION ALL SELECT 'sample_missing', COUNT(*)::BIGINT FROM rm_norm WHERE Sample IS NULL
        UNION ALL SELECT 'biosample_missing', COUNT(*)::BIGINT FROM rm_norm WHERE BioSample IS NULL
        UNION ALL SELECT 'spots_missing_or_non_numeric', COUNT(*)::BIGINT FROM rm_norm WHERE Spots IS NULL
        UNION ALL SELECT 'spots_non_positive', COUNT(*)::BIGINT FROM rm_norm WHERE Spots IS NOT NULL AND Spots <= 0
        UNION ALL SELECT 'bases_missing_or_non_numeric', COUNT(*)::BIGINT FROM rm_norm WHERE Bases IS NULL
        UNION ALL SELECT 'bases_non_positive', COUNT(*)::BIGINT FROM rm_norm WHERE Bases IS NOT NULL AND Bases <= 0
        """,
    )

    qc["status_counts"] = fetch_dicts(
        con,
        """
        SELECT COALESCE(Status, '<missing>') AS status, COUNT(*)::BIGINT AS rows, COUNT(DISTINCT Run)::BIGINT AS distinct_runs
        FROM rm_norm
        GROUP BY COALESCE(Status, '<missing>')
        ORDER BY rows DESC, status
        """,
    )

    qc["filtered_run_multiplicity_summary"] = fetch_dicts(
        con,
        """
        WITH per_run AS (
            SELECT
                Run,
                COUNT(*)::BIGINT AS rows_per_run,
                COUNT(DISTINCT Member_Name)::BIGINT AS distinct_member_name,
                COUNT(DISTINCT Experiment)::BIGINT AS distinct_experiment,
                COUNT(DISTINCT Sample)::BIGINT AS distinct_sample,
                COUNT(DISTINCT BioSample)::BIGINT AS distinct_biosample
            FROM rm_hard_filtered
            GROUP BY Run
        )
        SELECT
            COUNT(*)::BIGINT AS filtered_distinct_runs,
            SUM(rows_per_run)::BIGINT AS filtered_rows,
            SUM(CASE WHEN rows_per_run = 1 THEN 1 ELSE 0 END)::BIGINT AS one_row_runs,
            SUM(CASE WHEN rows_per_run > 1 THEN 1 ELSE 0 END)::BIGINT AS multi_row_runs,
            MAX(rows_per_run)::BIGINT AS max_rows_per_run,
            SUM(CASE WHEN distinct_member_name > 1 THEN 1 ELSE 0 END)::BIGINT AS runs_with_multiple_member_names,
            SUM(CASE WHEN distinct_experiment > 1 THEN 1 ELSE 0 END)::BIGINT AS runs_with_multiple_experiments,
            SUM(CASE WHEN distinct_sample > 1 THEN 1 ELSE 0 END)::BIGINT AS runs_with_multiple_samples,
            SUM(CASE WHEN distinct_biosample > 1 THEN 1 ELSE 0 END)::BIGINT AS runs_with_multiple_biosamples
        FROM per_run
        """,
    )

    return qc


def write_qc(qc_dir: Path, qc: dict[str, list[dict[str, Any]]]) -> None:
    """把所有 QC 结果写入 `qc/` 目录。

    流程位置：
        Step 1 的 QC 落盘阶段。

    输入：
        `qc_dir`：输出目录中的 `qc/` 子目录。
        `qc`：`compute_qc()` 返回的 QC 字典。

    输出：
        每个 QC 表一个 TSV 文件。
    """
    for name, rows in qc.items():
        write_tsv(qc_dir / f"{name}.tsv", rows)


def build_manifest(
    input_path: Path,
    outdir: Path,
    header: list[str],
    outputs: dict[str, str],
    qc: dict[str, list[dict[str, Any]]],
    write_tsv_gz: bool,
    sql_path: Path,
) -> dict[str, Any]:
    """构建本次运行的 manifest。

    流程位置：
        Step 1 的最终元数据登记阶段。

    输入：
        `input_path`：原始 `SRA_Run_Members` 路径。
        `outdir`：输出根目录。
        `header`：输入表头。
        `outputs`：主表输出文件路径。
        `qc`：本次生成的 QC 表名。
        `write_tsv_gz`：是否生成 TSV.GZ。
        `sql_path`：SQL 复现文件路径。

    输出：
        可直接写入 `manifest.json` 的字典。

    manifest 的作用：
        把输入、筛选条件、输出字段、输出文件、QC 文件和阶段边界写清楚，
        方便后续在 Notion、README 或 filtered_tables 登记中引用。
    """
    return {
        "generated_at_utc": utc_now(),
        "stage": "02_stage2_run_members_head_table.step1_hard_filter_run_members",
        "input": {
            "path": str(input_path),
            "size_bytes": input_path.stat().st_size,
            "header": header,
        },
        "filter_conditions": {
            "Status": "trim(Status) = 'live'",
            "Spots": "TRY_CAST(normalized Spots AS BIGINT) > 0",
            "Bases": "TRY_CAST(normalized Bases AS BIGINT) > 0",
            "Run": "non-empty",
            "Experiment": "non-empty",
            "Sample": "non-empty",
            "BioSample": "non-empty",
        },
        "output_fields": OUTPUT_COLUMNS,
        "outputs": outputs,
        "qc_files": {name: str(outdir / "qc" / f"{name}.tsv") for name in qc},
        "sql": str(sql_path),
        "write_tsv_gz": write_tsv_gz,
        "notes": [
            "This is member-level output based only on SRA_Run_Members.",
            "SRA_Accessions Visibility filtering is intentionally out of scope for this step.",
            "XML field lookup and relationship QC are intentionally out of scope for this step.",
        ],
    }


def print_plan(args: argparse.Namespace) -> None:
    """打印 dry-run 计划。

    流程位置：
        用户确认前的安全预览阶段。

    输入：
        CLI 参数对象。

    输出：
        打印 JSON 到 stdout，不创建任何文件。

    关键安全承诺：
        dry-run 不读取输入文件、不检查输入是否存在、不导入 DuckDB、不创建输出目录。
        因此用户可以先确认路径、筛选条件和计划输出，再决定是否执行全量扫描。
    """
    plan = {
        "execute": False,
        "message": "Dry plan only. Re-run with --execute to scan input and write outputs.",
        "input": str(args.input),
        "outdir": str(args.outdir),
        "write_tsv_gz": args.write_tsv_gz,
        "overwrite": args.overwrite,
        "filter_conditions": [
            "Status = live",
            "Spots > 0",
            "Bases > 0",
            "Run non-empty",
            "Experiment non-empty",
            "Sample non-empty",
            "BioSample non-empty",
        ],
        "planned_outputs": [
            str(args.outdir / "tables" / "sra_run_members_hard_filtered_member_level.parquet"),
            str(args.outdir / "qc" / "filter_funnel.tsv"),
            str(args.outdir / "qc" / "field_completeness.tsv"),
            str(args.outdir / "qc" / "rejection_reason_counts.tsv"),
            str(args.outdir / "qc" / "filtered_run_multiplicity_summary.tsv"),
            str(args.outdir / "qc" / "status_counts.tsv"),
            str(args.outdir / "manifest.json"),
        ],
    }
    print(json.dumps(plan, ensure_ascii=False, indent=2))


def run(args: argparse.Namespace) -> None:
    """执行 CLI 主流程。

    流程位置：
        Step 1 的总调度入口。

    输入：
        CLI 参数对象，包括输入路径、输出目录、是否执行、是否导出 TSV.GZ、
        是否允许 overwrite。

    输出：
        - dry-run 模式：只打印计划 JSON。
        - execute 模式：写出主表、QC、SQL、manifest，并打印完成 JSON。

    执行顺序：
        1. 如果没有 `--execute`，进入 dry-run 并立即返回。
        2. `--execute` 后才导入 DuckDB。
        3. 校验输入文件和表头。
        4. 准备输出目录。
        5. 创建 `rm_norm` 和 `rm_hard_filtered`。
        6. 导出主结果表。
        7. 计算并写出 QC。
        8. 写出 manifest。
    """
    if not args.execute:
        print_plan(args)
        return

    # DuckDB 只在 --execute 后导入。
    # 这样 dry-run 不依赖 DuckDB，也不会误触发全量扫描。
    try:
        import duckdb
    except ImportError as exc:
        raise SystemExit("DuckDB is required for --execute. Install python package 'duckdb' in the runtime env.") from exc

    if not args.input.exists():
        raise SystemExit(f"Input does not exist: {args.input}")
    header = read_header(args.input)
    validate_header(header)

    paths = prepare_outdir(args.outdir, args.overwrite)
    sql_path = write_sql_bundle(paths["sql"], args.input)
    db_path = paths["work"] / "sra_run_members_hard_filter.duckdb"

    con = duckdb.connect(str(db_path))
    try:
        con.execute(f"PRAGMA temp_directory='{sql_quote(paths['work'])}'")
        con.execute(build_normalized_table_sql(args.input))
        con.execute(build_filtered_view_sql())
        outputs = write_outputs(con, paths["tables"], args.write_tsv_gz)
        qc = compute_qc(con)
        write_qc(paths["qc"], qc)
    finally:
        con.close()

    manifest = build_manifest(args.input, args.outdir, header, outputs, qc, args.write_tsv_gz, sql_path)
    (args.outdir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "done", "outdir": str(args.outdir), "manifest": str(args.outdir / "manifest.json")}, ensure_ascii=False, indent=2))


def parse_args(argv: list[str]) -> argparse.Namespace:
    """解析命令行参数。

    流程位置：
        CLI 参数入口。

    输入：
        `argv`：不含程序名的命令行参数列表。

    输出：
        `argparse.Namespace`，供 `run()` 使用。

    参数设计：
        `--execute` 是强制安全门。没有这个参数时，脚本只打印计划。
    """
    parser = argparse.ArgumentParser(
        description="Build the SRA_Run_Members hard-filtered member-level table for stage 2 step 1."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT, help="Path to SRA_Run_Members TSV.")
    parser.add_argument("--outdir", type=Path, default=DEFAULT_OUTDIR, help="Output directory.")
    parser.add_argument("--write-tsv-gz", action="store_true", help="Also export a gzipped TSV copy.")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="If outdir is non-empty, move it to a .previous_<timestamp> backup before writing.",
    )
    parser.add_argument("--execute", action="store_true", help="Actually scan input and write outputs. Omit for dry plan.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """脚本入口函数。

    流程位置：
        Python 可执行入口。

    输入：
        可选 `argv`，主要用于测试；命令行运行时默认使用 `sys.argv[1:]`。

    输出：
        进程退出码。正常完成返回 0。
    """
    args = parse_args(sys.argv[1:] if argv is None else argv)
    run(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
