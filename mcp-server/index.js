#!/usr/bin/env node
/**
 * Helium Push MCP Server
 * 
 * Provides send_and_wait / push_message tools for IDE-to-mobile communication.
 * Works with Kiro, Windsurf, Cursor, or any MCP-compatible IDE.
 * 
 * Desktop dialog: PowerShell WinForms (Windows)
 * Phone channel: WebSocket + HTTP push via Push Server
 */

const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { z } = require('zod');
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const { spawn } = require('child_process');
const WebSocket = require('ws');
const os = require('os');

// ─── Config ───────────────────────────────────────────────────────
const CONFIG_SEARCH_PATHS = [
  path.join(__dirname, 'push_config.json'),
  path.join(__dirname, '..', '..', 'config', 'push_config.json'),
];

let CONFIG = null;
for (const p of CONFIG_SEARCH_PATHS) {
  if (fs.existsSync(p)) {
    CONFIG = JSON.parse(fs.readFileSync(p, 'utf8'));
    break;
  }
}
if (!CONFIG) {
  process.stderr.write('ERROR: push_config.json not found\n');
  process.exit(1);
}

const SERVER_URL = CONFIG.server_url;
const SESSION_ID = CONFIG.session_id;
const AUTH_TOKEN = CONFIG.auth_token;
const DATA_DIR = path.join(__dirname, '..', '..', 'data');
const RESPONSE_FILE = path.join(DATA_DIR, 'phone_response.md');
const RECEIVED_DIR = path.join(DATA_DIR, 'received_files');

// ─── HTTP helpers ─────────────────────────────────────────────────
function httpRequest(urlStr, options, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const mod = url.protocol === 'https:' ? https : http;
    const req = mod.request(url, {
      method: options.method || 'GET',
      headers: options.headers || {},
      timeout: options.timeout || 15000,
      rejectUnauthorized: false,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    if (body) req.write(body);
    req.end();
  });
}

async function pushToPhone(content, msgType = 'text') {
  const headers = {
    'Authorization': `Bearer ${AUTH_TOKEN}`,
    'Content-Type': 'application/json',
  };
  const payload = JSON.stringify({
    session_id: SESSION_ID,
    content,
    msg_type: msgType,
    is_final: msgType === 'text',
  });
  return httpRequest(`${SERVER_URL}/api/push`, { method: 'POST', headers, timeout: 10000 }, payload);
}

async function downloadFile(downloadUrl) {
  try {
    const fullUrl = downloadUrl.includes('?')
      ? `${SERVER_URL}${downloadUrl}&token=${AUTH_TOKEN}`
      : `${SERVER_URL}${downloadUrl}?token=${AUTH_TOKEN}`;
    const headers = { 'Authorization': `Bearer ${AUTH_TOKEN}` };
    
    return new Promise((resolve, reject) => {
      const url = new URL(fullUrl);
      const mod = url.protocol === 'https:' ? https : http;
      mod.get(url, { headers, rejectUnauthorized: false, timeout: 30000 }, (res) => {
        const chunks = [];
        res.on('data', c => chunks.push(c));
        res.on('end', () => {
          const buf = Buffer.concat(chunks);
          let fname = downloadUrl.split('/').pop().split('?')[0];
          const cd = res.headers['content-disposition'];
          if (cd && cd.includes('filename=')) {
            fname = cd.split('filename=').pop().replace(/"/g, '');
          }
          fs.mkdirSync(RECEIVED_DIR, { recursive: true });
          const savePath = path.join(RECEIVED_DIR, `${Date.now()}_${fname}`);
          fs.writeFileSync(savePath, buf);
          resolve(savePath);
        });
      }).on('error', reject);
    });
  } catch (e) {
    process.stderr.write(`Download failed: ${e.message}\n`);
    return null;
  }
}

// ─── Multipart upload helper ──────────────────────────────────────
function uploadFile(filePath, caption) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${SERVER_URL}/api/files/upload`);
    const mod = url.protocol === 'https:' ? https : http;
    const boundary = '----MCP' + Date.now().toString(36);
    const fileName = path.basename(filePath);
    const fileData = fs.readFileSync(filePath);

    // Build multipart body
    const parts = [];
    // session_id field
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="session_id"\r\n\r\n${SESSION_ID}`);
    // sender field
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="sender"\r\n\r\npc`);
    // caption field
    if (caption) {
      parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="caption"\r\n\r\n${caption}`);
    }
    // file field header
    const fileHeader = `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${fileName}"\r\nContent-Type: application/octet-stream\r\n\r\n`;
    const tail = `\r\n--${boundary}--\r\n`;

    const preBody = Buffer.from(parts.join('\r\n') + '\r\n' + fileHeader, 'utf8');
    const postBody = Buffer.from(tail, 'utf8');
    const totalLength = preBody.length + fileData.length + postBody.length;

    const req = mod.request(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${AUTH_TOKEN}`,
        'Content-Type': `multipart/form-data; boundary=${boundary}`,
        'Content-Length': totalLength,
      },
      timeout: 60000,
      rejectUnauthorized: false,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch (_) {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('upload timeout')); });
    req.write(preBody);
    req.write(fileData);
    req.write(postBody);
    req.end();
  });
}

// ─── Save response ────────────────────────────────────────────────
function saveResponse(action, text, source, images, files) {
  fs.mkdirSync(path.dirname(RESPONSE_FILE), { recursive: true });
  let md = `# 📱 Dialog Response\n\n`;
  md += `> Received: ${new Date().toLocaleString('zh-CN')}\n`;
  md += `> Source: ${source}\n\n`;
  md += `## ACTION\n\n\`\`\`\n${action}\n\`\`\`\n\n`;
  md += `## 用户指令\n\n\`\`\`\n${text}\n\`\`\`\n`;
  if (images && images.length) {
    md += `\n## 📷 附件图片\n\n`;
    images.forEach(img => { md += `- \`${img}\`\n`; });
  }
  if (files && files.length) {
    md += `\n## 📎 附件文件\n\n`;
    files.forEach(fp => { md += `- \`${fp}\`\n`; });
  }
  fs.writeFileSync(RESPONSE_FILE, md, 'utf8');
}

// ─── Desktop dialog (Node.js Web Dialog) ──────────────────────────
function showDesktopDialog(message) {
  return new Promise((resolve) => {
    const dialogScript = path.join(__dirname, 'dialog-server.js');
    const resultFile = path.join(os.tmpdir(), '_dialog_result.json');

    // Remove old result
    try { fs.unlinkSync(resultFile); } catch (_) {}

    const child = spawn('node', [
      dialogScript, '--message', message, '--result-file', resultFile
    ], { stdio: ['pipe', 'pipe', 'pipe'] });

    child.stderr.on('data', d => process.stderr.write(d));

    child.on('close', () => {
      try {
        if (fs.existsSync(resultFile)) {
          const data = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
          resolve({
            action: data.action || 'continue',
            feedback: data.feedback || '',
            source: 'desktop',
            images: data.images || [],
            files: data.files || [],
          });
        } else {
          resolve(null);
        }
      } catch (e) {
        process.stderr.write(`Dialog parse error: ${e.message}\n`);
        resolve(null);
      }
    });

    child.on('error', (err) => {
      process.stderr.write(`Dialog error: ${err.message}\n`);
      resolve(null);
    });
  });
}

// ─── Phone WebSocket listener ─────────────────────────────────────
function listenPhoneWS(abortSignal) {
  return new Promise((resolve) => {
    if (abortSignal.aborted) return resolve(null);

    const wsBase = SERVER_URL.replace('https://', 'wss://').replace('http://', 'ws://');
    const wsUrl = `${wsBase}/ws?token=${AUTH_TOKEN}&session_id=${SESSION_ID}&role=pc`;

    let resolved = false;
    let ws;

    function finish(data) {
      if (resolved) return;
      resolved = true;
      try { ws.close(); } catch (_) {}
      resolve(data);
    }

    abortSignal.addEventListener('abort', () => finish(null));

    function connect() {
      if (resolved) return;

      ws = new WebSocket(wsUrl, { rejectUnauthorized: false });

      const heartbeat = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'ping' }));
        }
      }, 15000);

      ws.on('open', () => {
        process.stderr.write('[WS] Phone channel connected\n');
      });

      ws.on('message', async (raw) => {
        if (resolved) return;
        try {
          const data = JSON.parse(raw.toString());

          if (data.type === 'command') {
            const cmdData = data.data || {};
            const command = cmdData.command || 'reply';
            const params = cmdData.params || '{}';
            let text = '';
            try {
              const p = JSON.parse(params);
              text = typeof p === 'object' ? (p.text || JSON.stringify(p)) : String(p);
            } catch (_) { text = params; }

            finish({ action: command, text, source: 'phone' });
          }

          if (data.type === 'message') {
            const msgData = data.data || {};
            if (msgData.sender === 'mobile') {
              const content = msgData.content || '';
              const caption = msgData.caption || '';
              const msgSubType = msgData.msg_type || 'text';
              const hasImage = msgData.has_image || false;
              const downloadUrl = msgData.download_url || '';

              const result = {
                action: `message_${msgSubType}`,
                text: caption || content,
                source: 'phone',
                images: [],
                files: [],
              };

              if (downloadUrl) {
                const localPath = await downloadFile(downloadUrl);
                if (localPath) {
                  if (hasImage) result.images.push(localPath);
                  else result.files.push(localPath);
                }
              }

              finish(result);
            }
          }
        } catch (e) {
          process.stderr.write(`[WS] Parse error: ${e.message}\n`);
        }
      });

      ws.on('close', () => {
        clearInterval(heartbeat);
        if (!resolved) {
          process.stderr.write('[WS] Disconnected, reconnecting in 3s...\n');
          setTimeout(connect, 3000);
        }
      });

      ws.on('error', (err) => {
        clearInterval(heartbeat);
        process.stderr.write(`[WS] Error: ${err.message}\n`);
      });
    }

    connect();
  });
}

// ─── MCP Server ───────────────────────────────────────────────────
const server = new McpServer({
  name: 'IDE-push',
  version: '1.0.0',
});

// Tool: send_and_wait
server.tool(
  'send_and_wait',
  'Push a message to mobile phone and wait for reply via WebSocket. Returns the user reply.',
  { message: z.string().describe('Message content to send to the user') },
  async ({ message }) => {
    // 1. Send stop_typing + message to phone
    try {
      await pushToPhone('', 'stop_typing');
    } catch (_) {}
    try {
      await pushToPhone(message, 'text');
    } catch (e) {
      process.stderr.write(`Push failed: ${e.message}\n`);
    }

    // 2. Wait for phone reply via WebSocket
    const abortController = new AbortController();
    const result = await listenPhoneWS(abortController.signal);

    const action = result?.action || 'continue';
    const text = result?.text || '';
    const source = result?.source || 'unknown';
    const images = result?.images || [];
    const files = result?.files || [];

    // 3. Save response file
    saveResponse(action, text, source, images, files);

    // 4. Build return content (with inline images for MCP)
    const contentItems = [];

    let returnText = `ACTION: ${action}\nSource: ${source}\n`;
    if (text) returnText += `\nUser reply:\n${text}\n`;
    if (files.length) returnText += `\nFiles:\n${files.map(f => `- ${f}`).join('\n')}\n`;
    returnText += `\nFull response saved to: ${RESPONSE_FILE.replace(/\\/g, '/')}`;
    contentItems.push({ type: 'text', text: returnText });

    // Embed received images as base64 so the AI can see them
    for (const imgPath of images) {
      try {
        const imgData = fs.readFileSync(imgPath);
        const base64 = imgData.toString('base64');
        const ext = path.extname(imgPath).toLowerCase();
        const mimeMap = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp' };
        const mimeType = mimeMap[ext] || 'image/png';
        contentItems.push({ type: 'image', data: base64, mimeType });
        process.stderr.write(`[send_and_wait] Embedded image: ${path.basename(imgPath)} (${imgData.length} bytes)\n`);
      } catch (e) {
        contentItems.push({ type: 'text', text: `[Image load failed: ${imgPath}] ${e.message}` });
      }
    }

    return { content: contentItems };
  }
);

// Tool: push_message (fire and forget)
server.tool(
  'push_message',
  'Push a message to the mobile phone without waiting for a reply.',
  { message: z.string().describe('Message content to push') },
  async ({ message }) => {
    try {
      await pushToPhone('', 'stop_typing');
    } catch (_) {}
    try {
      await pushToPhone(message, 'text');
      return { content: [{ type: 'text', text: 'Message pushed to phone successfully.' }] };
    } catch (e) {
      return { content: [{ type: 'text', text: `Push failed: ${e.message}` }] };
    }
  }
);

// Tool: send_typing
server.tool(
  'send_typing',
  'Send typing indicator to show the mobile app that AI is working.',
  {},
  async () => {
    try {
      await pushToPhone('...', 'typing');
      return { content: [{ type: 'text', text: 'Typing indicator sent.' }] };
    } catch (e) {
      return { content: [{ type: 'text', text: `Failed: ${e.message}` }] };
    }
  }
);

// Tool: push_file (upload a file to the phone)
server.tool(
  'push_file',
  'Upload a local file to the mobile phone. Use this when you need to send code files, documents, or any file to the user. The file will appear as a downloadable attachment in the phone app.',
  {
    file_path: z.string().describe('Absolute path to the local file to upload'),
    caption: z.string().default('').describe('Caption or description for the file (leave empty to use filename)'),
  },
  async ({ file_path, caption }) => {
    process.stderr.write(`[push_file] Called with: ${file_path}, caption: ${caption}\n`);
    try {
      if (!fs.existsSync(file_path)) {
        process.stderr.write(`[push_file] File not found: ${file_path}\n`);
        return { content: [{ type: 'text', text: `File not found: ${file_path}` }] };
      }
      const stats = fs.statSync(file_path);
      process.stderr.write(`[push_file] File size: ${stats.size} bytes\n`);
      if (stats.size > 100 * 1024 * 1024) {
        return { content: [{ type: 'text', text: `File too large (${(stats.size / 1024 / 1024).toFixed(1)}MB). Max 100MB.` }] };
      }
      process.stderr.write(`[push_file] Starting upload...\n`);
      const result = await uploadFile(file_path, caption || path.basename(file_path));
      process.stderr.write(`[push_file] Upload result: ${result.status}\n`);
      if (result.status === 200 && result.body.success) {
        return { content: [{ type: 'text', text: `File sent to phone: ${path.basename(file_path)} (${result.body.file_id})` }] };
      } else {
        return { content: [{ type: 'text', text: `Upload failed (${result.status}): ${JSON.stringify(result.body)}` }] };
      }
    } catch (e) {
      process.stderr.write(`[push_file] Error: ${e.message}\n${e.stack}\n`);
      return { content: [{ type: 'text', text: `Upload error: ${e.message}` }] };
    }
  }
);

// Tool: push_image (upload an image/screenshot to the phone)
server.tool(
  'push_image',
  'Upload a local image or screenshot to the mobile phone. The image will be displayed inline in the phone app chat.',
  {
    image_path: z.string().describe('Absolute path to the image file (jpg/png/gif/webp/bmp)'),
    caption: z.string().default('').describe('Caption for the image (leave empty for default)'),
  },
  async ({ image_path, caption }) => {
    process.stderr.write(`[push_image] Called with: ${image_path}, caption: ${caption}\n`);
    try {
      if (!fs.existsSync(image_path)) {
        process.stderr.write(`[push_image] Image not found: ${image_path}\n`);
        return { content: [{ type: 'text', text: `Image not found: ${image_path}` }] };
      }
      const ext = path.extname(image_path).toLowerCase();
      const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
      if (!imageExts.includes(ext)) {
        return { content: [{ type: 'text', text: `Not an image file: ${ext}. Supported: ${imageExts.join(', ')}` }] };
      }
      const result = await uploadFile(image_path, caption || 'Screenshot');
      if (result.status === 200 && result.body.success) {
        return { content: [{ type: 'text', text: `Image sent to phone: ${path.basename(image_path)} (${result.body.file_id})` }] };
      } else {
        return { content: [{ type: 'text', text: `Upload failed (${result.status}): ${JSON.stringify(result.body)}` }] };
      }
    } catch (e) {
      return { content: [{ type: 'text', text: `Upload error: ${e.message}` }] };
    }
  }
);

// Tool: read_file (read a local file, return text or image)
server.tool(
  'read_file',
  'Read a local file. For text files, returns the file content as text. For image files (jpg/png/gif/webp/bmp), returns the image data so you can see it. Use this to read code, logs, config files, or view screenshots/images on the local machine.',
  {
    file_path: z.string().describe('Absolute path to the file to read'),
    max_lines: z.number().default(0).describe('Max lines to return for text files (0 = all)'),
  },
  async ({ file_path, max_lines }) => {
    process.stderr.write(`[read_file] Reading: ${file_path}\n`);
    try {
      if (!fs.existsSync(file_path)) {
        return { content: [{ type: 'text', text: `File not found: ${file_path}` }] };
      }
      const stats = fs.statSync(file_path);
      if (stats.size > 10 * 1024 * 1024) {
        return { content: [{ type: 'text', text: `File too large: ${(stats.size / 1024 / 1024).toFixed(1)}MB (max 10MB)` }] };
      }

      const ext = path.extname(file_path).toLowerCase();
      const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.ico', '.svg'];

      if (imageExts.includes(ext)) {
        // Return image as base64
        const imgData = fs.readFileSync(file_path);
        const base64 = imgData.toString('base64');
        const mimeMap = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp', '.ico': 'image/x-icon', '.svg': 'image/svg+xml' };
        const mimeType = mimeMap[ext] || 'image/png';
        process.stderr.write(`[read_file] Image: ${path.basename(file_path)} (${imgData.length} bytes)\n`);
        return { content: [
          { type: 'text', text: `Image: ${path.basename(file_path)} (${imgData.length} bytes)` },
          { type: 'image', data: base64, mimeType },
        ] };
      } else {
        // Return text content
        let text = fs.readFileSync(file_path, 'utf8');
        if (max_lines > 0) {
          const lines = text.split('\n');
          if (lines.length > max_lines) {
            text = lines.slice(0, max_lines).join('\n') + `\n... (${lines.length - max_lines} more lines)`;
          }
        }
        process.stderr.write(`[read_file] Text: ${path.basename(file_path)} (${text.length} chars)\n`);
        return { content: [{ type: 'text', text: `File: ${file_path}\n---\n${text}` }] };
      }
    } catch (e) {
      process.stderr.write(`[read_file] Error: ${e.message}\n`);
      return { content: [{ type: 'text', text: `Read error: ${e.message}` }] };
    }
  }
);

// Start
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[IDE-push] MCP Server started (session: ${SESSION_ID})\n`);
}

// Global error handlers to prevent silent crashes
process.on('uncaughtException', (err) => {
  process.stderr.write(`[IDE-push] Uncaught exception: ${err.message}\n${err.stack}\n`);
});
process.on('unhandledRejection', (reason) => {
  process.stderr.write(`[IDE-push] Unhandled rejection: ${reason}\n`);
});

main().catch(e => {
  process.stderr.write(`Fatal: ${e.message}\n`);
  process.exit(1);
});
