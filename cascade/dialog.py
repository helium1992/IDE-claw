"""对话脚本 — 推送消息到 IDE Claw，等待用户回复

用法：
    python dialog.py "消息内容"
    python dialog.py "消息内容" --file /path/to/image.png

工作流程：
    1. 推送消息到 Push Server（手机端 + Windows桌面端 均可收到）
    2. WebSocket 监听用户回复（来自任一客户端）
    3. 收到回复 → 保存到 data/phone_response.md → 退出

供 Cascade 通过 run_command(Blocking=true) 调用。
"""
import sys
import os
import json
import time
import ssl
import threading
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)  # 上一级为项目根目录
RESPONSE_FILE = os.path.join(PROJECT_DIR, 'data', 'phone_response.md')
MEMORY_DB = os.path.join(PROJECT_DIR, 'data', 'memory.db')
VOCAB_DIR = os.path.join(PROJECT_DIR, 'data', 'vocab')
LOCK_FILE = os.path.join(PROJECT_DIR, '.ai_lock')
MODE_FILE = os.path.join(PROJECT_DIR, 'config', 'ai_mode.json')


def check_ai_lock():
    """检查AI操作锁状态，返回 (is_locked, mode_str)"""
    locked = os.path.exists(LOCK_FILE)
    mode = 'full'
    try:
        with open(MODE_FILE, 'r', encoding='utf-8') as f:
            mode = json.load(f).get('mode', 'full')
    except Exception:
        pass
    return locked or mode == 'chat_only', mode


def handle_lock_command(text):
    """处理 @lock / @unlock 命令，返回 True 如果是锁定命令"""
    cmd = text.strip().lower()
    if cmd in ('@lock', '锁定', '仅问答'):
        _run_lock('lock')
        return True
    elif cmd in ('@unlock', '解锁', '恢复操作'):
        _run_lock('unlock')
        return True
    return False


def _run_lock(action):
    """运行 ai_lock.py"""
    lock_script = os.path.join(PROJECT_DIR, 'ai_lock.py')
    if os.path.exists(lock_script):
        subprocess.run([sys.executable, lock_script, action], timeout=30)
    else:
        # 简单模式：直接创建/删除锁文件
        if action == 'lock':
            with open(LOCK_FILE, 'w') as f:
                f.write('locked')
            print("🔒 已锁定（仅问答模式）")
        else:
            if os.path.exists(LOCK_FILE):
                os.remove(LOCK_FILE)
            print("🔓 已解锁（完全操作模式）")

# 延迟加载记忆中间件（避免import失败影响基础功能）
_memory_mw = None


def get_memory_middleware():
    """懒加载记忆中间件"""
    global _memory_mw
    if _memory_mw is None:
        try:
            sys.path.insert(0, PROJECT_DIR)
            from faceted_memory.middleware import MemoryMiddleware
            _memory_mw = MemoryMiddleware(
                db_path=MEMORY_DB,
                vocab_dir=VOCAB_DIR if os.path.exists(VOCAB_DIR) else None,
                top_k=3,
                min_score=0.1,
            )
        except Exception as e:
            print(f"⚠️ 记忆系统加载失败: {e}", file=sys.stderr)
            _memory_mw = False  # 标记为加载失败，不再重试
    return _memory_mw if _memory_mw is not False else None


def save_response(action, text, source='unknown', images=None, files=None, memory_context=''):
    os.makedirs(os.path.dirname(RESPONSE_FILE), exist_ok=True)
    with open(RESPONSE_FILE, 'w', encoding='utf-8') as f:
        f.write(f"# 📱 Dialog Response\n\n")
        f.write(f"> Received: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"> Source: {source}\n\n")
        # AI操作锁：注入限制指令
        is_locked, _ = check_ai_lock()
        if is_locked:
            f.write("## 🔒 AI操作限制（仅问答模式）\n\n")
            f.write("**⚠️ 当前处于仅问答模式，严格遵守以下规则：**\n")
            f.write("1. **禁止** 调用 edit / multi_edit / write_to_file 工具\n")
            f.write("2. **禁止** 调用 run_command 工具\n")
            f.write("3. **禁止** 修改任何文件\n")
            f.write("4. **只能** 用文字回答问题\n")
            f.write("5. 如果用户要求操作，回复：'当前处于锁定模式，请先发送 @unlock 解锁'\n\n")
        f.write(f"## ACTION\n\n```\n{action}\n```\n\n")
        f.write(f"## 用户指令\n\n```\n{text}\n```\n")
        if images:
            f.write(f"\n## 📷 附件图片\n\n")
            for img in images:
                f.write(f"- `{img}`\n")
        if files:
            f.write(f"\n## 📎 附件文件\n\n")
            for fp in files:
                f.write(f"- `{fp}`\n")
        if memory_context:
            f.write(f"\n{memory_context}\n")


def extract_text(command, params_str):
    text = ''
    try:
        params = json.loads(params_str) if params_str else {}
        if isinstance(params, dict):
            text = params.get('text', str(params))
        else:
            text = str(params)
    except (json.JSONDecodeError, TypeError):
        text = params_str or ''
    return text


def download_file(server_url, token, download_url):
    """下载文件并保存到本地，返回本地路径"""
    import requests
    try:
        full_url = f"{server_url}{download_url}&token={token}" if '?' in download_url else f"{server_url}{download_url}?token={token}"
        r = requests.get(full_url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
        if r.status_code == 200:
            # 从Content-Disposition或URL提取文件名
            fname = download_url.split('/')[-1].split('?')[0]
            if 'Content-Disposition' in r.headers:
                cd = r.headers['Content-Disposition']
                if 'filename=' in cd:
                    fname = cd.split('filename=')[-1].strip('"')
            save_dir = os.path.join(PROJECT_DIR, 'data', 'received_files')
            os.makedirs(save_dir, exist_ok=True)
            save_path = os.path.join(save_dir, f"{int(time.time())}_{fname}")
            with open(save_path, 'wb') as f:
                f.write(r.content)
            return save_path
    except Exception as e:
        print(f"⚠️ 下载文件失败: {e}", file=sys.stderr)
    return None


def run_local_ipc(message, received, reply_data):
    """本地 IPC：尝试直连同一台电脑上的 IDE Claw 桌面端（localhost:13800）"""
    import requests as _req
    try:
        # 检测桌面端是否在运行
        try:
            r = _req.get('http://127.0.0.1:13800/ping', timeout=1)
            if r.status_code != 200:
                return
        except Exception:
            return  # 桌面端未运行，静默退出

        # 发送消息并长轮询等待回复
        r = _req.post(
            'http://127.0.0.1:13800/message',
            json={'message': message},
            timeout=1800,  # 30 分钟超时
        )
        if received.is_set():
            return  # 其他通道已收到回复
        if r.status_code == 200:
            data = r.json()
            text = data.get('text', '')
            action = data.get('action', 'reply')
            if text and action != 'timeout':
                reply_data['action'] = action
                reply_data['text'] = text
                reply_data['source'] = 'desktop'
                received.set()
    except Exception:
        pass  # 本地 IPC 失败，由 WebSocket 通道兜底


def _load_last_reply():
    """读取上一次响应文件中的回复文本，用于去重"""
    try:
        if not os.path.exists(RESPONSE_FILE):
            return ''
        with open(RESPONSE_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
        # 提取“用户指令”代码块内容
        marker = '## 用户指令'
        if marker in content:
            after = content.split(marker, 1)[1]
            if '```\n' in after:
                parts = after.split('```\n', 1)
                if len(parts) >= 2:
                    return parts[1].split('\n```')[0].strip()
    except Exception:
        pass
    return ''


def run_ws_listener(server_url, session_id, token, received, reply_data, push_done_time=None):
    """WebSocket 监听用户回复（手机端或桌面端均可）"""
    try:
        import websocket
    except ImportError:
        print("⚠️ websocket-client未安装，无法监听回复", file=sys.stderr)
        return

    ws_base = server_url.replace('https://', 'wss://').replace('http://', 'ws://')
    ws_url = f"{ws_base}/ws?token={token}&session_id={session_id}&role=pc"
    _debounce_sec = 3  # 连接后忽略 N 秒内到达的旧消息
    _ws_connected_time = [0]  # 记录 WS 连接成功时间
    _last_reply = _load_last_reply()  # 上一次回复内容，用于去重

    def on_message(ws, msg):
        if received.is_set():
            ws.close()
            return
        # 防抖：忽略 WS 连接后立即到达的旧消息（服务器缓冲）
        if _ws_connected_time[0] and (time.time() - _ws_connected_time[0]) < _debounce_sec:
            return
        try:
            data = json.loads(msg)
            msg_type = data.get('type', '')

            if msg_type == 'command':
                cmd_data = data.get('data', {})
                command = cmd_data.get('command', 'reply')
                params = cmd_data.get('params', '{}')
                text = extract_text(command, params)
                if not received.is_set():
                    if _last_reply and text.strip() == _last_reply:
                        return  # 去重：与上次回复相同，忽略
                    reply_data['action'] = command
                    reply_data['text'] = text
                    reply_data['source'] = 'phone'
                    received.set()
                    ws.close()

            elif msg_type == 'message':
                msg_data = data.get('data', {})
                if msg_data.get('sender') == 'mobile':
                    content = msg_data.get('content', '')
                    caption = msg_data.get('caption', '')
                    msg_sub_type = msg_data.get('msg_type', 'text')
                    has_image = msg_data.get('has_image', False)
                    download_url = msg_data.get('download_url', '')
                    file_name = msg_data.get('file_name', '')

                    if not received.is_set():
                        # Use caption as primary text if available
                        display_text = caption if caption else content
                        if _last_reply and display_text.strip() == _last_reply:
                            return  # 去重：与上次回复相同，忽略

                        reply_data['action'] = f'message_{msg_sub_type}'
                        reply_data['text'] = display_text
                        reply_data['source'] = 'phone'
                        reply_data['file_name'] = file_name

                        # Download image/file if available
                        if download_url:
                            local_path = download_file(server_url, token, download_url)
                            if local_path:
                                reply_data['file_path'] = local_path
                                if has_image:
                                    reply_data.setdefault('images', []).append(local_path)

                        received.set()
                        ws.close()
        except Exception as e:
            print(f"⚠️ WS消息解析错误: {e}", file=sys.stderr)

    def on_open(ws):
        _ws_connected_time[0] = time.time()
        def heartbeat():
            while not received.is_set():
                try:
                    ws.send(json.dumps({"type": "ping"}))
                except:
                    break
                time.sleep(15)
        threading.Thread(target=heartbeat, daemon=True).start()

    _ws_retry_count = [0]

    def on_error(ws, error):
        if not received.is_set():
            _ws_retry_count[0] += 1
            if _ws_retry_count[0] >= 3:
                print(f"⚠️ WS多次断开，仍在重连...", file=sys.stderr)
                _ws_retry_count[0] = 0

    def on_close(ws, code, msg):
        pass  # 静默断开，自动重连

    ssl_opts = {"cert_reqs": ssl.CERT_NONE}

    while not received.is_set():
        try:
            ws = websocket.WebSocketApp(
                ws_url,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close,
                on_open=on_open,
            )
            ws_thread = threading.Thread(
                target=lambda: ws.run_forever(sslopt=ssl_opts, ping_interval=20, ping_timeout=10),
                daemon=True,
            )
            ws_thread.start()
            while ws_thread.is_alive() and not received.is_set():
                received.wait(timeout=1)
            if received.is_set():
                break
            time.sleep(2)  # 快速重连
        except Exception as e:
            if not received.is_set():
                _ws_retry_count[0] += 1
                if _ws_retry_count[0] >= 3:
                    print(f"⚠️ WS连接错误，仍在重试...", file=sys.stderr)
                    _ws_retry_count[0] = 0
                time.sleep(3)


# 可存入记忆的文本文件后缀
_TEXT_EXTS = {'.md', '.txt', '.py', '.json', '.yaml', '.yml', '.toml', '.csv', '.html', '.css', '.js', '.ts', '.go', '.dart', '.sh', '.bat'}
# 文件大小上限（超过则截断存储）
_MAX_FILE_SIZE = 50000  # 50KB


def _store_file_content(mw, file_path):
    """将文本文件内容存入记忆库"""
    try:
        ext = os.path.splitext(file_path)[1].lower()
        if ext not in _TEXT_EXTS:
            return
        if not os.path.isfile(file_path):
            return
        size = os.path.getsize(file_path)
        if size == 0 or size > _MAX_FILE_SIZE * 2:
            return  # 空文件或过大文件跳过
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read(_MAX_FILE_SIZE)
        if len(content) < 20:
            return  # 内容太短，不值得存储
        fname = os.path.basename(file_path)
        summary = f"📄 文件: {fname} | {content[:120].replace(chr(10), ' ')}"
        mw.store(
            content=content,
            summary=summary,
            metadata={"type": "file", "path": file_path, "file_name": fname, "size": size}
        )
    except Exception as e:
        print(f"⚠️ 存储文件记忆失败 [{file_path}]: {e}", file=sys.stderr)


def _store_referenced_files(mw, message):
    """扫描消息中引用的文件路径，将其内容存入记忆库"""
    import re
    # 匹配常见的文件路径模式（Windows绝对路径或相对路径）
    patterns = [
        r'[A-Za-z]:[/\\][\w\-./\\]+\.\w+',  # Windows绝对路径
        r'(?:^|\s)\.?/?[\w\-]+(?:/[\w\-]+)*\.\w+',  # 相对路径
    ]
    paths = set()
    for pattern in patterns:
        for match in re.finditer(pattern, message):
            paths.add(match.group().strip())

    for p in paths:
        # 标准化路径
        p = p.replace('\\', '/')
        if not os.path.isfile(p):
            # 尝试在项目目录下查找
            alt = os.path.join(PROJECT_DIR, p)
            if os.path.isfile(alt):
                p = alt
            else:
                continue
        _store_file_content(mw, p)


def upload_file_to_phone(server_url, session_id, token, file_path, caption=''):
    """上传文件/图片到手机，使用multipart/form-data"""
    import requests
    try:
        if not os.path.isfile(file_path):
            print(f"⚠️ 文件不存在: {file_path}", file=sys.stderr)
            return False
        fname = os.path.basename(file_path)
        with open(file_path, 'rb') as f:
            files = {'file': (fname, f, 'application/octet-stream')}
            data = {'session_id': session_id, 'sender': 'pc', 'caption': caption or fname}
            headers = {'Authorization': f'Bearer {token}'}
            r = requests.post(f"{server_url}/api/files/upload", files=files, data=data, headers=headers, timeout=60)
        if r.status_code == 200:
            resp = r.json()
            if resp.get('success'):
                print(f"📎 文件已推送: {fname} ({resp.get('file_id', '')})")
                return True
            else:
                print(f"⚠️ 上传失败: {resp}", file=sys.stderr)
        else:
            print(f"⚠️ 上传失败 (HTTP {r.status_code}): {r.text[:200]}", file=sys.stderr)
    except Exception as e:
        print(f"⚠️ 上传异常: {e}", file=sys.stderr)
    return False


def main():
    if len(sys.argv) < 2:
        print('用法: python dialog.py "消息内容" [--file path]', file=sys.stderr)
        sys.exit(1)

    # 解析参数：message 和可选的 --file
    message = sys.argv[1]
    attach_files = []
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == '--file' and i + 1 < len(sys.argv):
            attach_files.append(sys.argv[i + 1])
            i += 2
        else:
            i += 1

    # 加载推送配置
    config_path = os.path.join(SCRIPT_DIR, 'config', 'push_config.json')
    server_url = session_id = token = ''
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        server_url = cfg.get('server_url', '')
        session_id = cfg.get('session_id', '')
        token = cfg.get('auth_token', '') or cfg.get('token', '')
    except Exception:
        pass

    if not (server_url and session_id and token):
        print("❌ 推送配置缺失，请编辑 cascade/config/push_config.json", file=sys.stderr)
        sys.exit(1)

    # 推送消息到 Push Server
    try:
        import requests
        _headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        # 先发stop_typing清除省略号气泡
        try:
            requests.post(
                f"{server_url}/api/push",
                json={"session_id": session_id, "content": "", "msg_type": "stop_typing"},
                headers=_headers, timeout=5,
            )
        except Exception:
            pass
        # 再发实际消息
        requests.post(
            f"{server_url}/api/push",
            json={"session_id": session_id, "content": message, "msg_type": "text", "is_final": True},
            headers=_headers, timeout=10,
        )
        # 推送附件文件/图片
        for fp in attach_files:
            upload_file_to_phone(server_url, session_id, token, fp)
    except Exception as e:
        print(f"⚠️ 推送失败: {e}", file=sys.stderr)

    received = threading.Event()
    reply_data = {}

    # 记录推送完成时间（用于 WebSocket 防抖）
    push_done_time = time.time()

    # 启动本地 IPC 线程（如果桌面端在运行，直连不绕服务器）
    t_local = threading.Thread(target=run_local_ipc, args=(message, received, reply_data), daemon=True)
    t_local.start()

    # 启动 WebSocket 监听（手机端通过此通道回复）
    t_ws = threading.Thread(target=run_ws_listener, args=(server_url, session_id, token, received, reply_data, push_done_time), daemon=True)
    t_ws.start()

    print(f"📤 消息已推送到 IDE Claw")
    print(f"⏳ 等待回复...")
    sys.stdout.flush()

    # 等待回复
    try:
        while not received.is_set():
            received.wait(timeout=1)
    except KeyboardInterrupt:
        print("\n👋 已取消", file=sys.stderr)
        sys.exit(1)

    action = reply_data.get('action', 'continue')
    text = reply_data.get('text', '')
    source = reply_data.get('source', 'unknown')
    images = reply_data.get('images', [])
    file_path = reply_data.get('file_path', '')
    files = [file_path] if file_path and file_path not in images else []

    # === 记忆中间件：自动处理 ===
    memory_context = ""
    mw = get_memory_middleware()
    if mw and text:
        try:
            # 入站：检索相关记忆
            results = mw.search_only(text)
            if results:
                memory_context = mw._format_memory_block(results)
            # 出站（上一条AI消息）：存储到记忆库
            mw.on_outgoing(message, sender="ai")
            # 出站（引用文件）：扫描消息中的文件路径，存储文件全文
            _store_referenced_files(mw, message)
            # 入站（用户回复）：存储到记忆库
            mw.on_outgoing(text, sender="user")
            # 入站（用户发送的文件）：如果是文本文件，存储内容
            if files:
                for fp in files:
                    _store_file_content(mw, fp)
        except Exception as e:
            print(f"⚠️ 记忆处理异常: {e}", file=sys.stderr)

    save_response(action, text, source, images=images or None, files=files or None,
                  memory_context=memory_context)

    print(f"\n💬 收到回复 (来源: {source}):")
    print(f"ACTION: {action}")
    print(f"内容: {text}")
    if images:
        print(f"图片: {', '.join(images)}")
    if files:
        print(f"文件: {', '.join(files)}")
    print(f"\n📄 完整响应已保存到: {RESPONSE_FILE}")
    sys.stdout.flush()


if __name__ == '__main__':
    main()
