# 笺盒增量同步协议 v1.1（模块 6）

> 状态：v1.1 明文修订（2026-09-13，替代 2026-09-09 的 v1 加密冻结稿）
> 上游依据：`cloud-service-contract-v1.md` 第 17 章（模块 6 范围确认）
> 适用范围：Windows 客户端 + Go 服务端双端实现所需的实体模型、变更捕获、信封格式、API 报文与错误码

## 1. 概述

增量同步采用**服务端有序不透明日志 + 元数据级 LWW 仲裁**架构：

- 内容（素材正文、Skill 文件）以**明文 JSON envelope** 形式存储在服务端，服务端可直接读取——这是为了支持网页端查看内容（NeatReader 模式）而做出的明确取舍：端到端加密与该目标互斥；
- 实体元数据（实体类型、实体 ID、`updated_at`、来源设备、删除标记、字节长度与摘要）对服务端可见，服务端据此做确定性 LWW 仲裁和有序日志；
- 所有设备按服务端顺序拉取同一份胜出状态，天然收敛，客户端不需要重放合并逻辑。

**v1 → v1.1 变更**：删除整套同步密钥体系（生成/导入/存储/恢复密钥），envelope 与 blob 从 JHCLSYN1 加密容器改为 UTF-8 JSON 明文；存量密文数据经迁移 000006 全部清空（私测阶段可弃），客户端通过 `head_seq` 回卷检测触发全量重推；同步门禁完全回归账号状态（登录 + VIP）。

## 2. 术语

| 术语 | 含义 |
|---|---|
| 实体 entity | 同步的最小单元：`item` / `category` / `skill_package` |
| 实体状态 entity state | 实体在某一时刻的全部同步字段 + `updated_at` |
| 变更记录 change | 一次实体状态的提交（put 或 delete/tombstone） |
| 批 batch | 一次 push 请求携带的一组变更记录 |
| envelope | 单个实体的明文 JSON 容器（UTF-8 JSON 对象，见第 4 章） |
| blob | Skill 包级明文 JSON 大对象，内容寻址（SHA-256） |
| cursor | 服务端为每账号分配的单调递增变更序号，设备记录已应用位置 |
| 窗口 window | 服务端保留变更日志的滑动范围，落后出窗的设备必须全量重推 |

## 3. 实体与字段

### 3.1 item（素材）

- 实体 ID：`items.id`（客户端 UUID）；
- 实体类型细分：`item:prompt` / `item:skill` / `item:snippet`（对应 `items.type`）；
- 同步字段白名单（`jianhe_item.dart`，含长度上限）：`id`、`type`、`title`（≤100）、`content`（≤100000）、`is_favorite`、`rating`（0–5）、`category`（≤40）、`sort_order`、`created_at`、`updated_at`、`content_hash`；
- **设备本地字段，不进协议**：`use_count`、`last_used_at`；
- envelope 为上述白名单字段的 JSON 对象（`content_hash` 不入信封，由服务端记录的 `package_hash` 语义覆盖 skill 场景）。

### 3.2 category（分类）

- 实体类型：`category:prompt` / `category:skill` / `category:snippet`（类型并入实体类型，避免复合 ID）；
- 实体 ID：分类名（≤40 字符）；
- 同步字段：`name`、`sort_order`、`created_at`；`updated_at` 由变更记录携带（`item_categories` 表无此列，客户端以本地变更时间为准）；
- envelope 为上述字段；分类改名 = 删旧建新两条变更。

### 3.3 skill_package（Skill 包）

- 实体 ID：`skill_id`（= `items.id`）；
- 变更记录只携带元数据：`updated_at`、`deleted`、`package_hash`、`blob_sha256`、`byte_length`、`file_count`；
- 包内容（manifest + 全部文件）序列化后作为一个整体 blob 上传，**整包原子替换**：`package_hash` 不同即视为不同状态，胜出方整体覆盖；
- 删除 skill 条目时客户端必须同时提交 `item:skill` 与 `skill_package` 两条 tombstone；
- blob 为 `{entrypoint, source_format, manifest, imported_at, files:[{relative_path, media_type?, content_base64}]}` 的 JSON 对象——服务端变更记录不带 entrypoint/source_format，两者与 `imported_at` 一并由 blob 携带；`imported_at` 缺失时接收端回退用变更记录的 `updated_at`。

## 4. 信封格式

### 4.1 同步 envelope

envelope 是 **UTF-8 编码的 JSON 对象**（`{` 开头、`}` 结尾，禁止数组/字符串/数字等顶层标量）。服务端在 push 时做三重浅层校验：

1. `utf8.Valid`——非法 UTF-8 拒绝；
2. `json.Valid`——非法 JSON 拒绝；
3. 首尾大括号（`TrimSpace` 后）——非对象 JSON 拒绝。

- 单 envelope 上限 8 MiB（item 最大约 100 KB，正常远低于此）；
- 无任何加密、无版本头；字段结构即第 3 章白名单（item 信封字段照抄 `_itemEnvelope`，category 信封字段照抄 `_categoryEnvelope`）。

### 4.2 blob

blob = 同一明文 JSON 对象（skill 包结构见 3.3），上限 64 MiB，SHA-256 即内容地址。`blob_sha256` / `byte_length` 均按明文字节计算。

## 5. 本地变更捕获（SQLite v7）

### 5.1 v7 迁移新增表

```sql
CREATE TABLE pending_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,  -- 设备本地单调序号
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op TEXT NOT NULL CHECK (op IN ('put','delete')),
  changed_at TEXT NOT NULL                -- 本地 UTC RFC3339
);

CREATE TABLE sync_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- 保存 pull 游标 'pull_cursor'、最近 push 时间等
```

### 5.2 记账规则

- 所有用户写路径在 `jianhe_storage` 的 `writeTransaction` 边界内**同事务追加** `pending_changes`；
- 实体级记账：同一事务内对同一实体的多次写合并为一条（取事务提交后的最终状态）；
- **同步回放路径不记账**：应用 pull 下来的变更走 `applyRemote` 专用入口，写 `writeTransaction` 但跳过记账，防止回声循环；
- push 成功 ack 后删除 `seq <= acked_seq` 的行（压缩）；失败保留待重试；
- `updated_at` 冲突裁决使用实体行上的 `updated_at`，非 `pending_changes.changed_at`。

## 6. API

### 6.1 通用约定

沿用契约第 5 章：`/v1` 前缀、Bearer 鉴权、`X-Request-Id`、RFC3339 UTC、未知字段拒绝、JSON 错误格式、`Idempotency-Key` 幂等（24 小时，仅 push）。

门禁：**push 要求有效 VIP**；pull 允许 VIP 到期后的宽限期内继续，保证用户停付后仍能把数据拉回来。

### 6.2 `GET /v1/sync/state`

```json
{
  "head_seq": 1042,
  "window_start": 930,
  "quota": { "used_bytes": 5242880, "max_bytes": 209715200 },
  "format_versions": { "envelope": 1 }
}
```

客户端在启动同步时先取此接口，以下任一条件触发全量重推流程（6.6）：

- 本地 cursor `< window_start`（滑出窗口；`window_start` 不低于已被 GC 删除的最大变更序号，见 6.7）；
- 本地 cursor `> head_seq`（服务端序号回卷——表被清空/重置，典型场景即 v1.1 明文切换迁移 000006；此时窗口为空而本地数据尚在，全量重推是本地数据上云的唯一路径）。

本接口同时是快照入口：`snapshot=full` 时改为分页返回账号全部存活实体（6.6.1）；不带该参数则保持上述原语义，向后兼容，互不影响。

### 6.3 `POST /v1/sync/changes`（push）

请求体 JSON（≤8 MiB，`MaxBytesReader` 强制）：

```json
{
  "device_id": "…",
  "changes": [
    {
      "entity_type": "item:snippet",
      "entity_id": "…",
      "updated_at": "2026-09-09T08:30:00Z",
      "deleted": false,
      "envelope": "<base64 UTF-8 JSON>"
    },
    {
      "entity_type": "skill_package",
      "entity_id": "…",
      "updated_at": "2026-09-09T08:30:00Z",
      "deleted": false,
      "package_hash": "…",
      "blob_sha256": "…",
      "byte_length": 123456,
      "file_count": 3
    }
  ]
}
```

- `envelope` 字段仍是 base64 字符串，解码后必须是 4.1 定义的明文 JSON 对象，否则整批 `415 UNSUPPORTED_BACKUP_FORMAT`；
- 单批 ≤ 100 条变更；skill_package 记录不携带 envelope（内容在 blob 通道）；
- 服务端逐条 LWW 仲裁（第 7 章），返回逐条结果：

```json
{
  "head_seq": 1043,
  "results": [
    { "entity_type": "item:snippet", "entity_id": "…", "accepted": true, "change_seq": 1043 },
    { "entity_type": "item:snippet", "entity_id": "…", "accepted": false, "reason": "LOST_LWW" }
  ]
}
```

- `accepted=true` 的记录按服务端接收顺序占用 `head_seq` 递增序号并追加进账号变更日志；`LOST_LWW` 表示服务端已有更新状态，客户端应拉取对端胜出状态（本地无需回滚）；
- `QUOTA_EXCEEDED` 表示该条变更会让存活数据超出配额（见 8），只拒绝这一条，同批其余记录照常处理；删除和缩小永远被接受。客户端应保留该条待推送记录，腾出空间后再推；
- 同账号同时只允许一个 push（`409 SYNC_PUSH_IN_PROGRESS`），沿用模块 5 的进程内互斥 + advisory lock 模式；
- 时钟防护：`updated_at` 晚于服务端时间 5 分钟以上的记录整批拒绝（`400 INVALID_REQUEST`）。

### 6.4 `GET /v1/sync/changes?cursor=<seq>&limit=<n>`（pull）

- 按 `change_seq` 升序返回 `(cursor, cursor+limit]` 内已被接受的变更记录；
- `limit` 默认 100，上限 200；响应体 ≤ 4 MiB；
- item/category 记录内联 `envelope`（明文 JSON 的 base64）；skill_package 记录只带 `blob_sha256` 等元数据，客户端按需拉 blob；
- 返回包含本设备自己 push 的记录（at-least-once）；客户端按 apply-if-newer 语义自然跳过自己的回声；
- cursor 超出窗口返回 `410 CURSOR_EXPIRED`。

```json
{
  "changes": [
    { "change_seq": 1041, "entity_type": "item:prompt", "entity_id": "…",
      "updated_at": "…", "deleted": false, "origin_device_id": "…", "envelope": "<base64>" }
  ],
  "next_cursor": 1043,
  "head_seq": 1043
}
```

### 6.5 blob 通道

- `PUT /v1/sync/blobs/{sha256}`：二进制体为明文 JSON blob，`Content-Type: application/vnd.jianhe.sync-envelope.v1`（兼容旧版客户端发送的 `application/octet-stream`，其他类型返回 `400 INVALID_REQUEST`）；流式读取 + 大小校验（≤64 MiB）+ 实测摘要与 URL 不符返回 `400 BLOB_HASH_MISMATCH`；同账号同 hash 幂等（重复上传同样返回 `201`，内容寻址天然去重）；不消耗幂等键；
- `HEAD /v1/sync/blobs/{sha256}`：存在性检查（push 前避免重传）；
- `GET /v1/sync/blobs/{sha256}`：返回对象流，`ETag` = sha256；
- 引用规则：blob 被任何未回收的变更记录引用即存活；解除引用且超过 7 天的 blob 由服务端 GC 删除（宽限期防止刚推完就被清）。

### 6.6 追赶与全量重推

设备满足 6.2 列出的任一恢复条件时：

1. 拉取 `GET /v1/sync/state?snapshot=full` 的全量胜出状态（分页返回全部存活实体记录）；
2. 本地执行 apply-if-newer 合并；
3. 把本地全部存活实体按普通 push 分批重推（LWW 自然裁决，不会覆盖更新的对端状态）；
4. 完成后以快照页报告的最小 `head_seq` 为新 cursor 恢复常规增量。

#### 6.6.1 `GET /v1/sync/state?snapshot=full`（快照分页）

以 `sync_entities` 投影表（账号内每个实体的当前胜出态；push 事务内维护）为源的只读 keyset 分页，零迁移、零 GC 副作用、不消耗变更日志。

请求参数：

| 参数 | 说明 |
|---|---|
| `snapshot` | 固定 `full`；其他值 `400 INVALID_REQUEST` |
| `after_type` / `after_id` | 排他起点游标，首页两者均省略；`after_type` 省略时 `after_id` 必须同时省略，`after_type` 非法时 `400 INVALID_REQUEST` |
| `limit` | 默认 200，上限 200 |

实体按 `(entity_type, entity_id)` 字典序升序排列。响应：

```json
{
  "changes": [
    { "change_seq": 1041, "entity_type": "item:prompt", "entity_id": "…",
      "updated_at": "…", "deleted": false, "origin_device_id": "…", "envelope": "<base64>" }
  ],
  "next_entity_type": "item:prompt",
  "next_entity_id": "…",
  "head_seq": 1043
}
```

- 记录形状与 pull（6.4）完全一致（skill_package 只带 blob 元数据，客户端按需取 blob）；tombstone 不返回，`deleted` 恒为 false；
- 终止条件：响应不含 `next_entity_type` / `next_entity_id`；
- 门禁与 pull 相同（VIP 宽限期内可用）；响应体同样受 pull 4 MiB 约束，靠分页规避；
- **分页期间的并发竞态**：每页各带独立的 `head_seq`（快照期间可能有新 push 入账），客户端取**全部页的最小 `head_seq`** 作为恢复后的新 pull cursor；快照期间新接受的变更随后续常规增量 pull 补齐（apply-if-newer 幂等去重）；
- 崩溃中断安全：恢复流程不推进 cursor，任一页失败重跑整段即可，全程幂等。

### 6.7 服务端 GC

- tombstone 在满足「年龄 > 90 天」且「已滑出日志窗口」后物理删除；
- 变更日志窗口：保留最近 5000 条或 90 天（先到为准）；
- 窗口推进不得越过任何设备上报的 cursor（设备每 24 小时通过 `POST /v1/sync/cursor` 上报心跳游标；超 90 天未上报的设备视为离线，不再约束窗口）；设备退出登录时删除其 cursor（重新登录会获得新的设备 ID）。
- 存储上限：账号的日志 envelope 字节加全部已存 blob 字节超过 400 MiB（配额的 2 倍）时，GC 从最旧的变更开始裁剪，即使低于设备 cursor；此时未被引用的 blob 宽限期由 7 天缩短为 1 小时。被裁剪的设备会收到 `CURSOR_EXPIRED` 并走全量重同步，存活数据不受影响。
- 服务端记录已删除的最大变更序号（`trimmed_through`）。`window_start` 与 pull 的过期判断都不低于它，因此 90 天 TTL 或存储上限裁掉窗口内的变更时，落后的设备一定收到 `CURSOR_EXPIRED`，不会静默跳过。
- blob 回收条件：既不被 `sync_entities` 中未删除的胜出态引用，也不被日志窗口内任何 `sync_changes` 记录引用，且距最后一次被引用超过 7 天。日志窗口内的旧版本 skill 包因此仍可下载，代价是被替换的旧 blob 在日志裁剪前继续计入配额。
- 客户端容错：pull / 快照中单条记录无法使用（blob 返回 `404 BLOB_NOT_FOUND`、envelope 无法解析或字段不合法）时跳过该条并给出警告，游标照常推进；网络、鉴权与 5xx 错误仍使本轮失败以便重试。

## 7. 冲突裁决（确定性 LWW）

- 比较键：`(updated_at, origin_device_id)` 字典序，大者胜；相等视为重复提交，忽略后者；
- 裁决发生在服务端 push 时，结果对全设备一致；
- tombstone 也是状态：删除后对端又推来更旧的 `put` 会被拒绝（`LOST_LWW`）；推来更新的 `put` 则复活实体——这是 LWW 的既定语义，不做特殊保护；
- skill_package：`package_hash` 相同视为重复上传（幂等去重），不同则整包替换，不合并文件；
- 已知局限（接受）：依赖设备时钟，NTP 失常设备可能输掉本不该输的裁决；5 分钟未来偏移防护只挡极端情况。字段级合并留待后续版本。

## 8. 配额与限制

| 限制 | 值 | 超出错误 |
|---|---:|---|
| 存活数据配额/账号 | 200 MiB | 单条 push 结果 `QUOTA_EXCEEDED` |
| 服务端存储上限（含历史）/账号 | 400 MiB | GC 提前裁剪最旧历史；blob 上传仍放不下时 `503 SYNC_STORAGE_BUSY` |
| 单 blob | 64 MiB | `413 SYNC_BLOB_TOO_LARGE` |
| 单批变更数 | 100 | `400 INVALID_REQUEST` |
| push 请求体 | 8 MiB | `413 SYNC_BATCH_TOO_LARGE` |
| pull 响应 | ≤ 200 条 / 4 MiB | 分页解决 |
| push 并发 | 每账号 1 | `409 SYNC_PUSH_IN_PROGRESS` |
| push 限流 | 每账号 30 次/分 | `429 RATE_LIMITED` |

配额计量：只计**存活数据**，即每个未删除实体当前的字节数（item/category 为 envelope 字节，skill 包为其 blob 字节），推送时按"新大小 − 旧大小"增量维护（`sync_accounts.live_bytes`）。同一实体修改多少次都只算当前一份，变更历史不计入配额；`GET /v1/sync/state` 的 `quota.used_bytes` 即此值。

只有让存活数据变大且变大后超出配额的单条变更会被拒绝（`QUOTA_EXCEEDED`），删除与缩小永远允许，账号满了也总能腾出空间。变更历史只受服务端存储上限约束（6.7），超出时裁剪最旧历史而不是拒绝用户修改。

全量重推（6.6）期间同一实体再次入日志，历史用量瞬时增加，不计入配额。

客户端处理（Windows）：
- 被 `QUOTA_EXCEEDED`（或旧服务端整批 `413 SYNC_QUOTA_EXCEEDED`）拒绝的记录保留待推送行，本机数据不动；同一实体再次修改前不重复提交。下次同步时 `quota.used_bytes` 下降、`max_bytes` 增大或距首次拒绝满 1 小时即重新提交；同一轮内若有删除被接受，也会立即重试一次。
- 推送按 seq 分页越过暂时推不出的记录，排在后面的删除照常送出，不会被前面待定的记录挡住。
- 全量重推中被拒的实体补写一条待推送行，转入常规推送路径重试。
- blob 上传遇 `503 SYNC_STORAGE_BUSY` 保留待推送行，下次同步再传；遇 `413 SYNC_BLOB_TOO_LARGE` 永远放不下，丢弃待推送行并提示该 Skill 只保存在本机。导入 Skill 时若编码后超过 64 MiB，桌面端与 CLI 会提前提示。
- 同步状态栏显示"云同步空间已满（已用 X / Y），有 N 项修改暂未上传"，完整告警写入错误日志。

## 9. 新增错误码

| HTTP | code | 含义 | 可重试 |
|---:|---|---|---:|
| 403 | `VIP_REQUIRED` | push/上传 blob 需有效 VIP | 否 |
| 403 | `SYNC_DOWNLOAD_NOT_ALLOWED` | pull/下载 blob 超出 VIP 下载宽限期 | 否 |
| 409 | `SYNC_PUSH_IN_PROGRESS` | 该账号已有 push 在进行 | 是 |
| 409 | `IDEMPOTENCY_KEY_REUSED` | 幂等键已用于不同请求体 | 否 |
| 413 | `SYNC_BATCH_TOO_LARGE` | push 请求体超限 | 否 |
| 413 | `SYNC_BLOB_TOO_LARGE` | 单 blob 超 64 MiB | 否 |
| 413 | `SYNC_QUOTA_EXCEEDED` | 保留：当前服务端不再返回（配额改为单条结果 `QUOTA_EXCEEDED`），旧服务端返回时客户端按配额已满处理 | 否 |
| 503 | `SYNC_STORAGE_BUSY` | blob 上传在裁剪历史后仍超出服务端存储上限 | 是，遵循 `Retry-After` |
| 410 | `CURSOR_EXPIRED` | cursor 已滑出窗口，需全量重推 | 否 |
| 400 | `BLOB_HASH_MISMATCH` | blob 实测摘要与 URL 不符 | 否 |
| 404 | `BLOB_NOT_FOUND` | blob 不存在或已被 GC | 否 |
| 415 | `UNSUPPORTED_BACKUP_FORMAT` | envelope 不是合法的 UTF-8 JSON 对象（v1.1 起语义改为明文格式校验） | 否 |

错误码出现在 `error.code`，语义与契约 5.2/11 章一致。

## 10. 安全与隐私边界（v1.1 重写）

**v1.1 不再提供端到端加密。** 服务端以明文存储全部同步内容，这是支持网页端查看内容的直接代价，须明确接受：

- 服务端可见（明文）：素材标题/正文/分类名、Skill 文件内容、以及全部元数据（实体类型、实体 ID、`updated_at`、`origin_device_id`、删除标记、字节长度、SHA-256、各设备 cursor）；
- 隐私与机密性依赖：传输层 TLS + 服务端账号鉴权 + 服务端存储安全（磁盘权限、备份加密由运维保障）；
- 同步门禁完全回归账号状态：登录 + VIP（服务端逐请求校验）；
- blob/envelope 内容损坏时客户端解析阶段报错，与服务端无关；
- 模块 8 管理界面基于服务端可见数据提供列表/删除——v1.1 起这意味着管理界面可读内容，其访问控制须按生产敏感权限对待。

## 11. 实现前需冻结的数值（沿用 v1 推荐值）

| 参数 | 推荐值 | 说明 |
|---|---|---|
| 日志窗口 | 5000 条 / 90 天 | 先到为准 |
| tombstone 存留 | 90 天 | 契约 17.2.9 |
| blob 解引用宽限 | 7 天 | 防推完即 GC |
| cursor 心跳 | 24 小时 | 超 90 天未上报设备退出窗口约束 |
| 未来时钟容差 | 5 分钟 | push 整批拒绝阈值 |
| push 限流 | 30 次/分/账号 | 与登录限流同量级 |
