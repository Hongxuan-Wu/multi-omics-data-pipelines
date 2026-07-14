# Scientific Dataset Download Framework v2 设计

> 状态：已确认设计
>
> 日期：2026-07-14
>
> 适用仓库：`multi-omics-data-pipelines`

## 1. 背景

RefSeq 全量下载证明，大规模科研数据下载的主要难点不是发起网络请求，而是持续明确下载边界、控制版本漂移、监控长任务、区分失败类型、执行最小粒度补跑，并用可审计证据定义最终完成状态。

当前仓库已经有 `genomes/common/common.sh` 和多套数据集下载脚本，但缺少一套覆盖 FTP、REST API、专用 CLI、分片任务和多盘存储的统一工程标准。Framework v2 将这些经验固化为独立的新框架，供未来下载器使用。

现有 RefSeq 下载脚本是成功案例和设计证据，不是本次改造对象。

## 2. 目标

Framework v2 必须实现以下目标：

1. 将高频沟通沉淀为可审计的下载合同和决策记录。
2. 为新下载器提供统一生命周期、运行产物和完成语义。
3. 复用日志、状态、重试、存储、校验、进度和异常隔离能力。
4. 支持普通 HTTP/FTP 文件以及 NCBI Datasets 一类专用 CLI。
5. 支持断点续跑、多盘切换和最小粒度补跑。
6. 通过离线测试和故障注入证明容错能力。
7. 对永久不可用目标保留明确证据，不静默缩小完成分母。
8. 成功后冻结配置、manifest 摘要和验收条件，防止行为回退。

## 3. 非目标

本次不执行以下工作：

- 不修改 `refseq/` 下任何脚本、测试、文档或运行逻辑。
- 不修改现有 `genomes/common/common.sh`。
- 不迁移或重构现有下载器。
- 不启动任何真实数据下载。
- 不改变现有数据目录、日志目录、manifest 或状态文件。
- 不建设 YAML 解释器或 Python 下载平台。
- 不把数据库专属发现、筛选和语义校验写入公共层。

## 4. 核心工程原则

| 原则 | 强制要求 |
|---|---|
| 边界先于下载 | 先明确 release、目标、排除项、存储、校验和完成条件，再允许传输 |
| 高频沟通必须沉淀 | 会话结论写入下载合同和决策记录，不依赖聊天历史作为唯一依据 |
| 高内聚、显式依赖 | 公共层提供横切能力，适配器只实现数据源专属逻辑 |
| Manifest-first | 下载对象先形成可冻结、可校验的 canonical manifest |
| Plan-before-transfer | 正式下载前必须输出文件数、体积、存储位置和校验覆盖率 |
| 幂等与可恢复 | 重跑跳过已验证文件，各阶段可以独立恢复 |
| 可观测性内建 | 进度、速度、ETA、下载时长和当前阶段由公共层统一输出 |
| 分层校验 | 官方 checksum 优先，并用大小、压缩、格式、记录数和语义规则补充 |
| 最小粒度修复 | 只补单文件、单 accession、单 shard 或单 archive part |
| 失败分类 | 网络、限流、永久下架、损坏、空间、漂移、配置和程序错误分别处理 |
| 控制面与数据面分离 | 最终数据与日志、状态、计划、临时文件、报告和 trash 分开存放 |
| 成功后冻结 | 默认配置、manifest 摘要和完成合同由测试锁定 |

函数之间不追求高耦合。公共函数通过稳定接口组合，数据集适配器显式声明依赖；日志等横切能力由生命周期核心统一调用，而不是复制到每个下载器。

## 5. 协作与决策门

高频沟通主要用于首次设计和异常处理。成熟后的下载器必须依靠合同、状态和报告表达事实，减少对会话上下文的依赖。

### 5.1 范围门

正式设计前必须确认：

- 官方数据源和 release。
- 下载的数据集、文件格式和元数据。
- 明确排除项。
- required 目标的定义。
- 永久缺失的处理原则。

输出：`download_contract.md` 和 `decisions.md`。

### 5.2 执行门

正式下载前必须确认：

- manifest 文件数和摘要。
- 预计压缩体积和空间阈值。
- 数据目录、运行目录和候选盘顺序。
- 凭证来源和脱敏方式。
- 初始并发、重试、限流和监控周期。
- 实际启动、停止和状态查询命令。

输出：冻结 manifest、离线 plan 和 preflight 报告。

### 5.3 异常门

永久下架、suppressed、源端格式变化和合同变更必须人工确认。框架只能记录证据和建议状态，不能自动把异常目标从分母中移除。

输出：异常审批记录、repair plan 或新快照决策。

## 6. 总体架构

```text
download_framework/v2/
├── README.md
├── lib/
│   ├── runtime.sh
│   ├── logging.sh
│   ├── state.sh
│   ├── retry.sh
│   ├── storage.sh
│   ├── transfer.sh
│   ├── verify.sh
│   ├── progress.sh
│   └── trash.sh
├── schemas/
│   ├── manifest.schema.tsv
│   ├── plan.schema.tsv
│   ├── event.schema.tsv
│   └── exception.schema.tsv
├── template/
│   ├── download_dataset.sh
│   ├── adapter.sh
│   ├── download_contract.md
│   ├── decisions.md
│   ├── download_scheme.md
│   ├── runbook.md
│   └── validation_report.md
├── tests/
│   ├── fixtures/
│   ├── test_framework_contracts.sh
│   ├── test_retry_and_resume.sh
│   ├── test_storage_failover.sh
│   ├── test_verification_layers.sh
│   └── test_failure_injection.sh
└── examples/
    └── refseq_lessons.md
```

`examples/refseq_lessons.md` 只描述经验映射，不 source、调用或修改任何 RefSeq 文件。

## 7. 组件职责

| 组件 | 职责 |
|---|---|
| `runtime.sh` | 初始化 `RUN_ID`、目录、框架版本、进程锁、trap 和阶段调度 |
| `logging.sh` | 统一主日志、错误日志、事件日志和注册敏感值脱敏 |
| `state.sh` | 校验状态转换，追加事件，原子更新 latest 状态，生成终态 |
| `retry.sh` | 错误分类、指数退避、随机抖动、`Retry-After` 和重试预算 |
| `storage.sh` | 有序候选盘、保留空间、目标分配、切盘和 `storage_map.tsv` |
| `transfer.sh` | 调度 `aria2`、`curl` 或 adapter custom transport |
| `verify.sh` | 大小、checksum、gzip、非空、格式和 adapter custom 校验 |
| `progress.sh` | 文件数、字节数、unit 数、滚动速度、ETA 和运行时长 |
| `trash.sh` | 路径安全检查和异常文件隔离；不执行删除 |

公共函数统一使用 `dfw_` 前缀，适配器钩子统一使用 `adapter_` 前缀。框架导出 `DFW_API_VERSION=2.0`，适配器必须显式声明兼容版本。

## 8. 适配器接口

每个新下载器必须实现：

```bash
adapter_validate_config
adapter_discover_targets
adapter_validate_source_version
adapter_prepare_transfer
adapter_classify_source_error
```

按需实现：

```bash
adapter_run_custom_transfer
adapter_verify_custom
adapter_progress_custom
```

接口规则：

- `adapter_discover_targets` 只生成候选 canonical manifest，不直接下载 payload。
- 普通 HTTP/FTP 目标使用公共 `aria2` 或 `curl` transport。
- 专用 CLI 才实现 `adapter_run_custom_transfer`。
- 自定义校验必须返回标准状态和错误分类，不能只打印日志。
- 适配器可以调用 `dfw_log` 等公开函数，不得读取公共库内部变量。
- 公共层不得出现 NCBI、UniProt、GTDB 等数据库专属字段和分支。

## 9. Canonical 数据合同

所有 TSV 使用 UTF-8、单行记录和固定表头。字段不得包含制表符、换行或 NUL。

身份模型：

- `contract_digest` 是已确认、使用 LF 换行的 `download_contract.md` 文件字节 SHA-256。
- `snapshot_id` 由 `dataset + source_version + contract_digest` 确定，不依赖 manifest 自身摘要。
- `manifest_digest` 是冻结 manifest 的 SHA-256，用于阻止同一 snapshot 下的目标集漂移。
- `plan_id` 由 `snapshot_id + manifest_digest + 按键名排序的有效配置快照` 确定。
- `RUN_ID` 标识一次实际执行，建议格式为 UTC 时间戳加进程号；多个 RUN 可以引用同一 snapshot 和 plan。

因此，来源版本、下载边界或 manifest 内容任一变化都会产生可检测的身份变化，不会形成摘要循环，也不会把新目标集接入旧状态。

### 9.1 Manifest

每个下载目标一行：

```text
schema_version
dataset
snapshot_id
target_id
unit_id
group
source_version
source_url
relative_path
expected_bytes
checksum_type
checksum
content_type
required
notes
```

约束：

- `target_id` 在一个 snapshot 内唯一。
- `unit_id` 是最小补跑单位。
- `relative_path` 必须是安全相对路径，不允许绝对路径或 `..`。
- `required` 只能是 `0` 或 `1`，不能根据下载结果临时改变。
- `checksum_type` 取 `sha256`、`md5` 或 `none`。
- `checksum_type=none` 时必须存在替代校验策略。
- `expected_bytes` 未知时使用空值，不使用伪造的 `0`。
- 冻结后记录 canonical 内容的 SHA-256，原文件不再修改。

### 9.2 Plan

Plan 从冻结 manifest 确定性生成，至少包含：

```text
plan_id
target_id
unit_id
source_url
storage_id
local_path
transport
verification_policy
selected
```

Plan 必须记录总文件数、required 文件数、已知总字节数、未知大小目标数、各校验策略覆盖数和 manifest SHA-256。

### 9.3 Event

事件文件是追加式审计记录：

```text
timestamp_utc
run_id
phase
event
unit_id
target_id
attempt
status
error_class
detail
```

### 9.4 Exception

永久异常记录至少包含：

```text
target_id
unit_id
source_version
error_class
reason
evidence
approved_by
approved_at_utc
```

没有审批人、时间和源端证据的记录不能改变完成状态。

## 10. 标准生命周期

所有下载器统一支持：

| Action | 作用 |
|---|---|
| `discover` | 发现远端目标并生成候选 manifest |
| `plan` | 校验并冻结 manifest，生成离线下载计划 |
| `preflight` | 检查工具、凭证、网络、release、空间、路径和重复进程 |
| `download` | 执行下载或断点续传 |
| `verify` | 对完整目标集执行严格校验 |
| `repair` | 只补缺失或损坏的最小 unit |
| `status` | 输出最新进度、速度、ETA 和下载时长 |
| `summary` | 生成最终审计报告 |
| `all` | 按状态机执行完整流程 |

每个 Action 可以独立重跑，但必须校验上游 manifest 和 plan 摘要。`all` 只是阶段编排，不包含另一套隐式逻辑。

## 11. 状态机与退出语义

```text
NEW
  -> DISCOVERED
  -> PLANNED
  -> PREFLIGHT_OK
  -> TRANSFERRING
  -> VERIFYING
       |-> COMPLETE
       |-> NEEDS_REPAIR -> REPAIRING -> VERIFYING
       |-> COMPLETE_WITH_APPROVED_EXCEPTIONS
       `-> BLOCKED
```

终态：

| 状态 | 含义 | 标准退出码 |
|---|---|---:|
| `COMPLETE` | 所有 required 目标通过校验 | `0` |
| `COMPLETE_WITH_APPROVED_EXCEPTIONS` | 仅剩有完整审批证据的永久异常 | `10` |
| `NEEDS_REPAIR` | 存在可补下载的缺失或损坏目标 | `20` |
| `BLOCKED` | 来源、凭证、空间、工具或内部错误阻止继续 | `30` |

命令行参数错误使用退出码 `2`。适配器不得把非零 transport 退出码直接解释为整个数据集的终态，必须结合状态和校验结果分类。

## 12. 运行目录与证据

```text
RUN_ROOT/<dataset>/<snapshot_id>/
├── config/config_snapshot.env
├── manifests/source_manifest.tsv
├── manifests/source_manifest.sha256
├── plans/download_plan.tsv
├── plans/repair_plan_<round>.tsv
├── state/events.tsv
├── state/phase_status.tsv
├── state/latest_progress.tsv
├── state/storage_map.tsv
├── state/exceptions.tsv
├── logs/main.log
├── logs/error.log
├── logs/transport_*.log
├── reports/preflight.tsv
├── reports/verification.tsv
├── reports/missing_targets.tsv
├── reports/final_summary.md
├── tmp/
└── trash/
```

数据目录只保存最终 payload。控制面保留足以回答以下问题的证据：下载了什么、为何下载、运行到哪一步、失败在哪里、如何恢复、最终为何被认定为完成。

`latest_progress.tsv` 等 latest 文件先写同目录 partial，再原子替换。框架不自动删除临时文件；无效临时文件移入本次运行的 `trash/`。

## 13. 失败分类与恢复策略

| 分类 | 示例 | 策略 |
|---|---|---|
| `TRANSIENT_NETWORK` | timeout、DNS、TLS、408、5xx | 保留 partial，退避重试 |
| `RATE_LIMITED` | 429、服务端限流信息 | 遵守 `Retry-After`，暂停并降低并发 |
| `REMOTE_PERMANENT` | 404、410、suppressed | 记录证据，进入人工异常门 |
| `LOCAL_CORRUPTION` | 大小、checksum、gzip、格式失败 | 移入 trash，生成 repair plan |
| `STORAGE_BLOCKED` | 剩余空间低于阈值 | 保存状态，按候选顺序切盘 |
| `CONTRACT_DRIFT` | release、数量、schema 或摘要变化 | 下载前停止，禁止混合快照 |
| `AUTH_CONFIG` | 凭证、权限、命令缺失 | fail fast，不重试 |
| `INTERNAL_INVARIANT` | 重复 target、非法状态、路径越界 | 立即停止并保留现场 |

重试规则：

- 按 `unit_id` 维护重试预算。
- 使用指数退避和随机抖动。
- 存在 `Retry-After` 时以服务端指示为下限。
- 单盘重试次数与候选盘遍历次数分离。
- 持续限流或高错误率时降低并发，不自动激进升高。
- 达到预算后进入 `NEEDS_REPAIR` 或 `BLOCKED`，不无限循环。

## 14. 多盘存储

候选盘是有序列表，每个盘配置最低保留空间。框架在下载前和运行中重复检查空间：

1. 按顺序选择第一个空间达标的候选盘。
2. 为目标写入 `storage_map.tsv` 后再开始传输。
3. 当前盘低于阈值时停止分配新目标并落盘状态。
4. 重算未完成目标，切换到下一个空间达标的候选盘。
5. 已完成文件不搬迁，不通过扫描路径猜测其位置。
6. 所有下游读取都以 `storage_map.tsv` 为定位依据。

## 15. 下载、校验与修复

### 15.1 下载前

- 校验 manifest schema、唯一键、路径和版本。
- 生成确定性 plan 并统计校验覆盖率。
- 检查数据盘和运行盘空间。
- 检查命令、凭证和远端版本。
- 获取进程锁，防止同一 snapshot 重复运行。
- 对 1 至 10 个目标执行冒烟测试。

### 15.2 下载中

- 已验证文件直接跳过。
- partial 保留并继续传输。
- 每次尝试写事件和错误分类。
- 传输失败不立即缩小目标集。
- 监控进程随主任务终态自动停止。

### 15.3 分层校验

按可用证据组合：

1. 官方 SHA-256 或 MD5。
2. 官方或冻结 manifest 中的 Content-Length。
3. gzip/tar 等容器完整性。
4. 文件格式解析。
5. 记录数、关键字段和数据集专属语义。
6. 全局 manifest 覆盖率。

弱校验必须在 manifest 和报告中显式标记，不得伪装成 checksum 强校验。

### 15.4 最小补跑

```text
全量 manifest
  -> 对照已验证状态
  -> 生成 repair_plan_<round>.tsv
  -> 隔离损坏文件
  -> 只下载异常 unit_id
  -> 校验修复目标
  -> 再做全局覆盖审计
```

原 manifest 永不修改。每个 repair plan 保存父 plan 摘要和轮次，失败目标始终保留在完成分母中。

## 16. 可观测性

框架按固定周期更新：

```text
phase
files_done
files_total
bytes_done
bytes_total
units_done
units_total
elapsed_seconds
speed_10m
speed_30m
speed_60m
eta_seconds
current_storage
retry_count
last_error_class
```

要求：

- 主日志使用适合 `tail -f` 的单行文本。
- `latest_progress.tsv` 适合程序读取。
- 下载时长从正式 transfer 开始计算，并在终态冻结。
- 总字节数未知时，ETA 写 `unknown`，不输出伪精确估计。
- 速度同时保留短、中、长窗口，避免只用全程平均掩盖停滞。
- 终态报告记录开始时间、结束时间和总时长。

## 17. 安全与路径约束

- 凭证只从环境或受控凭证文件读取，不写入 manifest、plan、状态和命令日志。
- `logging.sh` 支持注册敏感值，并在所有公共日志出口统一脱敏。
- URL 中的 token、query secret 和 header credential 在落盘前脱敏。
- 所有本地路径必须验证位于声明的数据根或运行根内。
- 拒绝绝对 `relative_path`、`..`、控制字符和重复规范化路径。
- 不执行删除命令；异常文件和无效 partial 只移入 `trash/`。
- 进程锁按 dataset 和 snapshot 维度建立，防止并发写同一状态文件。

## 18. 文档合同

每个新数据集必须包含：

| 文档 | 内容 |
|---|---|
| `download_contract.md` | 数据边界、release、required、排除项、空间、限流、校验和完成定义 |
| `decisions.md` | 决策、时间、依据、替代方案和影响 |
| `download_scheme.md` | 来源、适配器、manifest、数据流和目录 |
| `runbook.md` | 启动、监控、停止、续跑、repair 和 summary 命令 |
| `validation_report.md` | 冒烟、故障注入、全量验证和已知异常的真实结果 |

文档不得用聊天记录代替，也不得保留 `TODO`、`TBD` 或未经验证的运行命令作为正式验收内容。

## 19. 测试策略

### 19.1 静态契约

- Bash 语法通过。
- 公共 API 和必需 adapter 钩子齐全。
- 框架版本兼容。
- 不存在硬编码凭证。
- 不存在删除命令。
- schema、默认状态和退出码被测试锁定。

### 19.2 单元测试

- 日志脱敏。
- 合法和非法状态转换。
- 重试退避和预算。
- 候选盘顺序及空间阈值。
- 路径规范化和根目录约束。
- checksum、大小、gzip 和自定义校验调度。
- trash 隔离和命名冲突处理。

### 19.3 故障注入

使用离线 fixture 和 mock 模拟：

- 429 与 `Retry-After`。
- 503、timeout 和连接中断。
- 截断文件、错误 checksum、坏 gzip 和空文件。
- 空间不足和切盘。
- 主进程中断与恢复。
- release 漂移和重复 target。
- 远端永久不存在及未审批异常。

### 19.4 离线端到端

小型 fixture 必须走完：

```text
discover -> plan -> preflight -> download -> interrupt
-> resume -> corrupt -> verify -> repair -> verify -> summary
```

端到端测试不得访问真实数据库，不得写入正式数据盘。

### 19.5 幂等测试

完成后重跑必须满足：

- 已验证 payload 不重新传输。
- manifest 和 plan 摘要不变化。
- 新运行有独立 `RUN_ID`，但引用相同 snapshot。
- final summary 仍给出相同完成分母和终态。

## 20. 分阶段放量

新下载器禁止直接全量运行：

```text
离线 plan
  -> 1 至 10 个目标冒烟测试
  -> 1 个完整 unit 或 shard
  -> 故障注入与恢复
  -> 小规模性能测试
  -> 确认并发和限流
  -> 全量下载
```

并发参数必须根据目标数据库限流、单文件大小、服务器带宽和小规模测试确定，不能直接复制 RefSeq 的并发配置。

## 21. Definition of Done

只有全部满足才能标记成功：

1. 下载合同和关键决策已经确认。
2. manifest 版本、数量、摘要和预计体积有记录。
3. preflight 和小规模试运行通过。
4. 正式下载持续输出进度和下载时长。
5. 所有 required 目标已验证，或仅剩已审批的永久异常。
6. 不存在未解释的 partial、空文件或损坏文件。
7. repair 后执行过全局覆盖审计。
8. 成功后重跑已经证明幂等。
9. 最终报告包含文件数、字节数、校验覆盖率、异常和运行时长。
10. 通用测试、适配器测试和静态契约全部通过。
11. 默认参数、manifest 摘要和完成条件由契约测试冻结。
12. `runbook.md` 中的启动、监控、停止和补跑命令已经实际验证。

## 22. 首次实施范围

Framework v2 首次实施交付：

- 独立公共库和版本接口。
- 四种 canonical schema。
- 新下载器模板及五份文档模板。
- 离线 fixture、单元测试、故障注入和端到端测试。
- RefSeq 经验映射文档。
- 仓库根入口说明。

首次实施不包含任何真实数据库 adapter。未来新增数据集时，从模板建立 adapter，并通过同一套设计门和验收门。

## 23. 已确认决策

| 决策 | 结果 |
|---|---|
| 是否修改现有 RefSeq 下载脚本 | 不允许修改 |
| 是否修改现有 `genomes/common/common.sh` | 不修改 |
| v2 是否独立建设 | 是，使用根级 `download_framework/v2/` |
| 核心技术形态 | Bash 生命周期框架 + 数据集适配器 |
| 是否迁移现有下载器 | 本次不迁移 |
| 是否执行真实下载 | 本次不执行 |
| 公共层和专属逻辑关系 | 公共层管理生命周期，适配器管理数据源差异 |
| 完成判断 | 严格 manifest 分母 + 显式批准异常 |
