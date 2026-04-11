const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');
const http = require('http');

const TRIGGER_FILE = 'ideclaw-session-trigger.json';
const LOG_FILE = 'ideclaw-session.log';
const FIREBASE_LOGIN_URL = 'https://your-server.example.com/api/windsurf/firebase/login';
const AUTH_TOKEN_URL = 'https://your-server.example.com/api/windsurf/auth-token';

let fileWatcher = null;
let outputChannel = null;

// ── 工具函数 ──

function getGlobalStoragePath() {
    if (process.platform === 'win32') {
        const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
        return path.join(appData, 'Windsurf', 'User', 'globalStorage');
    } else if (process.platform === 'darwin') {
        return path.join(os.homedir(), 'Library', 'Application Support', 'Windsurf', 'User', 'globalStorage');
    }
    return path.join(os.homedir(), '.config', 'Windsurf', 'User', 'globalStorage');
}

function log(msg) {
    const ts = new Date().toISOString();
    const line = `[${ts}] ${msg}`;
    if (outputChannel) outputChannel.appendLine(line);
    try {
        const logPath = path.join(getGlobalStoragePath(), LOG_FILE);
        fs.appendFileSync(logPath, line + '\n', 'utf8');
    } catch (e) { /* ignore */ }
}

function getTriggerPath() {
    return path.join(getGlobalStoragePath(), TRIGGER_FILE);
}

// ── HTTPS 请求（与插件完全相同） ──

function httpsRequest(url, options, body) {
    return new Promise((resolve, reject) => {
        const parsedUrl = new URL(url);
        const mod = parsedUrl.protocol === 'https:' ? https : http;
        const req = mod.request(parsedUrl, options, (res) => {
            const chunks = [];
            res.on('data', chunk => chunks.push(chunk));
            res.on('end', () => {
                const data = Buffer.concat(chunks);
                resolve({
                    ok: res.statusCode >= 200 && res.statusCode < 300,
                    status: res.statusCode,
                    text: () => data.toString('utf8'),
                    json: () => JSON.parse(data.toString('utf8')),
                    arrayBuffer: () => data,
                });
            });
        });
        req.on('error', reject);
        req.setTimeout(20000, () => { req.destroy(); reject(new Error('timeout')); });
        if (body) req.write(body);
        req.end();
    });
}

// ── Protobuf 编解码（与插件完全相同） ──

function buildProtobufRequest(idToken) {
    const tokenBytes = Buffer.from(idToken, 'utf8');
    const lengthBytes = [];
    let len = tokenBytes.length;
    while (len > 127) {
        lengthBytes.push((len & 0x7F) | 0x80);
        len = len >> 7;
    }
    lengthBytes.push(len);
    const requestData = Buffer.alloc(1 + lengthBytes.length + tokenBytes.length);
    requestData[0] = 0x0A;
    Buffer.from(lengthBytes).copy(requestData, 1);
    tokenBytes.copy(requestData, 1 + lengthBytes.length);
    return requestData;
}

function parseAuthTokenFromResponse(responseBytes) {
    if (responseBytes.length > 2 && responseBytes[0] === 0x0A) {
        let tLen = 0;
        let shift = 0;
        let pos = 1;
        while (pos < responseBytes.length) {
            const b = responseBytes[pos++];
            tLen |= (b & 0x7F) << shift;
            if ((b & 0x80) === 0) break;
            shift += 7;
            if (shift > 63) break;
        }
        if (tLen > 0 && pos + tLen <= responseBytes.length) {
            return responseBytes.slice(pos, pos + tLen).toString('utf8');
        }
    }
    const text = responseBytes.toString('utf8');
    const match = text.match(/[a-zA-Z0-9_$-]{30,60}/);
    return match ? match[0] : '';
}

// ── 写入 auth 文件（与插件 writeAuthFiles 完全相同） ──

function writeAuthFiles(authToken) {
    try {
        const globalStoragePath = getGlobalStoragePath();
        if (!fs.existsSync(globalStoragePath)) {
            fs.mkdirSync(globalStoragePath, { recursive: true });
        }
        const authData = {
            authToken: authToken,
            token: authToken,
            api_key: authToken,
            timestamp: Date.now()
        };
        const authJson = JSON.stringify(authData, null, 2);
        const windsurfAuthPath = path.join(globalStoragePath, 'windsurf-auth.json');
        const cascadeAuthPath = path.join(globalStoragePath, 'cascade-auth.json');
        fs.writeFileSync(windsurfAuthPath, authJson, 'utf8');
        fs.writeFileSync(cascadeAuthPath, authJson, 'utf8');
        if (fs.existsSync(windsurfAuthPath) && fs.existsSync(cascadeAuthPath)) {
            log('Auth files written and verified');
            return true;
        }
        return false;
    } catch (e) {
        log('writeAuthFiles error: ' + e.message);
        return false;
    }
}

// ── 动态发现并注入命令（与插件完全相同的过滤和尝试逻辑） ──

async function injectViaCommands(authToken) {
    try {
        const allCommands = await vscode.commands.getCommands(true);
        const authCommands = allCommands.filter(c =>
            (c.toLowerCase().includes('windsurf') || c.toLowerCase().includes('cascade')) &&
            (c.toLowerCase().includes('auth') || c.toLowerCase().includes('token'))
        ).filter(c => !c.includes('ideclaw'));  // 排除自己
        log('Found auth commands: ' + JSON.stringify(authCommands));
        for (const cmd of authCommands) {
            try {
                log('Trying: ' + cmd + ' (string)');
                await vscode.commands.executeCommand(cmd, authToken);
                log('SUCCESS: ' + cmd + ' (string)');
                return true;
            } catch (e) {
                log('FAILED: ' + cmd + ' (string) - ' + e.message);
                try {
                    log('Trying: ' + cmd + ' (object)');
                    await vscode.commands.executeCommand(cmd, { token: authToken });
                    log('SUCCESS: ' + cmd + ' (object)');
                    return true;
                } catch (e2) {
                    log('FAILED: ' + cmd + ' (object) - ' + e2.message);
                }
            }
        }
    } catch (error) {
        log('Command discovery error: ' + error.message);
    }
    return false;
}

async function executeExplicitCommand(commandId, args) {
    const command = String(commandId || '').trim();
    if (!command) {
        return {
            success: false,
            error: 'missing_command',
        };
    }
    const commandArgs = Array.isArray(args) ? args : [];
    try {
        log('Executing explicit command: ' + command + ' args=' + JSON.stringify(commandArgs));
        const result = await vscode.commands.executeCommand(command, ...commandArgs);
        log('Explicit command success: ' + command);
        return {
            success: true,
            result: result === undefined ? null : result,
        };
    } catch (error) {
        const message = error && error.message ? error.message : String(error);
        log('Explicit command failed: ' + command + ' - ' + message);
        return {
            success: false,
            error: message,
        };
    }
}

// ── 完整登录流程（与插件 handleLogin 完全相同） ──

async function performFullLogin(email, password) {
    log('=== performFullLogin START: ' + email + ' ===');

    // Step 1: Firebase 登录
    log('Step 1: Firebase login...');
    let loginResp;
    try {
        loginResp = await httpsRequest(FIREBASE_LOGIN_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer your-session-id:your-jwt-secret' },
        }, JSON.stringify({
            returnSecureToken: true,
            email: email,
            password: password,
            clientType: 'CLIENT_TYPE_WEB',
        }));
    } catch (e) {
        log('Firebase login request failed: ' + e.message);
        return false;
    }

    if (!loginResp.ok) {
        log('Firebase login failed: HTTP ' + loginResp.status);
        return false;
    }

    let idToken;
    try {
        const loginData = loginResp.json();
        idToken = loginData.idToken;
    } catch (e) {
        log('Firebase login response parse failed: ' + e.message);
        return false;
    }

    if (!idToken) {
        log('No idToken received');
        return false;
    }
    log('Got idToken (len=' + idToken.length + ')');

    // Step 2: GetOneTimeAuthToken API
    log('Step 2: GetOneTimeAuthToken API...');
    const requestData = buildProtobufRequest(idToken);
    let authTokenResp;
    try {
        authTokenResp = await httpsRequest(AUTH_TOKEN_URL, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/proto',
                'connect-protocol-version': '1',
                'Origin': 'https://windsurf.com',
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Authorization': 'Bearer your-session-id:your-jwt-secret',
            },
        }, requestData);
    } catch (e) {
        log('GetOneTimeAuthToken request failed: ' + e.message);
        return false;
    }

    if (!authTokenResp.ok) {
        log('GetOneTimeAuthToken failed: HTTP ' + authTokenResp.status);
        return false;
    }

    const responseBytes = authTokenResp.arrayBuffer();
    const authToken = parseAuthTokenFromResponse(responseBytes);
    log('Got authToken: ' + authToken.substring(0, 20) + '... (len=' + authToken.length + ')');

    if (!authToken || authToken.length < 30 || authToken.length > 60) {
        log('Invalid authToken length: ' + authToken.length);
        return false;
    }

    // Step 3: 写入 auth 文件（与插件 writeAuthFiles 完全相同）
    log('Step 3: Writing auth files...');
    const authFileWritten = writeAuthFiles(authToken);
    log('Auth files written: ' + authFileWritten);

    // Step 4: 动态发现并注入命令（与插件完全相同）
    log('Step 4: Injecting via commands...');
    const injected = await injectViaCommands(authToken);
    log('Command injection: ' + injected);

    // 成功条件：与插件完全相同 - auth文件写入成功 或 命令注入成功
    const success = authFileWritten || injected;
    log('=== performFullLogin END: success=' + success + ' ===');
    return success;
}

// ── 处理触发文件 ──

async function processTriggerFile() {
    const triggerPath = getTriggerPath();
    if (!fs.existsSync(triggerPath)) return;

    let data;
    try {
        const raw = fs.readFileSync(triggerPath, 'utf8');
        data = JSON.parse(raw);
    } catch (e) {
        log('Failed to read trigger: ' + e.message);
        return;
    }

    if (data.processed) return;

    const commandId = String(data.command || '').trim();
    if (commandId) {
        log('Processing explicit command trigger: ' + commandId);
        const commandResult = await executeExplicitCommand(commandId, data.args);
        data.processed = true;
        data.processed_at = Date.now();
        data.success = !!commandResult.success;
        data.command = commandId;
        data.command_args = Array.isArray(data.args) ? data.args : [];
        if (commandResult.success) {
            data.command_result = commandResult.result;
            delete data.error;
        } else {
            data.error = commandResult.error || 'command_failed';
        }
        try {
            fs.writeFileSync(triggerPath, JSON.stringify(data, null, 2), 'utf8');
        } catch (e) { /* ignore */ }
        log('Explicit command result for ' + commandId + ': ' + (commandResult.success ? 'SUCCESS' : 'FAILED'));
        return;
    }

    const email = data.email || '';
    const password = data.password || '';

    if (!email || !password) {
        log('Trigger file missing email or password');
        // 标记已处理
        data.processed = true;
        data.success = false;
        data.error = 'missing_credentials';
        try { fs.writeFileSync(triggerPath, JSON.stringify(data, null, 2), 'utf8'); } catch (e) { }
        return;
    }

    log('Processing trigger for: ' + email);
    const success = await performFullLogin(email, password);

    // 标记已处理
    data.processed = true;
    data.processed_at = Date.now();
    data.success = success;
    try {
        fs.writeFileSync(triggerPath, JSON.stringify(data, null, 2), 'utf8');
    } catch (e) { /* ignore */ }

    log('Result for ' + email + ': ' + (success ? 'SUCCESS' : 'FAILED'));
}

// ── 扩展激活 ──

function activate(context) {
    outputChannel = vscode.window.createOutputChannel('IDE Claw Session');
    log('IDE Claw Session Manager activated');

    // 注册手动触发命令
    const cmd = vscode.commands.registerCommand('ideclaw.refreshSession', async () => {
        log('Manual refresh triggered');
        await processTriggerFile();
    });
    context.subscriptions.push(cmd);

    // 监听触发文件变化
    const triggerPath = getTriggerPath();
    const dir = path.dirname(triggerPath);
    log('Watching: ' + triggerPath);

    try {
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        fileWatcher = fs.watch(dir, (eventType, filename) => {
            if (filename === TRIGGER_FILE) {
                setTimeout(() => processTriggerFile(), 300);
            }
        });
        context.subscriptions.push({ dispose: () => { if (fileWatcher) fileWatcher.close(); } });
    } catch (e) {
        log('File watcher error: ' + e.message);
    }

    // 启动时检查一次
    processTriggerFile();
}

function deactivate() {
    if (fileWatcher) {
        fileWatcher.close();
        fileWatcher = null;
    }
}

module.exports = { activate, deactivate };
