#!/usr/bin/env node
// Development stand-in for the Mac app: serves the browser client and streams
// an ffmpeg test pattern using the same wire protocol as StreamServer.swift.
// Lets you work on Sources/ReverseDuet/Web on any OS.
//
//   node tools/mock-server.mjs [--port 7280] [--codec h264|jpeg] [--code 1234] [--size 1280x800]
//
// Input events received from the browser are printed as JSON lines.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith('--') ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), []),
);
const PORT = Number(args.port || 7280);
const CODEC = args.codec === 'jpeg' ? 'jpeg' : 'h264';
const CODE = args.code ?? '1234';
const [WIDTH, HEIGHT] = (args.size || '1280x800').split('x').map(Number);
const FPS = Number(args.fps || 30);
const WEB = join(dirname(fileURLToPath(import.meta.url)), '..', 'Sources', 'ReverseDuet', 'Web');
const TYPES = { html: 'text/html; charset=utf-8', js: 'text/javascript', css: 'text/css', svg: 'image/svg+xml', webmanifest: 'application/manifest+json' };

const server = createServer(async (req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  if (path === '/info') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ name: 'Mock Mac', requiresCode: CODE !== '', version: 'mock', defaults: { mode: 'extend', retina: true } }));
    return;
  }
  const name = path === '/' ? 'index.html' : path.slice(1);
  if (!/^[\w.-]+$/.test(name)) { res.writeHead(404).end(); return; }
  try {
    const body = await readFile(join(WEB, name));
    res.writeHead(200, { 'content-type': TYPES[name.split('.').pop()] || 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(body);
  } catch {
    res.writeHead(404).end('Not found');
  }
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  new Session(socket);
});

function frame(opcode, payload) {
  const len = payload.length;
  const header = len < 126 ? Buffer.from([0x80 | opcode, len])
    : len <= 0xffff ? Buffer.from([0x80 | opcode, 126, len >> 8, len & 0xff])
    : Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(len)); return b; })()]);
  return Buffer.concat([header, payload]);
}

class Session {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.inFlight = 0;
    this.needsKey = true;
    this.frames = 0;
    this.bytes = 0;
    this.rtts = [];
    socket.on('data', (data) => this.onData(data));
    socket.on('close', () => this.stop());
    socket.on('error', () => this.stop());
  }

  sendJSON(object) { if (!this.socket.destroyed) this.socket.write(frame(1, Buffer.from(JSON.stringify(object)))); }

  onData(data) {
    this.buffer = Buffer.concat([this.buffer, data]);
    while (this.buffer.length >= 2) {
      const opcode = this.buffer[0] & 0x0f;
      let len = this.buffer[1] & 0x7f;
      let offset = 2;
      if (len === 126) { if (this.buffer.length < 4) return; len = this.buffer.readUInt16BE(2); offset = 4; }
      else if (len === 127) { if (this.buffer.length < 10) return; len = Number(this.buffer.readBigUInt64BE(2)); offset = 10; }
      if (this.buffer.length < offset + 4 + len) return;
      const mask = this.buffer.subarray(offset, offset + 4);
      const payload = Buffer.from(this.buffer.subarray(offset + 4, offset + 4 + len));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      this.buffer = this.buffer.subarray(offset + 4 + len);
      if (opcode === 8) { this.socket.end(frame(8, Buffer.from([3, 232]))); this.stop(); return; }
      if (opcode === 1) this.onMessage(JSON.parse(payload.toString()));
    }
  }

  onMessage(message) {
    switch (message.t) {
      case 'hello':
        console.log(JSON.stringify({ event: 'hello', ...message, ua: undefined }));
        if (CODE && message.code !== CODE) {
          this.sendJSON({ t: 'auth', ok: false, message: message.code ? "That pairing code isn't right." : 'Enter the pairing code shown on your Mac.' });
          return;
        }
        this.codec = CODEC === 'h264' && (message.codecs || []).includes('h264') ? 'h264' : 'jpeg';
        this.mode = message.mode || 'extend';
        this.sendJSON({ t: 'auth', ok: true, name: 'Mock Mac' });
        this.sendJSON({ t: 'config', codec: this.codec, width: WIDTH, height: HEIGHT, mode: this.mode, fps: FPS, retina: !!message.retina });
        this.start();
        break;
      case 'ack':
        this.inFlight = Math.max(0, this.inFlight - 1);
        this.rtts.push(Date.now() - message.ts);
        break;
      case 'keyframe':
        this.needsKey = true;
        break;
      default:
        console.log(JSON.stringify({ event: 'input', ...message }));
    }
  }

  start() {
    const source = ['-f', 'lavfi', '-i', `testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}`];
    const output = this.codec === 'h264'
      ? ['-c:v', 'libx264', '-profile:v', 'main', '-pix_fmt', 'yuv420p', '-tune', 'zerolatency', '-preset', 'ultrafast', '-g', String(FPS), '-x264-params', 'aud=1', '-f', 'h264', '-']
      : ['-c:v', 'mjpeg', '-q:v', '5', '-f', 'image2pipe', '-'];
    this.ffmpeg = spawn('ffmpeg', ['-loglevel', 'error', '-re', ...source, ...output], { stdio: ['ignore', 'pipe', 'inherit'] });
    let pending = Buffer.alloc(0);
    this.ffmpeg.stdout.on('data', (chunk) => {
      pending = Buffer.concat([pending, chunk]);
      const units = this.codec === 'h264' ? splitAccessUnits(pending) : splitJpegs(pending);
      pending = units.rest;
      for (const unit of units.complete) this.deliver(unit);
    });
    this.stats = setInterval(() => {
      const rtt = this.rtts.length ? this.rtts.reduce((a, b) => a + b, 0) / this.rtts.length : 0;
      this.sendJSON({ t: 'stats', fps: this.frames, kbps: (this.bytes * 8) / 1000, rtt });
      this.frames = 0; this.bytes = 0; this.rtts = [];
    }, 1000);
  }

  deliver(unit) {
    const key = this.codec === 'jpeg' || containsIDR(unit);
    if (this.codec === 'h264') {
      if (this.needsKey && !key) return;
      if (this.inFlight >= 3) { this.needsKey = true; return; }
      this.needsKey = false;
    } else if (this.inFlight >= 3) {
      return;
    }
    const header = Buffer.alloc(10);
    header[0] = this.codec === 'h264' ? 1 : 2;
    header[1] = key ? 1 : 0;
    header.writeDoubleLE(Date.now(), 2);
    const packet = Buffer.concat([header, unit]);
    this.inFlight++;
    this.frames++;
    this.bytes += packet.length;
    if (!this.socket.destroyed) this.socket.write(frame(2, packet));
  }

  stop() {
    if (this.ffmpeg) this.ffmpeg.kill('SIGKILL');
    clearInterval(this.stats);
    this.ffmpeg = null;
  }
}

/** Splits an Annex B stream at access unit delimiters (NAL type 9). */
function splitAccessUnits(buffer) {
  const starts = [];
  for (let i = 0; i + 4 < buffer.length; i++) {
    if (buffer[i] === 0 && buffer[i + 1] === 0 && buffer[i + 2] === 0 && buffer[i + 3] === 1 && (buffer[i + 4] & 0x1f) === 9) starts.push(i);
  }
  const complete = [];
  for (let i = 0; i + 1 < starts.length; i++) complete.push(buffer.subarray(starts[i], starts[i + 1]));
  return { complete, rest: starts.length ? buffer.subarray(starts[starts.length - 1]) : buffer };
}

function containsIDR(unit) {
  for (let i = 0; i + 3 < unit.length; i++) {
    if (unit[i] === 0 && unit[i + 1] === 0 && unit[i + 2] === 1 && (unit[i + 3] & 0x1f) === 5) return true;
  }
  return false;
}

/** Splits concatenated JPEGs on SOI/EOI markers (0xFFD9 can't occur inside entropy data). */
function splitJpegs(buffer) {
  const complete = [];
  let start = 0;
  for (let i = 0; i + 1 < buffer.length; i++) {
    if (buffer[i] === 0xff && buffer[i + 1] === 0xd9) {
      complete.push(buffer.subarray(start, i + 2));
      start = i + 2;
    }
  }
  return { complete, rest: buffer.subarray(start) };
}

server.listen(PORT, () => console.log(JSON.stringify({ event: 'listening', url: `http://localhost:${PORT}`, codec: CODEC, code: CODE })));
