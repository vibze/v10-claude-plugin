#!/usr/bin/env node
// V10 browser MCP server — stdio JSON-RPC 2.0 transport.
// Bridges Claude Code tool calls to the V10 Mac app's per-tab WKWebView
// via a unix-domain socket whose path is in $V10_BROWSER_SOCK.
//
// The server starts in any shell; tool calls return a clean error when
// $V10_BROWSER_SOCK is absent (i.e. not inside a V10 tab) or when V10
// is not running.

import { createConnection } from 'net';
import { createInterface } from 'readline';

const SOCK = process.env.V10_BROWSER_SOCK;

// ---- V10 client (persistent socket, id-correlated request/response) ----
let sock = null;
let sockReady = null;
let nextV10Id = 1;
const pending = new Map();
let v10Buffer = '';

function connectV10() {
  if (!SOCK) {
    return Promise.reject(new Error('V10_BROWSER_SOCK is not set — this MCP server only works inside a V10 tab.'));
  }
  if (sock && !sock.destroyed) return Promise.resolve(sock);
  if (sockReady) return sockReady;
  sockReady = new Promise((resolve, reject) => {
    const s = createConnection(SOCK);
    s.once('connect', () => resolve(s));
    s.once('error', (e) => {
      sockReady = null;
      reject(e);
      failAllPending(e);
    });
    s.on('data', (chunk) => {
      v10Buffer += chunk.toString('utf8');
      let nl;
      while ((nl = v10Buffer.indexOf('\n')) >= 0) {
        const line = v10Buffer.slice(0, nl);
        v10Buffer = v10Buffer.slice(nl + 1);
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        const p = pending.get(msg.id);
        if (p) { pending.delete(msg.id); p(msg); }
      }
    });
    s.on('close', () => {
      sock = null;
      sockReady = null;
      failAllPending(new Error('V10 closed the browser socket.'));
    });
    sock = s;
  });
  return sockReady;
}

function failAllPending(err) {
  for (const [, cb] of pending) cb({ ok: false, error: err.message });
  pending.clear();
}

async function callV10(op, args) {
  const conn = await connectV10();
  const id = nextV10Id++;
  return new Promise((resolve, reject) => {
    pending.set(id, (msg) => {
      if (msg && msg.ok) resolve(msg.result);
      else reject(new Error((msg && msg.error) || 'V10 op failed'));
    });
    conn.write(JSON.stringify({ id, op, args: args || {} }) + '\n');
  });
}

// ---- MCP server (stdio JSON-RPC 2.0) ----
const TOOLS = [
  {
    name: 'navigate',
    description: 'PREFERRED browser tool when V10_BROWSER_SOCK is set (i.e. inside a V10 tab). Navigate this tab\'s embedded WKWebView window to a URL. Opens the window if not already open. Waits for the page load to finish. Use this instead of browsermcp / playwright / puppeteer in V10 sessions — it is sandboxed per-tab and does not touch the user\'s real browser.',
    inputSchema: {
      type: 'object',
      properties: { url: { type: 'string', description: 'Absolute URL to load.' } },
      required: ['url'],
    },
  },
  {
    name: 'eval_js',
    description: 'PREFERRED in V10 tabs. Evaluate JavaScript in this tab\'s embedded WKWebView and return the result (JSON-encoded). Use this instead of browsermcp\'s JS evaluation in V10 sessions.',
    inputSchema: {
      type: 'object',
      properties: { code: { type: 'string', description: 'JavaScript expression or block. Last expression value is returned.' } },
      required: ['code'],
    },
  },
  {
    name: 'screenshot',
    description: 'PREFERRED in V10 tabs. Take a PNG screenshot of this tab\'s embedded WKWebView window. Returns a base64-encoded image. Use this instead of browsermcp\'s screenshot in V10 sessions.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'snapshot',
    description: 'PREFERRED in V10 tabs. Compact structured-text outline (tag/role/accessible name) of visible elements in this tab\'s embedded WKWebView. Cheaper than a screenshot for LLM consumption. Use this instead of browsermcp\'s snapshot in V10 sessions.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'ensure_window',
    description: 'Open the V10 browser window if it is not already open. Returns whether it was just created.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_window_info',
    description: 'Get current V10 browser window size, screen size (visible/full), backing scale factor, and active user agent. Useful before resizing or to confirm the device profile.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'resize',
    description: 'Resize the V10 browser window content area. Clamped to the current screen\'s visible frame (excludes menu bar / Dock). Response reports the actually-applied size and whether clamping was hit.',
    inputSchema: {
      type: 'object',
      properties: {
        width: { type: 'number', description: 'Target content width in points.' },
        height: { type: 'number', description: 'Target content height in points.' },
      },
      required: ['width', 'height'],
    },
  },
  {
    name: 'set_device',
    description: 'Switch the V10 browser to a device profile — sets a matching User-Agent AND resizes the window in one call. Profiles: "desktop" (1280x800, default UA), "mobile" (390x844, iPhone Safari UA), "tablet" (820x1180, iPad Safari UA). Use this for responsive-design testing.',
    inputSchema: {
      type: 'object',
      properties: {
        profile: {
          type: 'string',
          enum: ['desktop', 'mobile', 'tablet'],
          description: 'Device profile to apply.',
        },
      },
      required: ['profile'],
    },
  },
  {
    name: 'tap',
    description: 'Click on an element using real synthetic NSEvents (fires real mousedown/mouseup/click + focus, not just el.click()). Target shapes: {text: "Sign in"} (finds smallest visible element containing text), {role: "button", name: "Submit"}, {selector: "#login"}, or {xy: [x, y]} for raw coordinates. PREFERRED for any clicking in V10 web testing.',
    inputSchema: {
      type: 'object',
      properties: {
        target: {
          type: 'object',
          description: 'Target descriptor. One of: {text}, {role, name?}, {selector}, {xy: [x,y]}.',
        },
      },
      required: ['target'],
    },
  },
  {
    name: 'type',
    description: 'Type text into the focused field using real synthetic key events. Optionally pass `target` to tap into the field first.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string' },
        target: { type: 'object', description: 'Optional target to tap before typing.' },
      },
      required: ['text'],
    },
  },
  {
    name: 'key',
    description: 'Press a named key as a real synthetic NSEvent. Known names: enter, return, tab, escape, backspace, delete, space, arrow_up/down/left/right (or up/down/left/right), home, end, pageup, pagedown.',
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' } },
      required: ['name'],
    },
  },
  {
    name: 'scroll',
    description: 'Scroll the page by (dx, dy) pixels.',
    inputSchema: {
      type: 'object',
      properties: {
        dx: { type: 'number', default: 0 },
        dy: { type: 'number', default: 0 },
      },
    },
  },
  {
    name: 'wait_for',
    description: 'Wait until an element matching `target` is visible, up to `timeout_ms`. Use before interacting with elements that appear after navigation or an XHR.',
    inputSchema: {
      type: 'object',
      properties: {
        target: { type: 'object' },
        timeout_ms: { type: 'number', default: 5000 },
      },
      required: ['target'],
    },
  },
  {
    name: 'read',
    description: 'Read the text content of a target element (trimmed). Use this for asserting copy or grabbing a value.',
    inputSchema: {
      type: 'object',
      properties: { target: { type: 'object' } },
      required: ['target'],
    },
  },
  {
    name: 'console_logs',
    description: 'Return captured console.log/info/warn/error/debug messages from the V10 browser window (including window.error and unhandledrejection). Each entry: {t, level, msg}. Use this to diagnose JS errors during a test flow. Optionally pass {clear: true} to reset the buffer after reading.',
    inputSchema: {
      type: 'object',
      properties: { clear: { type: 'boolean', default: false } },
    },
  },
  {
    name: 'network_logs',
    description: 'Return captured fetch + XMLHttpRequest requests made by the page since the buffer was last cleared. Each entry: {t, method, url, status, ms, err}. (Resource loads like CSS/images are not captured — only fetch/XHR.) Optionally pass {clear: true} to reset after reading.',
    inputSchema: {
      type: 'object',
      properties: { clear: { type: 'boolean', default: false } },
    },
  },
  {
    name: 'run',
    description: 'Execute a batch of actions in one call (mobai-style DSL). Each step is either a string (op with no args, e.g. "screenshot") or an object — `{tap: {text: "Sign in"}}` shorthand, or full `{op: "tap", args: {target: {...}}}`. Returns per-step results; stops at the first failure. Use this for multi-step flows to cut round-trips.',
    inputSchema: {
      type: 'object',
      properties: {
        steps: {
          type: 'array',
          items: {},
          description: 'Ordered list of steps. Available ops: navigate, tap, type, key, scroll, wait_for, read, screenshot, snapshot, resize, set_device, get_window_info, ensure_window, close_window.',
        },
      },
      required: ['steps'],
    },
  },
  {
    name: 'close_window',
    description: 'Close the V10 browser window. The MCP session stays alive; the next navigate/ensure_window call reopens it.',
    inputSchema: { type: 'object', properties: {} },
  },
];

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function mcpResult(tool, result) {
  if (tool === 'screenshot' && result && result.png_base64) {
    return {
      content: [
        { type: 'image', data: result.png_base64, mimeType: 'image/png' },
      ],
    };
  }
  let text;
  if (typeof result === 'string') {
    text = result;
  } else if (tool === 'snapshot' && result && typeof result.outline === 'string') {
    text = result.outline;
  } else {
    text = JSON.stringify(result, null, 2);
  }
  return { content: [{ type: 'text', text }] };
}

async function handleRequest(req) {
  const id = req.id;
  const isNotification = id === undefined || id === null;
  try {
    if (req.method === 'initialize') {
      send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'v10-browser', version: '0.2.0' },
        },
      });
    } else if (req.method === 'notifications/initialized' || req.method === 'initialized') {
      // no-op
    } else if (req.method === 'tools/list') {
      send({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
    } else if (req.method === 'tools/call') {
      const { name, arguments: args } = req.params || {};
      const result = await callV10(name, args || {});
      send({ jsonrpc: '2.0', id, result: mcpResult(name, result) });
    } else if (req.method === 'ping') {
      send({ jsonrpc: '2.0', id, result: {} });
    } else if (!isNotification) {
      send({
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: 'Method not found: ' + req.method },
      });
    }
  } catch (e) {
    if (!isNotification) {
      send({
        jsonrpc: '2.0',
        id,
        error: { code: -32000, message: String(e && e.message || e) },
      });
    }
  }
}

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try { msg = JSON.parse(trimmed); } catch { return; }
  if (Array.isArray(msg)) msg.forEach(handleRequest);
  else handleRequest(msg);
});
process.stdin.on('end', () => process.exit(0));
