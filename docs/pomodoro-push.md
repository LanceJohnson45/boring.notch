# 番茄钟工时推送 v1

请求：`POST https://clawapi.5bug.eu.org/pomo?key=<TOKEN>`。

请求头：`Content-Type: application/json`；`Idempotency-Key: <event_id>`。
Token 只来自本机 `.env`，不写进 JSON、应用包或仓库。请求不跟随重定向。

```json
{
  "schema_version": 1,
  "source": "boring_notch",
  "event_id": "663a4fe9-a663-42ce-bfa6-21d6b054d8ab",
  "session_id": "343cb83d-0b75-4964-957a-7753e1e406d0",
  "event": "pause",
  "phase": "focus",
  "activity": "work",
  "occurred_at": "2026-11-05T15:30:00.000+08:00",
  "session_started_at": "2026-11-05T15:20:00.000+08:00",
  "planned_seconds": 1500,
  "elapsed_seconds": 600,
  "remaining_seconds": 900,
  "completed_today": 2,
  "is_running": false
}
```

| 字段 | 含义 |
| --- | --- |
| `event_id` | UUID4；同一事件的所有重试保持不变，服务端按此去重 |
| `session_id` | UUID4；一个工作或休息阶段的标识，暂停、继续和同日重启恢复保持不变；下个阶段生成新值 |
| `event` | `start` 开始阶段、`pause` 暂停、`resume` 继续、`reset` 放弃并重置、`complete` 阶段完成、`restore` 应用重启恢复、`shutdown` 退出时快照、`progress` 运行中每计时 60 秒的快照 |
| `phase` | `focus` 工作、`shortBreak` 短休息、`longBreak` 长休息 |
| `activity` | `work` 或 `break`，供工时分类汇总 |
| `occurred_at` / `session_started_at` | 当前事件时间 / 阶段首次开始时间，ISO 8601，固定 `+08:00` |
| `planned_seconds` | 本阶段开始时的计划时长，阶段内保持不变 |
| `elapsed_seconds` | 当前阶段累计消耗的倒计时秒数，排除暂停时间，包含重置前已经计时的时间 |
| `remaining_seconds` | 剩余秒数，`planned_seconds - elapsed_seconds` |
| `completed_today` | 当天已经完整完成的工作番茄数，休息不增加，完成工作后的 `complete` 已含本次 |
| `is_running` | 该事件发生后倒计时是否运行；`shutdown` 是退出前快照 |

服务端接入规则：

1. 校验 query 中的 key，按 `event_id` 幂等持久化成功后返回任意 `2xx`（推荐 `204`）；响应体客户端不解析。重复事件也返回 `2xx`。
2. 每个 `session_id` 取最大的 `elapsed_seconds` 作为已计时时长，再按 `activity` 分别求和。**不要累加同一阶段每条事件的累计值，也不要用开始与结束时间直接相减**，否则会重复统计或把暂停算进去。
3. `reset` 代表未完整完成的阶段，其已消耗秒数仍可计入实际工时；完整完成数量只认 `complete` 且 `activity=work`，不要累加 `completed_today`。
4. 按事件时间排序，不能按接收时间排序；离线队列可能延迟补发。按阶段开始日期汇总最简单；若需要跨午夜精确分日，可依据相邻快照的累计秒数差拆分。

发送失败（含非 `2xx`）保留本机队列，30 秒后重试，指数退避到最多 5 分钟；应用下次启动继续补发。采用至少一次投递，服务端必须去重。尚未返回成功的第一条事件会阻塞后面的事件，恢复接口后按队列顺序补发。

计时口径沿用现有番茄钟：运行中的同日退出/重启会按已过去的时间扣减剩余秒数，最多扣到本阶段完成；暂停状态不会扣减。阶段完成后，等待用户确认下一阶段的时间不算工作或休息。跨日重启沿用原有清除缓存行为，未结束阶段只能统计到最后一次快照；强退可能损失最后不足一分钟的快照数据。

## 本机配置与安装

沙盒应用读取：`~/Library/Containers/theboringteam.boringnotch/Data/Library/Application Support/boringNotch/Pomodoro/.env`。

```dotenv
POMODORO_PUSH_KEY=change-this
```

本次已经将用户提供的真实 key 写入本机上述路径，文件权限 `600`。移动新应用到本机 `/Applications` 后仍使用此配置，无需再次填写。其他机器需要自行创建配置；应用包不携带 key。

同目录的 `push-queue.json` 为尚未确认的事件队列，不包含 key。退出旧版应用后，将新 `boringNotch.app` 拖入 `/Applications` 替换，再打开。

此本机包使用 ad-hoc 签名，未做 Apple 公证；用于当前机器。构建、签名检查和自动化测试不能替代接口上线后的真实联调。

本机打包后运行 `bash scripts/sign-local-release.sh <app路径>`，为无 Team ID 的 ad-hoc 包配置动态库加载权限；保留沙盒和 hardened runtime，关闭调试权限。随后必须运行 `bash scripts/verify-app-startup.sh <app路径>` 验证真实启动，不能只依赖 `codesign --verify`。此签名方式仅适用于本机包，Developer ID 分发另走正式签名和公证。
