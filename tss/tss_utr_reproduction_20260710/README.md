# S1 TSS/UTR Reproduction Pipeline

## Quick Contract Test

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
```

## Run Status

Formal execution is blocked: `FASTP_POLICY_STATUS=blocked` and `FASTP_MAX_N=0` in `config/pipeline.env`. Do not begin the formal pipeline until the FASTP policy is explicitly released.

## Tool Entrypoints

| Tool | Absolute prefix |
| --- | --- |
| fastp | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/fastp/env` |
| STAR | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/STAR/env` |
| StringTie | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/stringtie/env` |
| PASA | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env` |
| AGAT | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/agat/env` |

## Outputs And Reference Constraint

Pipeline outputs are confined to `work/`, `logs/`, and `results/`; failed artifacts are placed in `trash/`. The company GFF3 is read-only and must not be used for parameter tuning.
