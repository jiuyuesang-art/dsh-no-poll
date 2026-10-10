<div align="center">

# dsh-no-poll

**别让 AI 轮询长任务 —— 让宿主唤醒它。**

一个 agent 背后的等待机制：把「等」从模型手里拿走，交给后台进程。<br>
装完常驻，ComfyUI / 渲染农场 / 任何异步任务都能直接用。

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)](#平台支持)
[![Runtime](https://img.shields.io/badge/runtime-Python%20%C2%B7%20PowerShell%20%C2%B7%20Bash-green)](#平台支持)
[![Deps](https://img.shields.io/badge/dependencies-zero-brightgreen)](#平台支持)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

**文档语言**：README 和 [说明书](MANUAL.zh-CN.md) 有中文版；
其余文件（脚本 / 示例 / skill / 英文手册）**全部英文**，注释也不例外 —— 避免跨平台编码问题。

</div>

---

## 问题：模型在「等」这件事上白烧 token

你让 agent 跑一个长任务。它提交完，然后：

```
模型：好了没？  →  工具：还没
模型：好了没？  →  工具：还没
模型：好了没？  →  工具：还没
… 重复 40 分钟
```

**每一次询问都是一次完整往返**：请求、上下文、响应、推理。而**任务耗时不会因为多问而变短**。

更糟的是，如果它用「调用超时」来判断，还会**误判** —— 超时 ≠ 失败，任务可能还在跑。
**而误判的代价是：它可能去把正在跑的任务打断。**

---

## 解法：三层，缺一不可

```
① 提交任务，拿到 id，立刻返回     ← 不要阻塞在提交那一步
② 用一个「等待器」挂到后台作业上   ← 进程去等，不是模型去等
③ 等待器退出时，宿主唤醒模型       ← 模型不需要问，是被通知的
```

**等待期间模型 turn 数 = 0。**

> 这个模式**不需要协议支持** —— 它用的是宿主本来就有的「后台作业 + 完成通知」能力。
> 在 DSH 里就是 `run_in_background` + 完成时自动通知。

### 为什么这件事值得单独拿出来

MCP 正在用 **[SEP-1686 "Tasks"](https://modelcontextprotocol.io/seps/1686-tasks)** 从协议层解决同一个问题 ——
**说明这是公认痛点**。但在那之前，你的 agent 已经在白烧 token 了。

**而解法不需要等协议。**

---

## 退出契约：**只有三个状态**

```
0  DONE     成功 —— 系统明确报告完成
1  FAILED   失败 —— 系统明确报告失败；或连不上系统且重试耗尽
   （不退出）等待 —— 进程一直阻塞。这是默认且正常的状态
```

### 🔴 没有超时，也没有「放弃」

**排队中、慢、看起来卡死 —— 都一直等。**

### 🔴 `FAILED` 的判定是严格的

**只有两种情况**才会报失败：

1. **上游系统自己说失败了**（ComfyUI 报 `error` / `failed`，或 `execution_interrupted`）
2. **完全连不上**，且重试耗尽（默认重试 2 次，间隔 2.5 分钟）

**绝不会**因为下面这些报失败：

- 任务慢
- 任务在排队
- 某一次查询失败（网络抖了）
- history 里暂时查不到

**为什么这么严**：误判失败的代价是**丢掉已经完成的工作**，或者**重复提交**。
而更糟的是 —— **模型会因此去打断一个还在跑的任务**。

---

## 60 秒上手

### 装（DSH）

1. 把这个仓库放到 DSH 能解析的位置（或 `npm install dsh-no-poll`）
2. 在 DSH 里说：**「安装插件包 dsh-no-poll」**
3. **重启 DSH**

装完之后，**规则常驻** —— 不管你用哪个预设、开哪个会话，模型都知道「长任务不要轮询」。

> 它不创建预设，是**常驻层**：跟预设正交，互不干扰。

### 用（两个真实例子）

**ComfyUI —— 事件驱动，收到实时进度**

```bash
python waiters/wait.py comfyui --prompt-id <ID> --client-id <CID>
```

实测输出：

```
waiting for ComfyUI job b2794a88-... (event-driven)
   ... 5/25
   ... 10/25
   ... 15/25
   ... 20/25
   ... 25/25
  [DONE] 137.9s, 1 output node(s)
```

**而模型这边**：提交任务 → 挂上等待器 → **结束这一轮**。
138 秒后它被唤醒，全程 **0 次询问**。

**命令行程序 —— 根本不需要等待器**

```bash
ffmpeg -i in.mp4 -vf scale=1920:-1 out.mp4     # 直接 run_in_background 跑它
blender -b scene.blend -o //out/frame_ -f 1-250  # 同理（已实测：12 帧批量，宿主在退出时唤醒）
```

> **大部分情况不需要等待器。**
> 只有「提交 → 排队 → 异步完成」的软件（ComfyUI、渲染农场……）才需要 ——
> 因为任务**不在你的进程里**，你没法 `wait` 它。
>
> 判断标准一句话：**任务在不在你手里。**

**已实测的软件**

| 软件 | 类型 | 需要等待器吗 |
|---|---|---|
| **ComfyUI** | 提交-排队-异步 | ✅ 需要（事件驱动） |
| **Blender**（`-b` 无头） | 命令行 | ❌ **不需要**，`run_in_background` 直接跑 |
| ffmpeg / 编译 / 训练脚本 | 命令行 | ❌ 不需要 |

### 多输出工作流：能正确定位到最后一个输出

**一个工作流里有多个输出节点**（比如 3 个 `SaveImage`）时，ComfyUI 的事件序列是：

```
[122.0s] executing   node=9
[122.2s] executed    node=9     output={images: [...]}
[122.2s] executing   node=92
[122.5s] executed    node=92    output={images: [...]}
[122.5s] executing   node=91
[122.8s] executed    node=91    output={images: [...]}
[122.8s] execution_success      ← ★ ComfyUI 自己的成功判决
[122.8s] executing   node=NULL  ← 整轮结束
```

**三个输出全部完成之后**才发结束标记 —— 所以等待 `node=NULL` 就是等全部输出 ✅

**而且等待器不只报个数，直接给你文件名**（从 history 取，那是权威记录）：

```
DONE	3 output node(s): out_A_00001_.png, out_C_00001_.png, out_B_00001_.png
```

**模型拿到末行就知道产物叫什么，不用再调一次工具去查。**

> bash 版报的是**文件数**（`3 output file(s)`）而不是节点数 ——
> 数节点需要括号配对，grep 做不到。两者都是对"出来了什么"的正确陈述。
> 文件名上限 6 个，超出会截断。

### ★ 顺带发现的 `execution_success`

ComfyUI 除了 `execution_error`，还会发 **`execution_success`** ——
**一个明确的成功判决**，正好是错误事件的对称物。

现在**两条都会触发结束**（哪个先到算哪个）：

| 事件 | 判定 |
|---|---|
| `execution_success` | **DONE**（系统明确报成功） |
| `executing` 且 `node=null` | **DONE**（兜底，也是整轮结束） |
| `execution_error` | **FAILED** |
| `execution_interrupted` | **FAILED** |

**成功和失败现在同样明确** —— 不靠推断。

---

## 平台支持

| 平台 | 事件驱动（WebSocket） | 连不上时降级 | 依赖 |
|---|---|---|---|
| **`wait.py`** — Python | ✅ **实测通过** | ✅ | 无（标准库） |
| **`wait.ps1`** — PowerShell 7+ | ✅ **实测通过** | ✅ | 无（.NET 自带 `ClientWebSocket`） |
| **`wait.sh`** — Bash | ✅ **实测通过** | ✅ | 无（`/dev/tcp` + `dd`/`od`） |

**三个平台都是事件驱动的** —— 包括 bash。

**关于 Bash**：bash 用 `/dev/tcp` 开原始 TCP，再自己实现 WebSocket 协议。
之所以可行，靠两个事实：

1. **服务端→客户端的帧不加掩码**（RFC 6455）—— 所以没有掩码要剥，只需读帧头和负载
2. **`read -u FD` 在非可寻址描述符上逐字节读，不会多读**；
   `dd bs=1 count=N <&FD` 精确读 N 字节 —— 两者都对着**真 ComfyUI** 验证过

实测：`... 5/25 ... 10/25 ... 15/25 ... 20/25 ... 25/25 → [DONE] 148s` ✅

> 代价说明：`dd bs=1` 约 80 KB/s。ComfyUI 的消息很小（`status` ~100 B、`progress` ~80 B、
> `executed` 200–2000 B），**一帧约 1–25 ms** —— 对等待器完全无所谓。
> 代码按 **bash 3.2**（macOS 自带版本）写，所以不能用 `read -N`、`mapfile`、关联数组。

**`/dev/tcp` 不可用时**（bash 编译时没开 net redirections）会自动退化成轮询，**并且明确告知**。

> 三个脚本**接口一致**：同样的子命令、同样的参数名、同样的退出码、同样的末行格式。
> 换平台不用重学。

---

## 🔴 三条纪律（写给模型，也写进了常驻规则）

**违反任何一条，这套机制就白做了。**

### 1. 不设超时

等待器**根本没有超时选项**，这是刻意的。

**为什么**：超时会让模型觉得"我有兜底"，于是：

```
"等了 10 分钟还没动静，肯定是挂了" → 超时退出 → 宣布失败 / 重试 / 去打断
```

**但任务可能只是慢。** 重试会**重复提交**，宣布失败会**丢掉成果**，
去打断会**真的把任务杀掉**。

### 2. 等待器沉默 = 正常等待，**不要去打断它**

**不要**为了"看看还在不在"去调 `job status` / `job cancel`，也不要给上游软件发 `interrupt`。

**任务结束（成功或失败）时你一定会被通知**，不需要你去查。

> 本仓库开发时就遇到过：一个 ComfyUI 任务**已经写出了输出**，但队列里还挂着它。
> 当时第一反应是 `interrupt` 清掉 —— **如果那是正在跑的渲染，就白跑了。**

### 3. 完成和失败都会唤醒你

宿主是在**作业退出**时通知的，**跟退出码无关** —— 所以 `DONE`(0) 和 `FAILED`(1)
**都是终态，都会推**。

**被唤醒后读末行就知道是哪种**：

```
DONE	3 output node(s): out_A_00001_.png, out_B_00001_.png  → 成功，产物文件名直接给你
FAILED	CUDA out of memory                                  → 系统报告失败 → 排错，别盲目重试
```

> 注意：**等待器沉默不代表失败**。它只在等到**明确结局**时才退出 ——
> 没退出就是还在等，这是正常的。

---

## 等待器接口

```
wait.py comfyui --prompt-id ID --client-id CID [--host H] [--port P] [--poll]
wait.py http    --url URL [--until REGEX] [--interval S]
wait.py file    --path P [--until-match REGEX]
wait.py probe   --url URL [--expect REGEX]
```

（`wait.ps1` / `wait.sh` 同名参数，见 [说明书](MANUAL.zh-CN.md)）

**末行是机器可读的**：`DONE\t<detail>` —— 方便脚本直接 `case` 判断。

---

## ⚠️ 必须说清的限制

| 限制 | 说明 |
|---|---|
| **依赖宿主的后台作业能力** | 这个模式要求宿主持有「后台作业 + 完成通知」。DSH 有（`run_in_background`）。别的框架得先确认 |
| **常驻规则要付 token** | 插件往系统提示注入一段规则 —— 默认 1930 字符 ≈ **483 tokens/轮**。嫌贵就把 `verbose` 设 `false`（326 字符 ≈ 82 tokens），或 `enabled: false` 整个关掉 |
| **没有超时 = 进程不会自己退出** | 这是**刻意**的。需要终止就由**人**去终止（那是"等待"状态下的操作者决定），而不是让模型有借口去打断任务 |
| **不是所有软件都能真推送** | 有事件流的（ComfyUI）能阻塞在事件上；只有 HTTP 状态的只能在**进程内轮询**（仍远好于模型轮询） |
| **ComfyUI 必须传 `--client-id`** | 它的执行事件是**定向发送**的（源码 `execution.py` 里带 `server.client_id`），**用随机 id 连上去一条事件都收不到**。不传会退化成轮询并警告 |
| **只在 Windows 11 实测过** | macOS / Linux 理论可行但**未实测**（代码按 bash 3.2 写，兼容性考虑过，但没有实际跑过） |

---

## 适配你自己的软件

**这个仓库真正的价值不是那三个脚本，是那个模式。**

给你自己的软件加适配器，通常只要回答三个问题：

```
① 提交：怎么发起任务、拿回什么 id？
② 完成：有没有事件流？（有 → 阻塞在它上面；没有 → 轮询状态接口）
③ 结局：怎么区分 成功 / 失败 / 还在跑？ → DONE / FAILED / 继续等
```

**可以直接让 AI 帮你写** —— 见 [examples/add-your-own.md](examples/add-your-own.md)，
那里有一段可以直接粘给 AI 的提示词模板，以及一个完整的适配器骨架。

现成的例子：

- [examples/comfyui.md](examples/comfyui.md) —— 事件驱动型（WebSocket + 定向事件 + 竞态保护）
- [examples/blender.md](examples/blender.md) —— 命令行型（**根本不需要等待器**）

---

## 仓库结构

```
dsh-no-poll/
├─ cordis.patch.yml          常驻规则怎么挂进 DSH
├─ plugin/no-poll.js         把规则注入每个会话的系统提示
├─ waiters/
│   ├─ wait.py               ★ 跨平台首选（事件驱动）
│   ├─ wait.ps1              Windows 原生（事件驱动）
│   └─ wait.sh               POSIX（事件驱动，纯 bash WebSocket）
├─ tests/
│   ├─ dry-run.mjs           插件离线干跑（33 项）
│   ├─ probe-ws.py           WebSocket 连通性排错
│   └─ dump-frames.py        ★ 按时间转储一轮的所有帧（适配新软件时用）
├─ examples/
│   ├─ comfyui.md            事件驱动适配器范例
│   ├─ blender.md            命令行范例（不需要等待器）
│   └─ add-your-own.md       ★ 让 AI 帮你适配
├─ MANUAL.zh-CN.md           ★ 完整说明书 · 中文（参数 / 退出契约 / 排错 / 行为契约）
├─ MANUAL.md                 同一份说明书的英文版
└─ README.md                 ← 你在这里（中文）
```

---

## 排错

**等待器一条事件都收不到？**

1. 先确认 WebSocket 通不通：
   ```bash
   python tests/probe-ws.py 12
   ```
   能收到 `{"type":"status",…}` 说明握手和帧解析都对。
2. **确认 `client_id` 是提交时那个** —— 这是最常见的坑。
3. **确认任务真的在执行**（不是排在别人后面）：
   ```bash
   curl -s http://127.0.0.1:8188/queue
   ```
   `pending` 里的就是还没轮到它，**没有事件是正常的**。
4. 如果 `queue_running` 里是个**已经产出过**的任务，那是 ComfyUI 的幻影残留，
   会让后面的任务永远排队 —— `curl -X POST http://127.0.0.1:8188/interrupt` 清掉。

**模型还是轮询不行？**

- 插件装了吗、DSH 重启了吗
- `order` 有没有和别的 section 撞（撞了会 throw，插件静默失效 —— 换 `sectionName` 或 `order`）
- **有没有别的指令在鼓励轮询**（比如某个 skill 说"每 30 秒查一次"）—— 那是直接冲突

---

## 背景：为什么不做成 MCP 服务器

因为 **MCP 层解决不了这个问题**：

```
MCP 工具是同步的
  → 工具调用要么阻塞（模型干等），要么立即返回（那就得有人告诉它「好了」）
  → 「告诉它」这件事只能由宿主做，MCP 服务器做不到
```

做成 MCP 只是把轮询换了个位置（变成 `wait_for_job` 工具调用），**没解决问题**。

**等待不该在工具层解决，要在宿主层解决。**

---

## License

[MIT](LICENSE)。随便用，包括商用。

**如果这个仓库帮你省下了 token，给个 ⭐ 就够了。**
