# dsh-no-poll · 说明书

**给「要用它的人」和「要写代码调它的 AI」看。**
想先了解「为什么」→ 看 [README.md](README.md)（中文）。
English version: [MANUAL.md](MANUAL.md).

---

## 0. 三十秒决定：我该用哪个

```
要等的东西是什么？
│
├─ 一个命令行程序（ffmpeg / blender -b / 编译 / 训练脚本）
│    └─ ★ 不需要本仓库的任何等待器
│       直接让宿主后台跑它（DSH 里是 run_in_background），完成时宿主会通知你
│
├─ 「提交 → 排队 → 异步完成」的软件（ComfyUI / 渲染农场 / 云端队列）
│    └─ 用等待器
│       ├─ 有 Python         → waiters/wait.py   ★ 首选（事件驱动）
│       ├─ Windows 没 Python  → waiters/wait.ps1  （事件驱动）
│       └─ 只有 bash          → waiters/wait.sh   （事件驱动，纯 bash WebSocket）
│
└─ 一个我自己的软件
     └─ 看 examples/add-your-own.md —— 让 AI 帮你写适配器
```

**核心原则**：**等待器在后台阻塞，模型不等。** 等待期间模型 turn 数 = 0。

**判断标准一句话**：**任务在不在你手里。**
在手里的（`blender -b` / `ffmpeg` / 编译）→ 不需要等待器。
不在手里的（提交给别的服务排队）→ 需要。

---

## 1. 安装

### 1.1 装进 DSH（让规则常驻）

```bash
git clone https://github.com/jiuyuesang-art/dsh-no-poll.git
cd dsh-no-poll
```

然后在 DSH 里说：

> **「安装插件包 `<仓库绝对路径>`」**

或者手动（等价）：

1. 让包能被 DSH 的 profile 解析到 —— 放进 `<profile>/node_modules/`，或做符号链接
2. 在 DSH 的插件管理里启用 `dsh-no-poll`
3. **重启 DSH**

**验证装好了**：重启后问模型「长任务该怎么等」—— 它应该说出「用后台作业，不要轮询」。

### 1.2 只用等待器（不装插件）

等待器是**独立脚本**，零依赖，可以单独拷走：

```bash
cp waiters/wait.py /anywhere/
python /anywhere/wait.py comfyui --prompt-id <ID> --client-id <CID>
```

**它不需要 DSH，也不需要这个仓库的其它部分。**
但那样你就失去了「规则常驻」—— 得自己记得去用。

---

## 2. 退出契约 —— 只有三个状态

```
0  DONE     成功 —— 系统明确报告完成
1  FAILED   失败 —— 系统明确报告失败；或连不上系统且重试耗尽
   （不退出）等待 —— 进程一直阻塞。这是默认且正常的状态
```

### 🔴 没有超时，也没有「放弃」

**排队中、慢、看起来卡死 —— 都一直等。**

### 🔴 `FAILED` 的判定是严格的

**只有两种情况**才会报失败：

| 情况 | 说明 |
|---|---|
| **上游系统自己说失败了** | ComfyUI 报 `status_str` 为 `error`/`failed`，或 `execution_error`、`execution_interrupted` |
| **完全连不上，且重试耗尽** | 默认重试 2 次，间隔 150 秒 |

**绝不会**因为下面这些报失败：

- 任务慢
- 任务在排队（`queue_pending`）
- 某一次查询失败（网络抖了）
- history 里暂时查不到这个任务

**为什么这么严**：误判失败的代价是**丢掉已经完成的工作**，或者**重复提交**。
更糟的是 —— **模型会因此去打断一个还在跑的任务**。

**输出**

- `stderr`：给人看的进度（`--quiet` / `-Quiet` 关掉）
- `stdout` **最后一行**：给机器看的 `标签\t详情`，例如 `DONE	137.9s, 1 output node(s)`

```bash
out=$(python waiters/wait.py comfyui --prompt-id "$ID" --client-id "$CID" -q)
code=$?
case $code in
  0) echo "成功：${out#*$'\t'}" ;;
  1) echo "失败：${out#*$'\t'}" >&2; exit 1 ;;
esac
```

> `code` 只会是 0 或 1。**没有别的情况** —— 进程只在拿到**真实结局**时才退出。
> 等待期间它根本不返回。

---

## 3. 等待器完全参考

三个脚本**接口一致**：相同子命令、相同参数名（大小写风格随语言习惯）、相同退出码、相同末行格式。

### 3.1 共同参数

| 参数 | Python | PowerShell | Bash | 默认 | 说明 |
|---|---|---|---|---|---|
| 轮询间隔 | `--interval` | `-IntervalSeconds` | `--interval` | 3 | 秒 |
| 单次请求超时 | `--request-timeout` | `-RequestTimeoutSeconds` | `--request-timeout` | 10 | 秒 |
| 连接重试次数 | `--conn-retries` | `-ConnRetries` | `--conn-retries` | 2 | 耗尽后报 FAILED |
| 重试间隔 | `--conn-retry-delay` | `-ConnRetryDelaySeconds` | `--conn-retry-delay` | 150 | 秒 |
| 安静模式 | `-q` / `--quiet` | `-Quiet` | `-q` / `--quiet` | 关 | 只输出末行 |

> 这里的「超时」是**单次网络请求**的超时，**不是任务的截止时间**。
> **没有任何参数能让等待器放弃一个任务。**

### 3.2 `comfyui` —— 等一个 ComfyUI 任务

**⚠️ 要有真事件，必须同时给 `prompt_id` 和 `client_id`。**

**为什么**：ComfyUI 的执行事件是**定向发送**的。看它的源码：

```python
# ComfyUI/execution.py
server.send_sync("executing", {...}, server.client_id)   # 第三个参数 = 目标 client
```

| 你用的 client_id | 广播消息（`status`） | 执行事件（`execution_*`） |
|---|---|---|
| 提交时那个 | ✅ 收得到 | ✅ **收得到** |
| 随便造的 | ✅ 收得到 | ❌ **一条都收不到** |

**这是整片领域里最阴险的失败模式**：握手成功、能看到 `{"type":"status", ...}`、
一切看起来都正常，**就是没有执行事件**。

（本仓库开发时实测：任务跑了 137 秒并成功产出，而监听方**收到了 0 条执行事件**。
换成提交时那个 `client_id` 后立刻收到实时进度。）

两个 id 从哪来（DSH + ComfyUI MCP）：

```
run_workflow(wait=false)  →  { "prompt_id": "...", "client_id": "..." }
```

| 参数 | Python | PowerShell | Bash | 默认 |
|---|---|---|---|---|
| prompt id | `--prompt-id` | `-PromptId` | `--prompt-id` | 必填 |
| client id | `--client-id` | `-ClientId` | `--client-id` | `''`（会退化成轮询） |
| 主机 | `--host` | `-HostName` | `--host` | `127.0.0.1` |
| 端口 | `--port` | `-Port` | `--port` | `8188` |
| 强制轮询 | `--poll` | `-Poll` | `--poll` | 关 |

```bash
python waiters/wait.py comfyui --prompt-id abc-123 --client-id def-456
```

```powershell
./waiters/wait.ps1 comfyui -PromptId abc-123 -ClientId def-456
```

```bash
bash waiters/wait.sh comfyui --prompt-id abc-123 --client-id def-456
```

**它内部做了什么**（决定了它有多可靠）

1. **竞态保护**：连事件流**之前**先查一次 `/history/<id>`。
   任务可能在「提交完」和「连上」之间就跑完了 —— 那样你会永远等不到事件。
   **这不是轮询**，是一次性检查。
2. **阻塞在事件流上**：连 `/ws?clientId=<那个id>`，然后阻塞读。
   **不是定时去问 —— 是等服务端推。**
3. **降级会告知**：WebSocket 连不上或中途断了 → 自动切到轮询 `/history`，并**打印原因**。
   **绝不会静默降级。**
4. **结局判定**：见下面的表。

| 事件 | 判定 |
|---|---|
| `execution_success` | **DONE**（系统明确报成功） |
| `executing` 且 `node=null` | **DONE**（兜底，也是整轮结束） |
| `execution_error` | **FAILED** |
| `execution_interrupted` | **FAILED** |
| 其它 | **继续等** |

### 3.2b Bash 版是怎么做 WebSocket 的

`wait.sh` **也是事件驱动的**，而且零依赖。它用 bash 的 `/dev/tcp` 开原始 TCP，
然后自己实现 WebSocket 协议。

之所以可行，靠两个事实：

1. **服务端→客户端的帧不加掩码**（RFC 6455）—— 所以没有掩码要剥，只需读帧头和负载
2. **`read -u FD` 在非可寻址描述符上逐字节读，不会多读**；
   `dd bs=1 count=N <&FD` 精确读 N 字节 —— 两者都对着**真 ComfyUI** 验证过

实测：`... 5/25 ... 10/25 ... 15/25 ... 20/25 ... 25/25 → [DONE] 148s` ✅

**代价说明**：`dd bs=1` 约 80 KB/s。ComfyUI 的消息很小
（`status` ~100 B、`progress` ~80 B、`executed` 200–2000 B），**一帧约 1–25 ms** ——
对等待器完全无所谓，换来的简单性是值得的。

**可移植性**：脚本按 **bash 3.2**（macOS 自带版本）写，
所以不能用 `read -N`、`mapfile`、`${var,,}`、关联数组、nameref。

**开发中踩到的三个坑**（你要改的话，值得知道）：

| 坑 | 症状 | 解法 |
|---|---|---|
| `exec $FD<>/dev/tcp/...` | `exec: 4: not found` | **fd 号必须是字面数字** —— bash 把 `$FD` 当命令名 |
| `exec 3<>/dev/tcp/... 2>/dev/null` | 之后**所有**消息消失 | `exec` 没有命令参数时重定向**作用于 shell 且永久生效**。关进花括号：`{ exec 3<>/dev/tcp/...; } 2>/dev/null` |
| sed 里贪婪的 `s/.*"type".../` | 事件被静默丢弃，`executed` 数成 0 | 贪婪匹配找的是**最后**一个，而嵌套对象复用同名 key（`images[].type == "output"`）。改用 `grep -o ... \| head -n1` 取**第一个** |

最后一条很微妙：把正则锚定到消息开头能修好 `type`，
但会**弄坏** `prompt_id` 和 `exception_message` —— 它们在 `data` 里，不在开头。
**取第一个匹配**两种情况都对。

`/dev/tcp` 不可用时（bash 编译时没开 net redirections），脚本会退化成轮询，**并且明确告知**。

### 3.2c 多输出节点，以及明确的成功事件

一个工作流可以有多个输出节点（比如 3 个 `SaveImage`）。实测的事件顺序是：

```
[122.0s] executing         node=9
[122.2s] executed          node=9    output={images: [...]}
[122.2s] executing         node=92
[122.5s] executed          node=92   output={images: [...]}
[122.5s] executing         node=91
[122.8s] executed          node=91   output={images: [...]}
[122.8s] execution_success           ← ComfyUI 自己的成功判决
[122.8s] executing         node=NULL ← 整轮结束
```

由此得到两件事：

1. **`executing` 且 `node == null` 是在所有输出节点都完成之后才发的**，
   所以等它就等于等全部输出。它是**确定性的结束标记**。
2. **`execution_success` 确实存在**，是 `execution_error` 的精确对称物。
   两者现在都是 DONE 的终止事件（谁先到算谁）。
   **成功因此和失败一样明确，而不是靠推断。**

**等待器会报出产物文件名**，取自 history（那是权威记录）：

```
DONE	3 output node(s): out_A_00001_.png, out_C_00001_.png, out_B_00001_.png
```

调用方从末行就知道产物叫什么，**不需要再调一次工具去查**。清单上限 6 个。

Bash 版报的是**文件数**（`3 output file(s)`）而不是节点数 ——
数节点需要括号配对，grep 做不到。两者都是对「出来了什么」的正确陈述，
只是回答的问题略有不同。

### 3.3 `http` —— 轮询一个 HTTP 地址直到匹配

适合：软件只有一个「查状态」的 HTTP 接口，没有事件流。

| 参数 | Python | PowerShell | Bash | 默认 |
|---|---|---|---|---|
| 地址 | `--url` | `-Url` | `--url` | 必填 |
| 匹配 | `--until` | `-Until` | `--until` | 空 = 只要拿到响应就算完成 |

```bash
python waiters/wait.py http --url http://127.0.0.1:9000/status --until '"state":\s*"done"'
```

> `--until` 是**正则**，`"` 之类的字符记得转义。

### 3.4 `file` —— 等文件出现 / 内容匹配

适合：软件靠**写文件**表示完成（渲染器、批处理、导出）。

| 参数 | Python | PowerShell | Bash | 默认 |
|---|---|---|---|---|
| 路径 | `--path` | `-Path` | `--path` | 必填 |
| 匹配 | `--until-match` | `-UntilMatch` | `--until-match` | 空 = 文件存在即完成 |

```bash
python waiters/wait.py file --path ./out/final.png
python waiters/wait.py file --path ./render.log --until-match 'Render complete'
```

> ⚠️ 只判「文件存在」有风险：有些程序会**先创建空文件再写入**。
> 稳妥做法是加 `--until-match`，或者先等一个 `.done` 标记文件。

### 3.5 `probe` —— 一次性探测（排错用）

不等待，只查一次，立刻返回。

```bash
python waiters/wait.py probe --url http://127.0.0.1:8188/system_stats
python waiters/wait.py probe --url http://127.0.0.1:8188/system_stats --expect 'comfyui_version'
```

用它确认「服务在不在、地址对不对、返回什么」。

---

## 4. 常驻规则（插件）配置

`plugin/no-poll.js` 往**每个会话**的系统提示里注册一个 section。
配置写在 `cordis.patch.yml` 里：

```yaml
- id: no-poll
  name: 'dsh-no-poll/plugin/no-poll.js'
  config:
    enabled: true      # false = 完全不注册（等于没装）
    order: 100         # 规则在系统提示里的位置，数字越小越靠前
    verbose: true      # false = 精简版（1930 → 326 字符）
    sectionName: 'no-poll'
    extraLines: []     # 追加你自己的行
```

### `order` 怎么选

参考 DSH 的 `SECTION_ORDERS`（来自 `@deepseek-ai/dsh-system-prompt`）：

| 名字 | 值 | 是什么 |
|---|---|---|
| `HARNESS_IDENTITY` | `-1000` | 框架身份 |
| `DEPLOYMENT_PERSONA_PREFIX` | `0` | 人格 |
| **（默认放这附近）** | **`100`** | ← 作为行为准则，紧跟人格之后 |
| `PLAN_POLICY` | `500` | 计划策略 |
| `TEAM_POLICY` | `600` | 团队策略 |
| `MCP_SERVERS` | `3100` | 工具说明 |

**`order` 必须是有限数** —— 非有限数（`NaN` / `Infinity`）会让 `section()` 抛异常。
插件对非法值会自动回落到 `100`。

### token 成本（必须知道）

| 配置 | 大小 | ≈ tokens/轮 |
|---|---|---|
| `verbose: true`（默认） | 1930 字符 | **≈ 483** |
| `verbose: false` | 326 字符 | ≈ 82 |
| `enabled: false` | 0 | 0 |

**这是每一轮都要付的。** 如果你只是偶尔跑长任务，
把 `enabled` 设 `false`，需要时手动提一句；
或者把等待器用法写进你自己的 skill（按需加载）。

### `extraLines` 用来做什么

把本机的具体信息告诉模型，省掉它一次探测：

```yaml
extraLines:
  - '本机 ComfyUI 在 http://127.0.0.1:8188，用 waiters/wait.py comfyui 等它。'
  - '本机 Blender 在 D:\steam\...\blender.exe，渲染直接 run_in_background 跑 -b。'
```

---

## 5. 典型场景：完整调用链

### 场景 A：ComfyUI 跑一个 5 分钟的视频任务

**模型侧的动作**（这就是「不要轮询」的样子）：

```
① run_workflow(wait=false)  →  拿到 prompt_id + client_id，立刻返回
② run_in_background: python waiters/wait.py comfyui --prompt-id … --client-id …
③ 结束这一轮（模型不再做任何事）
   …138 秒后…
④ 宿主通知「后台作业完成了」→ 模型被唤醒
⑤ 读作业输出末行 → DONE → 继续（取产物、质检、入库）
```

**关键**：第 ③ 步**模型真的停下来**，不是换个方式问。

### 场景 B：Blender 无头渲染

**不需要等待器** —— 直接后台跑：

```
run_in_background: blender -b scene.blend -o //out/frame_ -f 1-250
```

实测：12 帧批量渲染，`BATCH_DONE`，exit 0，**宿主在退出时唤醒模型** ✅

> 一个批处理脚本跑完所有帧，比一帧一个后台作业好 —— **一次作业，一次唤醒。**

### 场景 C：自己的软件只有 `/status` 接口

```bash
python waiters/wait.py http --url http://localhost:9000/status --until '"state":"done"'
```

---

## 6. 排错

### 6.1 「一条事件都收不到」

**按顺序查：**

1. **WebSocket 通不通？**
   ```bash
   python tests/probe-ws.py 12
   ```
   - 打印 `handshake OK` + 若干 `{"type":"status",…}` → 连通性没问题，往下查
   - 打印 `handshake FAILED` → 服务没起 / 端口不对 / 有代理

2. **`client_id` 是不是提交时那个？** ← **最常见的原因**
   随便造一个 id，你能收到广播的 `status`，但**收不到定向的 `execution_*`**。

3. **任务真的在执行吗？**
   ```bash
   curl -s http://127.0.0.1:8188/queue
   ```
   看你的 id 在 `queue_running` 还是 `queue_pending`。
   **在 `queue_pending` 就是"还没轮到它"—— 这时没有事件是正常的。**

4. **`queue_running` 里是不是个「已经产出过」的任务？**
   那是 ComfyUI 的**幻影残留**，会让后面的任务**永远排队**（实测遇到过）。
   清掉：
   ```bash
   curl -X POST http://127.0.0.1:8188/interrupt
   ```

5. **想知道完整事件序列？** 用帧转储器：
   ```bash
   python tests/dump-frames.py <clientId> <promptId> 300
   ```
   它按时间顺序打印每一帧 —— **适配新软件时就用它**。

### 6.2 「等待器立刻返回 DONE，但我没看到它跑」

那是**竞态保护**生效了 —— 你在任务已经完成后才去等它。
末行会写明 `(finished before we connected)`。这是**正确行为**，不是 bug。

### 6.3 「它报了 FAILED，但任务还在跑」

**不应该发生。** 判定逻辑只在 ComfyUI **自己**说
`status_str` 是 `error`/`failed`，或者 `completed` 带着非 success 状态时，才报 FAILED。

如果你看到相反的情况，用 `curl -s <host>/history/<id>` 抓下 payload 提 issue。

### 6.4 「模型还是轮询」

1. **插件装了吗？重启 DSH 了吗？**
2. **`order` 撞了吗？** 同一个 scope 里 `section` 重名或 order 非有限数会 **throw**，
   插件设计成**静默失效**（不让它影响会话）。所以撞了你就看不出任何提示。
   换个 `sectionName` 或 `order` 试试。
3. **模型可能只是在读它自己的旧习惯** —— 规则说「不要轮询」，但如果有别的指令
   （比如某个 skill 说"每 30 秒查一次"），那就是冲突。检查你有没有别的提示词在鼓励轮询。

### 6.5 「输出里非 ASCII 字符是乱码」

- `wait.py` 已经强制 `stdout`/`stderr` 走 UTF-8，正常不该乱码。
- **末行只含 ASCII** —— 网络错误带的是操作系统本地化文本（中文 Windows 报中文），
  所以完整信息留在 stderr 给人看，末行放稳定的 ASCII 详情。**脚本解析不受系统语言影响。**
- 如果你把输出重定向到文件，用 UTF-8 打开。

---

## 7. 行为契约（写给要改这个仓库的人）

改等待器时，请守住这几条 —— 它们是踩坑换来的：

| 契约 | 为什么 |
|---|---|
| **只能有三个状态：DONE / FAILED / 等待** | 多一个「超时」「放弃」，就等于给模型一个打断运行中任务的借口 |
| **FAILED 只能来自上游的明确判决** | 猜失败会毁掉已完成的工作，并引发无意义的重投 |
| **「查不到」不等于「不存在」** | 查询失败是「我没法问」，绝不是「它没了」。把两者混起来就会弄死正在跑的任务 |
| **完全不要「放弃」分支** | 契约就是等；**一个任务绝不该被这个进程宣告死亡** |
| **末行必须机器可读** | 调用方要能可靠解析，不能靠人读 stderr |
| **优先事件流，而非轮询** | 阻塞在推送上比定时问更省资源、延迟更低 |
| **竞态保护是强制的** | 没有它，短任务会**永远**等不到事件 —— 而且是偶发的，最难查 |
| **降级必须自报** | 静默降级会让人以为还在用事件驱动 |
| **进程内轮询可以，模型轮询不可以** | 这是整个仓库存在的理由 |

---

## 8. 相关

- [README.md](README.md) —— 为什么这么做 + 60 秒上手（中文）
- [MANUAL.md](MANUAL.md) —— English version of this document
- [examples/comfyui.md](examples/comfyui.md) —— 事件驱动适配器完整剖析
- [examples/blender.md](examples/blender.md) —— 命令行范例（**不需要**等待器）
- [examples/add-your-own.md](examples/add-your-own.md) —— 适配自己的软件
- [MCP SEP-1686 "Tasks"](https://modelcontextprotocol.io/seps/1686-tasks) —— 协议层正在做的同一件事
