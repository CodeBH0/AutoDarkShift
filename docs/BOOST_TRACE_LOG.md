# 运行日志与 Boost 记录

数学模型 v2 使用两个平行的日志流。运行日志保存生命周期、配置、切换/通知结果、每秒采样摘要和错误；Boost 记录保存每次动态采样附近的全部真实亮度读数。在“通知与统计”二级页面，App 提供“导出运行日志”和“导出 Boost 日志”两个入口。每次只分享所选流的一份 JSONL：`AutoDarkShift-runtime-<导出编号>.jsonl` 或 `AutoDarkShift-boost-<导出编号>.jsonl`，两次操作各有独立导出编号。

## 一次 Boost 记录的范围

- 从常规 1 Hz 进入动态采样时创建 `traceID`。同轮 10 / 30 / 60 / 120 Hz 档位变化继续写入同一文件。
- 触发前最近 **5 秒**的全部实际观测保留在内存环形上下文中，包括 initial / wake / event / poll，以及上一轮尚在高速采样时的读数。每次重触发都有其真实速度窗口上下文，不补造样本。
- 恢复 1 Hz 后继续记录，直到最近 **2 秒**实际亮度最大值减最小值不超过 **0.005**，并由新的轮询确认结束。该稳定条件独立于数学模型的低速退出条件。
- 尚未稳定又进入动态采样时，新建重叠记录；每个记录单独结束。导出按整个文件连续拼接，各块 `start → samples → end`，不将不同 trace 的无编号数组样本交错。
- 停止、睡眠、重载配置、采样长间断、时钟倒退或非法输入导致 `complete=false`。写入容量超限时以 `capture_size_limit` 结束部分记录，运行日志保存 `boost_trace_error`。这些情况不记为亮度稳定。

## 紧凑格式 v2

每次 Boost 写入 `boost-trace-<traceID>.open.jsonl`，结束后改为 `boost-trace-<traceID>.jsonl`。开始/结束行保留普通 JSONL 事件结构；样本采用数值数组，删除每行重复的 trace/instance/revision/cooldown、亮度的 rawValue 文本副本，以及已从模型删除的 D / 方向计数。模型参数只写在开始行；目标与候选状态仅在变化时写入。

| 行 | 内容 |
| --- | --- |
| `boost_trace_start` | traceID、instanceID、触发时间/序号、5 秒上下文长度、稳定条件、配置 revision/cooldown、`schema=boost-trace-v2`、列定义与数学模型 v2 的完整参数 |
| `{"s":[...]}` | 按 `sampleColumns` 解释的数值列，每个实际观测一行 |
| 样本中的可选 `"n"` | 首样本与状态变化时的完整目标状态：`d` desired、`p` pending、`c` candidateID、`f` inFlightID；其他行继承当前 trace 上次状态 |
| `boost_trace_end` | 原因、完整标记、样本/轮询总数；稳定结束附持续时间与真实亮度范围 |
| `boost_trace_export_boundary` | 仅在导出副本中终止仍打开的块，`complete=false` / `capture_active_at_export`；不会关闭正在采集的原始文件 |
| `boost_trace_export_omitted` | 超过导出预算而整次略去的文件及原因；不会截取尾部冒充完整 Boost |

`sampleColumns` 当前依次为：

```text
sequence, unixSeconds, uptime, brightness, source,
requestedHz, nextHz, S, baseline, filteredBrightness, velocity
```

- `unixSeconds` 是实际墙钟 Unix 秒，可恢复 UTC 时间；`uptime` 保留实际单调秒。保留数值原精度，不按显示小数位舍入。
- `source`：0 initial、1 poll、2 event、3 wake。事件不能当作轮询；采样间隔由相邻 uptime 重建，轮询间隔由相邻 source=1 的 uptime 重建。
- `requestedHz` 是读取时频率，`nextHz` 是该轮评估后的下一频率；调度验证看 uptime/source/sequence，不将目标频率当作实测频率。
- `baseline`、`filteredBrightness` 与 `velocity` 保留计算 S 所需的观测状态；A / Δ / 预测 V 等派生值按开始行模型参数重算。跨 trace 的历史峰谷未完整序列化，短上下文的冷启动轨迹重放与设备热状态可能不同；逐行原状态评分核验应使用这些保留值，不能将上下文缺失误报为公式错误。
- `phase` 根据样本序号与 `triggerSequence` 推得 preboost / trigger / tracking。目标代码为 0 none、1 dark、2 light；候选与在途为空使用 JSON null。

解码工具兼容 build 12 旧完整字段行、旧混合日志中的交错 traceID，以及 v2 连续紧凑块；CSV 保留 traceID/source/sequence/phase、原输入、时间、频率、评分及基线。生成文件必须指定输出位置，建议留在忽略的本地分析目录：

```sh
python3 tools/decode_boost_trace.py local-data/device-logs/AutoDarkShift-boost-<编号>.jsonl \
  --output local-data/analysis/boost-decoded.csv
python3 tools/decode_boost_trace.py local-data/device-logs/AutoDarkShift-boost-<编号>.jsonl \
  --output local-data/analysis/boost-readable.jsonl
```

## 持久化、容量与同步

前置上下文仅在内存中保留；触发时立即写入。活动记录按一秒或最多 256 条批量落盘，结束与导出时冲刷。异常终止可能丢失最后一秒未落盘数据；新监听实例修复半行并将孤立打开文件标为 `process_interrupted`。

运行日志独立轮转：4 个文件，每个最多 256 KiB，总计约 1 MiB。Boost 完成文件保留最近 8 次、总计最多 16 MiB；活动文件不参与轮转，单次最多 8 MiB（超限结束标记另占一条小记录）。Boost 单次导出预算 12 MiB，整次取舍较旧记录，任何略去均显式标记。紧凑样本的实际字节占用由生产编码回归核验，容量未依赖减少实际样本数来提升。

App Group 模式直接读取共享 runtime 与 Boost 文件；Provider 自身诊断通过运行日志流补充，Boost 不重复叠加私有缓存。`local-ipc-v1` 模式按明确的 `exportStream=runtime/boost` 分别分页，运行流取回全部仍保留的运行文件与快照，Boost 流按其独立预算取回完整记录。两流分别原子写入 `provider-diagnostics.jsonl` 和 `provider-boost-traces.jsonl`；一个流同步失败时保留该流上次成功副本，另一流仍可更新。升级旧混合缓存时，先持久迁移其中的 Boost，再替换运行缓存；写入失败事件仍在运行流中。

每页 **32 KiB**，整条 JSONL 可跨页，取回后才做 UTF-8/完整 JSON 校验；单帧仍最多 512 KiB、每流历史快照最多 16 MiB。分页验证 exportID、stream、总字节与连续偏移，防止混合不同日志流。正常分页仅写开始/结束汇总，取消逐页 sent/received/confirmed 的日志噪声；传输、身份与持久化失败仍立即记录。已完成快照保留至下一次新导出，供末页重试；新导出优先回收已完成快照，活动快照总内存最多 32 MiB，不驱逐正在使用的页快照。

手动导出只同步所选流；前台自动同步及关闭保活前的同步仍保存两个流。共享模式的 Boost 直接读取共享记录，运行导出包含 Provider 私有诊断缓存。停止 VPN 或重启 App 后仍可分别导出已同步的两个副本。两个导出文件各自注明成功/缓存/缺失/失败，成功的运行流不会因 Boost 同步失败被标成失败。日志覆盖不足表示不可观测；日志缺失、Provider Message 无回复或读取超时不能单独证明切换功能停止。

## 真机验收

1. 安装匹配 build 的 App 和扩展，重新开启保活，在常规 1 Hz 下保持至少 5 秒。
2. 快速增亮/变暗，再缓慢漂移，确认恢复 1 Hz 后仍保留逐次读取；亮度稳定至少 2 秒后进入“通知与统计”，分别点击“导出运行日志”和“导出 Boost 日志”，每次分享界面应只有相应的一份文件。
3. 解码 Boost 文件，核对 start、真实前置样本、触发轮、所有连续序号及 `complete=true` 的稳定结束。原运行文件应保留通知与错误摘要，避免大量分页回声记录。
4. 尚未稳定时再触发一次 Boost，确认两个连续文件块可独立归属；采集期间关闭保活或睡眠，确认 `complete=false`。
5. 本地通信模式先在线同步，随后关闭 VPN，再分别通过两个入口导出缓存；逐流检查覆盖与失败标记。分别记录实际通知/外观切换和日志可读性。

设备精确频率、后台读取、文件分享及持续采集由本轮真机验收确认；本机编译、模型重放和模拟回归不能代替这些结果。
