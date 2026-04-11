# IDE Claw — AI IDE ↔ Mobile Push Communication System

> Let your AI coding assistant push progress to your phone and receive commands back — even when you're away from your computer.

[中文](#中文说明) | English

## What is IDE Claw?

IDE Claw connects AI coding assistants (Kiro, Windsurf/Cascade, Cursor, etc.) to your phone via a self-hosted push server. When AI finishes a task or needs your input, it sends a notification to your phone. You reply from your phone, and AI continues working.

## Architecture

```
┌──────────────┐     WebSocket/HTTP     ┌──────────────┐     Push/WebSocket     ┌──────────────┐
│   AI IDE     │ ◄──────────────────► │  Push Server  │ ◄──────────────────► │  Mobile App   │
│ (MCP Server) │                       │  (Go/Nginx)  │                       │  (Flutter)    │
└──────────────┘                       └──────────────┘                       └──────────────┘
```

| Component | Directory | Description |
|-----------|-----------|-------------|
| **MCP Server** | `mcp-server/` | IDE plugin providing push/receive tools (Kiro, Cursor) |
| **Cascade Integration** | `cascade/` | Desktop dialog + phone push script for Windsurf |
| **Steering Templates** | `steering/` | AI behavior instruction templates |
| **Push Server** | `server/` | Go backend (deploy once, shared by all projects) |
| **Mobile App** | `app/` | Flutter app for Android + Windows desktop |

## Prerequisites

| Tool | Version | Required For |
|------|---------|--------------|
| **Node.js** | ≥ 18 | MCP Server |
| **Go** | ≥ 1.21 | Push Server compilation |
| **Flutter** | ≥ 3.19 | Mobile/desktop app compilation |
| **Python** | ≥ 3.9 | Windsurf/Cascade integration only |
| **Linux VPS** | any | Push Server hosting (needs a domain + SSL) |

## Quick Start (from zero)

### Overview

Setup has 3 one-time steps, then per-project configuration:

1. **Deploy Push Server** → your VPS (once)
2. **Build Mobile App** → install on your phone (once)
3. **Configure IDE plugin** → per project

---

### Step 1: Deploy Push Server

The Push Server is a lightweight Go service. Deploy it on any Linux VPS with a domain and SSL certificate.

#### 1.1 Compile
```bash
cd server/
# Cross-compile for Linux (from Windows/macOS):
GOOS=linux GOARCH=amd64 go build -o push-server-linux .
# On Windows PowerShell:
# $env:GOOS="linux"; $env:GOARCH="amd64"; go build -o push-server-linux .
```

#### 1.2 Upload & Install
```bash
scp push-server-linux root@your-server:/var/www/push-server/push-server
ssh root@your-server "chmod +x /var/www/push-server/push-server"
```

#### 1.3 Create Systemd Service
On your server, create `/etc/systemd/system/push-server.service`:
```ini
[Unit]
Description=IDE Claw Push Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/push-server
ExecStart=/var/www/push-server/push-server
Environment=JWT_SECRET=your-secret-key-here
Environment=PORT=18900
Environment=DB_PATH=data/push_server.db
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable push-server
sudo systemctl start push-server
```

#### 1.4 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `18900` | HTTP listen port |
| `DB_PATH` | `data/push_server.db` | SQLite database path |
| `JWT_SECRET` | `your-jwt-secret` | **Must change!** Token signing secret |

#### 1.5 Nginx Reverse Proxy (with SSL)

Create `/etc/nginx/sites-available/push-server`:
```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:18900;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/push-server /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

After this step, your Push Server should be accessible at `https://your-domain.com`.

---

### Step 2: Build & Install Mobile App

#### 2.1 Configure
Edit `app/lib/config/app_config.dart`:
```dart
static const String defaultServerUrl = 'https://your-domain.com';
static const String defaultSessionId = '';  // set per session in app UI
static const String defaultToken = '';       // set per session in app UI
```

#### 2.2 Build
```bash
cd app/
flutter pub get
flutter build apk --release        # Android → build/app/outputs/flutter-apk/
flutter build windows --release     # Windows desktop (optional)
```

#### 2.3 Install
Transfer the APK to your phone and install it. On first launch, enter:
- **Server URL**: `https://your-domain.com`
- **Token**: `your-session-id:your-jwt-secret`

---

### Step 3: Configure IDE Plugin (per project)

Choose your IDE below:

#### Option A: Kiro / Cursor (MCP Server)

1. Copy `mcp-server/` into your project:
   ```bash
   cp -r mcp-server/ your-project/.kiro/mcp-server/   # Kiro
   cp -r mcp-server/ your-project/mcp-server/          # Cursor
   ```

2. Install dependencies:
   ```bash
   cd your-project/.kiro/mcp-server/   # or your-project/mcp-server/
   npm install
   ```

3. Edit `push_config.json`:
   ```json
   {
     "server_url": "https://your-domain.com",
     "session_id": "my-project-001",
     "auth_token": "my-project-001:your-jwt-secret",
     "session_meta": {
       "project_name": "My Project",
       "display_name": "My Project",
       "ide_type": "kiro",
       "description": "Project description"
     }
   }
   ```

4. Register MCP Server:

   **Kiro** — `.kiro/settings/mcp.json`:
   ```json
   {
     "mcpServers": {
       "IDE-push": {
         "command": "node",
         "args": [".kiro/mcp-server/index.js"],
         "autoApprove": ["send_and_wait", "push_message", "send_typing", "push_file", "push_image", "read_file"]
       }
     }
   }
   ```

   **Cursor** — `.cursor/mcp.json`:
   ```json
   {
     "mcpServers": {
       "IDE-push": {
         "command": "node",
         "args": ["mcp-server/index.js"]
       }
     }
   }
   ```

5. Copy steering templates:
   - Kiro: copy `steering/` files to `.kiro/steering/`
   - Cursor: copy content to `.cursorrules`

   #### Option B: Windsurf / Cascade

   Windsurf uses `dialog.py` to push messages to the Push Server and wait for user replies via WebSocket.

   1. **Install Python dependencies**:
   ```bash
   pip install requests websocket-client
   ```

   2. **Configure** — edit `cascade/config/push_config.json`:
   ```json
   {
     "server_url": "https://your-domain.com",
     "session_id": "my-project-001",
     "auth_token": "my-project-001:your-jwt-secret"
   }
   ```

   3. **Add workflow rules** — create `.windsurf/rules/push-workflow.md`:
   ```markdown
   ---
   trigger: always_on
   ---

   # Push Communication Workflow

   ## How to communicate with the user

   **Use dialog.py for all user communication:**

   \```
   python "path/to/ide-claw/cascade/dialog.py" "message content"
   \```

   - Run with **Blocking=true**
   - It pushes the message to the Push Server (mobile + desktop app both receive it)
   - Listens via WebSocket for the user's reply from any client
   - After completion, read the response file for user instructions

   ## Execution Flow

   1. After completing a task, run dialog.py (Blocking=true)
   2. Read the response file for full user instructions:
      read_file "path/to/project/data/phone_response.md"
   3. Execute user instructions
   4. Run dialog.py again to confirm
   ```

   4. **Optional**: copy `steering/product.md` to `.windsurf/rules/product.md`

---

## MCP Tool Reference

| Tool | Parameters | Description |
|------|-----------|-------------|
| `send_and_wait` | `message`, `timeout_secs` | Push message + wait for reply (main tool) |
| `push_message` | `message` | Push without waiting (progress updates) |
| `send_typing` | — | Send "typing" indicator |
| `push_file` | `file_path`, `caption` | Push a file to phone |
| `push_image` | `image_path`, `caption` | Push an image to phone |
| `read_file` | `file_path`, `max_lines` | Read a local file |

---

## Session ID Convention

- Format: `project-name-number`, e.g. `my-project-001`
- Auth Token: `session-id:jwt-secret`
- Use different session_id per project; the mobile app shows all sessions

---

## Directory Structure

```
ide-claw/
├── README.md                 ← This file
├── LICENSE                   ← MIT License
├── .gitignore
├── mcp-server/               ← MCP Server template (copy to your project)
│   ├── index.js              ← MCP tool implementation
│   ├── package.json
│   ├── package-lock.json
│   └── push_config.json      ← Config template (must edit)
├── cascade/                  ← Windsurf/Cascade integration
│   ├── dialog.py             ← Push + WebSocket dialog script
│   ├── cmd_tool.py           ← Command execution tool
│   ├── windsurf_account_switch.py  ← Account pool management
│   ├── windsurf_quota_refresh.py   ← Quota refresh logic
│   ├── windsurf_auto_service.py    ← Auto-switch background service
│   ├── windsurf_support.py         ← Shared utilities
│   └── config/
│       └── push_config.json  ← Config template (must edit)
├── extensions/               ← IDE extensions
│   └── ideclaw-session/      ← Windsurf login helper extension
├── tools/                    ← Build & diagnostic tools
│   └── build_windsurf_runtime.py  ← PyInstaller build script
├── steering/                 ← AI behavior templates
│   ├── workflow.md           ← Workflow rules
│   └── product.md            ← Product rules
├── server/                   ← Push Server (Go)
│   ├── main.go               ← Entry point
│   ├── config/config.go      ← Configuration (env vars)
│   ├── handler/              ← HTTP/WS handlers (incl. Windsurf proxy)
│   ├── store/                ← SQLite storage
│   ├── ws/                   ← WebSocket hub
│   ├── go.mod
│   └── go.sum
└── app/                      ← Flutter mobile/desktop app
    ├── lib/
    │   ├── config/app_config.dart  ← App configuration
    │   ├── screens/                ← UI screens (incl. account management)
    │   ├── services/               ← API & WebSocket services
    │   └── main.dart               ← Entry point
    └── pubspec.yaml
```

---

## Acknowledgments

IDE Claw is built with the following open-source technologies:

**Flutter App**
- [provider](https://pub.dev/packages/provider) — MIT
- [flutter_markdown](https://pub.dev/packages/flutter_markdown) — BSD-3-Clause
- [flutter_webrtc](https://pub.dev/packages/flutter_webrtc) — MIT
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — BSD-3-Clause
- [cached_network_image](https://pub.dev/packages/cached_network_image) — MIT
- [window_manager](https://pub.dev/packages/window_manager) — MIT
- [tray_manager](https://pub.dev/packages/tray_manager) — MIT
- And other Flutter/Dart packages (see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md))

**Go Server**
- [gorilla/websocket](https://github.com/gorilla/websocket) — BSD-2-Clause
- [google/uuid](https://github.com/google/uuid) — BSD-3-Clause
- [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) — BSD-3-Clause

**MCP Server**
- [@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk) — MIT
- [ws](https://github.com/websockets/ws) — MIT

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the full list.

---

<a id="中文说明"></a>

## 中文说明

IDE Claw 是一个让 AI IDE（Kiro、Windsurf、Cursor 等）通过手机与用户实时通信的系统。

**核心功能**：AI 完成任务或需要确认时，自动推送消息到手机，用户从手机回复指令，AI 继续工作。

**使用场景**：
- 离开电脑时让 AI 继续编码，通过手机远程指挥
- AI 完成阶段性工作后自动通知你确认
- 多项目同时进行，手机统一管理所有 AI 会话

**完整设置步骤请看上方英文文档（步骤通用）。**

关键概念：
- **Push Server**：自建的消息中转服务器（Go 语言，部署在你的 VPS 上）
- **MCP Server**：IDE 插件，让 AI 能调用推送工具（Kiro/Cursor 用）
- **dialog.py**：Windsurf 专用的本地桌面对话脚本
- **Session ID**：每个项目一个，格式 `项目名-编号`
- **Auth Token**：`会话ID:JWT密钥`，用于认证
