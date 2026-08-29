# ClaudeChat 目标迁移架构

> 文档状态：已吸收 2026-08-19 用户确认的迁移范围与全部架构决策。本文描述**目标架构和验收契约**，不表示当前代码已经全部符合。除后期平台最低版本外，本轮产品级决策已关闭；当前实现与本文不一致之处均视为待迁移或待修复项。

## 1. 总体原则

Flutter 统一负责 Android/iOS 的 UI、导航、状态、领域模型、SQLite 持久化、API 客户端、工具、导入导出和测试。Kotlin/Swift 仅承担 Flutter 无法直接实现的操作系统能力。

目标版本必须遵守以下范围规则：

1. 旧 HTML 项目已有功能全部复原，不以新版新增功能抵消旧功能缺失。
2. 已纳入的新功能中，所有已知且可复现的缺陷均需修复后才能验收。
3. 工具箱的定义、开关、执行逻辑、审批和安全语义以旧项目为准；记忆删除保持旧版逐次审批，其余旧工具不新增审批。
4. UI 先复用旧源码的明确参数，再校准跨渲染引擎差异。理论目标为 99%，最终视觉结论以用户真机/实测为准；达不到 99% 的状态必须逐项登记。
5. 数据存储采用新项目已经建立的 SQLite、app-private 文件和 Secure Storage 架构；这属于跨框架必要适配，不要求退回浏览器 localStorage/IndexedDB 作为主数据源。
6. 用户已确认不把旧项目既有安全风险的清理作为本轮迁移目标，并要求新移动端恢复任意 HTTP、SSRF 可达性、同源 opener 和 unrestricted WebView。该高风险兼容边界必须登记；工作区代码是否可访问主数据库和 Secure Storage 仍需明确。
7. 日历、提醒、通知、小组件、铃声和语音识别不纳入本轮功能验收；声音仍纳入。

## 2. 应用私有数据目录

运行时在平台 Application Support 下创建 app-private `claudechat/`：

```text
claudechat/
├── database/claudechat.sqlite3
├── data/
│   ├── conversations/
│   ├── memories/
│   ├── diary/
│   ├── files/
│   ├── workspaces/
│   ├── settings/
│   ├── reminders/
│   └── voices/
├── attachments/
├── files/
├── fonts/
├── icons/
├── temp/
└── import-staging/
```

- SQLite 是事务主索引；分类目录是可恢复、可导出的数据镜像或二进制载体。
- 声音 profile 元数据进入 SQLite；生成的声音文件必须实际保存在 `data/voices/`，数据库只保存相对路径、hash、大小、格式和绑定关系。
- 用户文件、工作区文件、附件、声音、字体和图标必须在备份中携带实际内容，不能只导出数据库引用。
- API key 和语音 API key 的运行时主副本保存在 Keychain/Android Keystore，不进入普通 SQLite 字段。

## 3. API 与模型配置

### 3.1 API profile

- 保留多个聊天 API profile 和多个语音 API profile。
- 取消 Vercel proxy 开关、字段、说明、分支和相关遗留配置；移动端直接请求配置的供应商 endpoint。
- “获取模型”在 API 设置界面只显示获取到的模型数量，但结果必须写回当前 API profile，并在重启后保持。
- 获取结果应按模型 ID 去重；再次获取时更新当前 profile 的模型集合，不生成重复模型项。

### 3.2 API key UI

- 聊天和语音 API key 默认显示为一串不可见圆点。
- 每个 key 输入区提供“显示 key”复选框；勾选后显示真实值，并允许选择、复制和编辑。
- 取消勾选后立即恢复掩码；页面切换或重新进入设置时默认恢复为不可见。
- 读取、显示、复制和编辑从 Secure Storage 获取的真实值时，不得写入日志、异常、分析事件或普通设置表。
- API key 只进入加密备份的 secret payload，不进入明文 manifest/JSON Lines。导入先解密并写回 Secure Storage，用户不重复输入各 API key；导入后 key 立即可用于请求，勾选显示复选框可正常读取明文、复制和编辑。

### 3.3 模型槽位

- 初始保留 Sonnet、Opus、Haiku 三个旧版槽位。
- 在 Settings → Models 的 Haiku 槽位后增加“添加模型”入口。
- 槽位总数最多 5 个，即旧版 3 个固定槽位加最多 2 个用户新增槽位；达到 5 个后隐藏或禁用新增入口，避免破坏现有 UI。
- 每个槽位可选择 API profile 和该 profile 已持久化的真实模型 ID。
- temperature/top-p/frequency penalty/presence penalty/max tokens 默认分别为 `.7/1/0/0/4096`。
- 每个参数允许设为 `None`，表示不向供应商发送该字段；是否可用取决于供应商和模型能力。
- 模型选择、参数、stream、上下文预算和当前槽位均需持久化并进入完整备份。

### 3.4 本地演示

旧项目的无 API 本地演示回复纳入迁移范围。未配置 endpoint/模型时必须保持可用的本地演示流程，同时明确其不请求真实模型。

## 4. 工具箱契约

- 19 个旧聊天工具和 2 个工作区工具的名称、JSON Schema、默认开关、最大 10 轮工具循环、可见胶囊和结果语义以旧项目为准。
- 只有旧版 `delete_memory` 要求逐次用户审批；审批文案、通知和执行/拒绝状态按旧版复原。
- 其他旧工具不因新架构文档而增加逐次审批。
- 私密会话继续只允许旧版定义的无状态安全子集，并确保不落盘。
- 新增原生工具不改变旧工具迁移验收结果；新增工具的缺陷属于新版功能缺陷范围，必须单独修复和验收。

## 5. 文件、工作区与代码运行

### 5.1 持久化与 localStorage

- “Ta的文件”和工作区仍以 SQLite/app-private 文件为主数据源。
- 文件运行容器必须启用 JavaScript 和持久 localStorage。
- localStorage 使用两级隔离：独立文件按 file ID；工作区按 workspace ID，工作区内文件共享。再次运行必须能读取之前的数据。
- 导出页提供“包含运行数据/localStorage”复选框，由用户决定是否备份和跨设备恢复；选择写入 manifest。

### 5.2 运行类型

验收范围要求文件和工作区能够运行或执行：

- HTML/CSS/JavaScript；
- React 项目或 React 源码；
- Python；
- Java。

HTML/JS/React 在本地工作区沙箱执行；React 必须支持 JSX/TSX、npm 安装、项目构建和运行，不能只支持预构建静态产物。Python/Java 采用“本地优先 + 沙箱”方向；本地嵌入、WASM/解释器和远程回退的边界见第 12 节。

### 5.3 兼容和风险边界

- 为还原旧功能，运行页面不再按“纯静态、无存储 preview”验收；脚本执行和 localStorage 是必需能力。
- 沙箱内允许访问任意外网、CDN、npm、Maven、PyPI，支持依赖安装和一定程度的 vibe coding。
- 恢复任意 HTTP、SSRF 可达性、同源 opener、脚本和 unrestricted WebView。旧行为风险已接受，但沙箱是否能读取 ClaudeChat 主数据库、API keys、其他工作区和 app-private 文件仍需明确。
- Android/iOS 对动态代码、JIT 和运行时有平台限制；无法等价实现时逐项列出，不得以“预览成功”代替“运行成功”。

## 6. 附件

- 应用层不设置固定的单文件或单次选择大小上限，移除现有 20MB/40MB 业务限制和旧版 30MB 限制。
- 文件以流式复制方式写入 app-private 存储，避免整文件常驻内存。
- 仍需处理设备剩余空间、操作系统 picker、文件系统和模型供应商 API 的客观限制；这些是外部能力边界，不应伪装成“无限”。
- 供应商拒绝超大附件时保留本地并弹出选择：取消/更换、尝试分块或转文本（若支持）、仅保留本地；不能静默截断或替用户决定。

## 7. 完整备份契约

### 7.1 覆盖范围

完整导出必须包含所有可恢复内容：

- settings、API profiles、模型槽位和所有 API key；
- conversations、messages、message parts；
- 消息内容、思考、usage、反馈、分支关系、上下文折叠、胶囊状态、工具调用请求/参数/结果/错误/审批状态、消息发送/流式/完成/错误/停止状态；
- memories、diary entries/versions、user files/versions、workspaces/files/messages；
- attachments 及实际二进制；
- voice profiles、voice assets、收藏/绑定关系及实际声音文件；
- reminders、platform bindings、fonts、icons；
- revisions、tombstones、必要的冲突和导入审计数据；
- 文件运行容器的 localStorage（仅在用户导出时勾选包含）。

数据库行、引用和实际文件必须保持一致；导出时应建立同一事务快照或等价的一致性快照。

### 7.2 容器与校验

- `.claudechat` 为 ZIP 容器，含 manifest、每表 JSON Lines、实际文件和 SHA-256 checksum。
- secret payload 使用 Argon2id + AES-256-GCM 加密；API key 不允许进入未加密数据区。
- 导入顺序为容器/checksum 验证 → 获取解密凭据 → 解密 secrets → 校验 → 事务合并普通数据并写入 Secure Storage。导入后不得要求用户重新逐个输入 API key。
- 跨设备解密采用用户备份密码还是恢复密钥仍需第 12 节决策。

### 7.3 合并导入

- 导入只能合并，不能无条件替换整库。
- 完全相同的记录通过规范化内容 hash 判定并跳过。
- 相同 ID 只能保留一个主记录，禁止产生多条相同主键数据。
- incoming revision 更高时更新；更低时保留本机。
- revision 相同但内容不同，比较 `updated_at`；时间更新的一方更新主记录。
- revision 和时间均相同但内容不同，两份都保留：本机记录保持唯一主记录，导入版本进入冲突/修订历史，保存 original entity ID、来源 backup/device 和完整内容；主表不得产生重复 ID。
- tombstone 参与同一比较规则，避免被较旧备份错误复活或重复删除。
- 不可变版本通过稳定 ID/content hash 去重；同 ID 异内容登记冲突。
- `backupId` 只用于幂等和审计，不能作为“遇到同 ID 全部跳过”的理由。

## 8. 旧版导入与旧项目备份升级

- 新项目继续合并导入旧 v1/v2 JSON。
- 已经生成的旧 v2 文件从未包含 `userFiles`/`workspaces` 时，缺失内容无法事后恢复。
- 旧 HTML Web 项目新增 full exporter，不能改变既有 v2 文件的历史含义。
- 旧 Web 直接输出与新项目相同的加密 `.claudechat`：包含 `userFiles`、`workspaces`、完整消息/胶囊/工具状态、API profiles/keys、所有版本、附件内容、用户选择包含的 localStorage，以及 revision/updatedAt/contentHash/originDeviceId/tombstone。
- 本轮采用旧 Web → 新 Flutter 的单向迁移：旧 Web full exporter 与新项目 importer 使用相同的去重和同 ID 更新规则；不要求旧 Web 反向导入新版 `.claudechat`。

## 9. 视觉迁移契约

1. 先逐项复制旧源码明确给出的颜色、字体、字号倍率、间距、圆角、最大宽度、断点、safe-area 和交互时长。
2. 只有源码无法确定，或相同参数在 DOM 与 Flutter 中表现不一致时，才用同环境实测校准。
3. 固定 viewport、DPR、字体、主题、种子数据、页面状态和滚动位置，依次核对内容、结构/semantics、几何、样式和截图差分。
4. 理论视觉目标为 99%；最终是否通过由用户真机/实测决定，不以单一自动化像素分数替代。
5. 未达 99% 的每个页面/状态必须记录：旧/新截图、相似度、差异位置、原因、已尝试方法、预计上限和已知限制。
6. 不允许用新增功能、平均分或不可见区域的高相似度掩盖核心页面明显差异。

## 10. 平台边界

- Android 包名和 iOS bundle 标识保持 `com.susuclaude.app`。
- Android 最低 SDK、target SDK 和 iOS 最低版本暂不在本轮冻结，等待后续决策。
- 系统 picker、权限和分享属于本轮平台适配。通知、日历、提醒、铃声、Widget 和语音识别不纳入本轮功能验收。
- iOS 对下载代码、JIT、Java/Python 运行时和任意脚本执行的限制必须在文件运行方案中单独验证。

## 11. 当前已知实现差距

以下项目是目标契约与当前源码的已知差距，后续实现必须处理：

- 生产默认模型槽位为空，Settings → Models 没有可用新增入口；最大 5 槽尚未实现。
- API“获取模型”没有持久化结果。
- Vercel proxy UI/设置仍存在。
- 聊天/语音 key 的统一掩码、显示复选框和复制/编辑闭环尚未按本契约验收。
- 声音 profile 删除调用不支持表的通用 softDelete。
- 当前工具审批文档/实现曾与旧版语义不一致，必须以第 4 节为准统一。
- 当前附件仍有 20MB/40MB 等限制。
- 当前 HTML preview 禁持久化存储和网络，不能满足第 5 节运行契约。
- Java、Python、React 的产品方向已确定为“本地优先的工作区沙箱 + 用户主动选择远程沙箱回退”；具体 runtime、协议和平台实现仍需技术设计与验证。
- 按工作区保存依赖缓存、显示占用并提供手动清理尚未实现。
- unrestricted 工作区与 ClaudeChat 主数据库、Secure Storage/API key、其他工作区及未授权 app-private 文件之间的强制隔离边界尚未实现和验收。
- 完整备份是否覆盖所有细粒度消息/胶囊/工具状态和运行 localStorage 需要 schema 与测试审计。
- 当前启动时长、视觉相似度和全量当前提交测试证据尚未达到最终验收要求。

## 12. 运行架构解释与已确认决策

### 12.1 本地 + 沙箱

“本地”表示代码在手机执行；“沙箱”表示运行时限制代码可访问的资源。两者可以同时成立。

- **本地原生运行时：** 内嵌 CPython/JVM/编译器/Node-compatible 工具链；离线和响应好，但包体/磁盘大、原生依赖复杂，iOS 动态代码限制明显。
- **本地 WASM/解释器：** 隔离和跨平台较好，但性能、系统 API、原生 PyPI/Maven 包兼容受限。
- **远程沙箱：** 最接近桌面 Node/JDK/Python 和完整依赖生态，但需要网络、服务器和上传代码。

Apple App Review Guideline 2.5.2 对下载、安装或执行会引入/改变 App 功能的代码有限制，因此 iOS 上的任意 npm/Maven/PyPI 安装与执行还需单独做分发合规验证：[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

目标当前定义为本地优先的工作区沙箱：HTML/JS/React 本地构建运行；Python 优先本地嵌入或 WASM；Java 在 Android 可探索本地方案，iOS 可能需要受限解释器/WASM 或远程回退。

### 12.2 Flutter Web

Flutter Web 是把新项目的 Dart/Flutter UI 编译成浏览器 JavaScript/Canvas 应用。它不是旧 HTML 项目。当前新项目的 Web 入口主要用于视觉审计；若正式支持 Web，还需为 SQLite、Secure Storage、文件目录、原生能力和 CORS 提供浏览器替代实现。

Flutter 官方将 Web 定义为同一代码库的浏览器目标，可使用 JavaScript/Canvas/WebAssembly；这并不会自动为移动端专属 API 提供 Web 实现：[Flutter Web support](https://docs.flutter.dev/platform-integration/web)。

更新旧 HTML Web 的完整导出器并不要求新 Flutter 应用正式支持 Web。已确认 Flutter Web 当前阶段只作视觉审计，不作为新版正式浏览器产品。

### 12.3 已确认决策

1. **备份解密凭据：** 使用用户设置的备份密码，密钥派生采用 Argon2id。导入时只要求输入备份密码，不要求重新输入 API key；解密后的 API key 必须写入对应安全设置并可直接使用、显示、复制和编辑。忘记备份密码时不提供绕过解密的恢复路径。
2. **远程沙箱回退：** Java/Python/React 等本地运行能力不足时，仅由用户主动选择远程沙箱。应用不得自动上传代码、文件、依赖、localStorage 或工作区数据；选择前必须明确告知上传范围、服务端保留策略和网络边界。
3. **平台差异：** 允许 Android、iOS 及其他目标平台因系统能力不同采用不同 runtime 或回退路径。每项差异必须逐条列出受影响功能、原因、替代实现、限制和预计一致度，不得以“平台限制”笼统结案。
4. **unrestricted 工作区边界：** “unrestricted”仅表示当前工作区内部可按运行契约读写文件和数据、使用该工作区 localStorage、同源 opener 及允许的任意网络访问。运行环境必须禁止访问 ClaudeChat 主数据库、Secure Storage/API key、其他工作区和未授权的 app-private 文件；不得借助路径穿越、链接、进程能力、WebView bridge 或网络回调绕过边界。
5. **依赖缓存：** npm、Maven、PyPI 等依赖按工作区保留，并提供用户主动的手动清理入口。清理前应显示目标工作区、缓存类别与占用；清理不得影响其他工作区或 ClaudeChat 主数据。
6. **Flutter Web 定位：** 当前阶段仅作为视觉审计工具，不是正式交付平台，也不要求为生产 Web 单独适配业务能力。它可用于固定视口截图、参数核对和视觉差异比较，但最终移动端结论仍以用户实机验收为准。
7. **迁移方向：** 采用单向兼容：旧 HTML Web 提供完整加密导出，新 Flutter 应用解密并按合并规则导入；旧 Web 反向导入新版备份不在本轮范围内。
8. **平台最低版本：** Android/iOS 最低支持版本留待平台基线阶段确定，不阻塞本轮产品范围和架构决策冻结。
9. **工作区归档暂缓门槛：** 当前只实现普通对话归档。进入下一轮工作区开发前，必须先提醒并与用户确认工作区归档的数据模型、列表入口、详情内容、恢复规则和导入导出语义；未经该次确认不得直接补做工作区归档。

## 13. 验收出口

- 旧功能缺失数为 0。
- 纳入范围的新功能已知可复现 bug 为 0。
- 核心配置、聊天、工具、数据、导入导出、声音和文件运行均通过重启/重复导入/异常路径测试。
- 自动视觉以 99% 为理论目标；用户实测结论为最终结论；所有未达 99% 的状态有逐项例外记录。
- 实现、测试和交付说明必须与本文件的已确认决策一致；平台最低版本后续单独确认，不得用开发默认值替代尚未确定的平台基线。
