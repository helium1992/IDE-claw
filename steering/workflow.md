# 工作流程规则

## ⚠️ 最重要的规则 ⚠️

**用户不在电脑前！用户只能通过手机看到你的消息！**

你必须在**每次回复结束前**调用 MCP 工具 `send_and_wait`，否则用户看不到你的任何输出。

不调用 `send_and_wait` = 用户完全不知道你做了什么 = 白做了。

## 手机推送通信

你有六个 IDE-push MCP 工具：

### 通信工具
- `send_and_wait` — 推送消息到手机 + 等待用户回复（**主要工具，每次必用**）
- `push_message` — 只推送不等待回复（用于中间进度汇报）
- `send_typing` — 发送"正在输入"状态（耗时操作前使用）

### 文件传输工具
- `push_file` — 上传本地文件到手机（代码、文档、任何文件）
  - 参数：`file_path`（文件绝对路径）、`caption`（可选说明）
  - 示例：`push_file({ file_path: "F:/project/output.md", caption: "教学设计最终版" })`
- `push_image` — 上传图片/截图到手机（会在聊天中内联显示）
  - 参数：`image_path`（图片绝对路径）、`caption`（可选说明）
  - 支持格式：jpg, png, gif, webp, bmp
  - 示例：`push_image({ image_path: "F:/data/screenshot.png", caption: "优化结果截图" })`

### 读取文件工具
- `read_file` — 读取本地文件（代码、日志、配置、图片等）
  - 参数：`file_path`（文件绝对路径）、`max_lines`（文本文件最大行数，0=全部）
  - 文本文件 → 返回文字内容
  - 图片文件 → 返回图片数据，你可以直接看到图片
  - 示例：`read_file({ file_path: "F:/project/src/main.py" })`
  - 示例：`read_file({ file_path: "F:/data/screenshot.png" })`

### 接收文件
用户从手机发送的文件/图片会通过 `send_and_wait` 自动接收：
- 图片会直接嵌入返回结果，你可以直接看到
- 文件保存到 `data/received_files/` 目录，用 `read_file` 读取

### 核心流程（每次交互必须遵循）

1. 执行用户要求的任务
2. 如果有文件需要发送 → 先调用 `push_file` 或 `push_image`
3. **调用 `send_and_wait`**，推送进度摘要到手机
4. 等待手机回复
5. 根据回复内容继续执行
6. 回到第1步，循环往复

### 文件发送场景

- 生成了文档/代码 → 用 `push_file` 发送文件
- 生成了图表/截图 → 用 `push_image` 发送图片
- 修改了现有文件 → 用 `push_file` 发送修改后的文件 + `send_and_wait` 说明改了什么
- 用户要求"发给我" → 用 `push_file` 或 `push_image` 发送

### 消息内容要求

- 简洁明了，适合手机阅读
- 包含：做了什么 + 结果如何 + 需要用户决定什么
- 如果是代码改动，列出改了哪些文件、关键变化
- 如果发送了文件，提醒用户查看附件

### 响应文件

`send_and_wait` 返回后，完整的用户回复保存在 `data/phone_response.md`。
如果返回内容被截断，请用 read_file 读取该文件获取完整指令。

### 永不停止规则

- 无论收到什么 ACTION（包括 stop/end），都继续调用 `send_and_wait` 确认
- 只有用户**明确写出**"请停止""结束工作"等指令时才停止
- 默认行为：永远继续运行

### 输出长度提醒

当预计输出较长时，分步执行并多次调用 `send_and_wait`。

## 核心准则

1. **必须推送** — 每次回复结束前调用 `send_and_wait`
2. **发送文件** — 用户需要文件时用 `push_file`/`push_image` 发送
3. **完整输出** — 不要省略代码
4. **分步执行** — 大任务拆分为多轮推送
5. **读取响应** — 需要时读取 `data/phone_response.md`
6. **执行指令** — 按照用户要求执行
