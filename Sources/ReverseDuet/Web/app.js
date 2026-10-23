'use strict';

// Reverse Duet browser client: shows a Mac's screen streamed over WebSocket
// (H.264 via WebCodecs, or JPEG) and sends touch / mouse / keyboard back.
(() => {
  const $ = (id) => document.getElementById(id);
  const FRAME_HEADER = 10; // u8 codec, u8 flags, f64le capture time (ms)
  const CODEC_H264 = 1;
  const CODEC_JPEG = 2;

  const prefs = {
    get(key, fallback) {
      try {
        const value = localStorage.getItem('rd.' + key);
        return value === null ? fallback : JSON.parse(value);
      } catch {
        return fallback;
      }
    },
    set(key, value) {
      try { localStorage.setItem('rd.' + key, JSON.stringify(value)); } catch { /* private mode */ }
    },
  };

  const isAppleDevice = /Mac|iPhone|iPad|iPod/.test(navigator.platform || '') || /Macintosh|iPhone|iPad/.test(navigator.userAgent);

  const ui = {
    connect: $('connect'),
    form: $('connect-form'),
    macName: $('mac-name'),
    codeField: $('code-field'),
    codeBoxes: Array.from($('code-boxes').querySelectorAll('input')),
    mode: $('mode'),
    modeHint: $('mode-hint'),
    retina: $('retina'),
    fullscreen: $('fullscreen'),
    swap: $('swap-modifiers'),
    error: $('error'),
    secureTip: $('secure-tip'),
    connectButton: $('connect-button'),
    stage: $('stage'),
    canvas: $('screen'),
    toolbar: $('toolbar'),
    stats: $('stats'),
    status: $('status'),
    sink: $('keyboard-sink'),
  };
  const ctx = ui.canvas.getContext('2d', { alpha: false, desynchronized: true });

  const state = {
    info: null,
    ws: null,
    authed: false,
    mode: prefs.get('mode', 'extend'),
    config: null,
    decoder: null,
    jpegChain: Promise.resolve(),
    gotFrame: false,
    lastSize: null,
    wakeLock: null,
    counters: { frames: 0, bytes: 0 },
    display: { fps: 0, mbps: 0 },
    server: { rtt: 0, fps: 0, kbps: 0 },
  };

  // ---------------------------------------------------------------- Connect UI

  function setMode(mode) {
    state.mode = mode;
    for (const button of ui.mode.querySelectorAll('button')) {
      button.classList.toggle('active', button.dataset.value === mode);
    }
    ui.modeHint.textContent = mode === 'extend'
      ? "Becomes a second screen next to your Mac's display."
      : "Shows a copy of your Mac's main screen.";
  }

  function showError(message) {
    ui.error.textContent = message;
    ui.error.hidden = !message;
  }

  function code() {
    return ui.codeBoxes.map((box) => box.value).join('');
  }

  function setupCodeBoxes() {
    ui.codeBoxes.forEach((box, index) => {
      box.addEventListener('input', () => {
        box.value = box.value.replace(/\D/g, '').slice(-1);
        if (box.value && index < ui.codeBoxes.length - 1) ui.codeBoxes[index + 1].focus();
        if (code().length === ui.codeBoxes.length) ui.connectButton.focus();
      });
      box.addEventListener('keydown', (event) => {
        if (event.key === 'Backspace' && !box.value && index > 0) ui.codeBoxes[index - 1].focus();
      });
      box.addEventListener('paste', (event) => {
        const digits = (event.clipboardData.getData('text') || '').replace(/\D/g, '').slice(0, ui.codeBoxes.length);
        if (!digits) return;
        event.preventDefault();
        ui.codeBoxes.forEach((b, i) => { b.value = digits[i] || ''; });
        ui.codeBoxes[Math.min(digits.length, ui.codeBoxes.length - 1)].focus();
      });
    });
  }

  async function loadInfo() {
    try {
      const response = await fetch('/info', { cache: 'no-store' });
      state.info = await response.json();
      ui.macName.textContent = 'Connect to ' + state.info.name;
      ui.codeField.hidden = !state.info.requiresCode;
      if (prefs.get('mode', null) === null && state.info.defaults) setMode(state.info.defaults.mode);
      if (prefs.get('retina', null) === null && state.info.defaults) ui.retina.checked = !!state.info.defaults.retina;
      if (!window.isSecureContext && state.info.securePort) {
        // WebCodecs (hardware H.264) is only available on secure pages.
        const url = `https://${location.hostname}:${state.info.securePort}/`;
        const link = document.createElement('a');
        link.href = url;
        link.textContent = url;
        ui.secureTip.replaceChildren(
          'For smoother video, open ', link,
          ' and accept the certificate warning (Advanced › Proceed). It is your Mac\'s own certificate.',
        );
        ui.secureTip.hidden = false;
      }
      if (state.info.requiresCode) ui.codeBoxes[0].focus();
    } catch {
      ui.macName.textContent = "Can't reach the Mac. Is Reverse Duet running?";
    }
  }

  async function supportedCodecs() {
    const codecs = [];
    if ('VideoDecoder' in window && 'EncodedVideoChunk' in window) {
      try {
        const result = await VideoDecoder.isConfigSupported({ codec: 'avc1.4d0034', optimizeForLatency: true });
        if (result.supported) codecs.push('h264');
      } catch { /* not supported */ }
    }
    codecs.push('jpeg');
    return codecs;
  }

  async function enterFullscreen() {
    const element = document.documentElement;
    try {
      if (!document.fullscreenElement && element.requestFullscreen) {
        await element.requestFullscreen({ navigationUI: 'hide' });
      } else if (element.webkitRequestFullscreen) {
        element.webkitRequestFullscreen();
      }
    } catch { /* iPhone Safari has no fullscreen API */ }
    if (document.fullscreenElement && navigator.keyboard && navigator.keyboard.lock) {
      // Lets ⌘W, Ctrl+T etc. reach the Mac instead of the browser (Chrome).
      navigator.keyboard.lock().catch(() => {});
    }
  }

  function screenSize() {
    const fullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
    return {
      w: Math.round(fullscreen ? screen.width : window.innerWidth),
      h: Math.round(fullscreen ? screen.height : window.innerHeight),
      dpr: Math.round((window.devicePixelRatio || 1) * 100) / 100,
    };
  }

  async function onSubmit(event) {
    event.preventDefault();
    showError('');
    if (state.info && state.info.requiresCode && code().length !== ui.codeBoxes.length) {
      showError('Enter the 4-digit pairing code shown on your Mac.');
      return;
    }
    prefs.set('mode', state.mode);
    prefs.set('retina', ui.retina.checked);
    prefs.set('fullscreen', ui.fullscreen.checked);
    prefs.set('swap', ui.swap.checked);

    ui.connectButton.disabled = true;
    ui.connectButton.textContent = 'Connecting…';
    if (ui.fullscreen.checked) {
      await enterFullscreen();
      await new Promise((resolve) => setTimeout(resolve, 250)); // let the viewport settle
    }
    const hello = {
      t: 'hello',
      code: code(),
      mode: state.mode,
      retina: ui.retina.checked,
      ua: navigator.userAgent,
      touch: navigator.maxTouchPoints || 0,
      codecs: await supportedCodecs(),
      ...screenSize(),
    };
    state.lastSize = { w: hello.w, h: hello.h, dpr: hello.dpr };

    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      send(hello);
    } else {
      openSocket(hello);
    }
  }

  function resetConnectButton() {
    ui.connectButton.disabled = false;
    ui.connectButton.textContent = 'Connect';
  }

  // ---------------------------------------------------------------- Socket

  function openSocket(hello) {
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${scheme}//${location.host}/ws`);
    ws.binaryType = 'arraybuffer';
    state.ws = ws;
    state.authed = false;

    ws.onopen = () => send(hello);
    ws.onmessage = (event) => {
      if (typeof event.data === 'string') {
        handleMessage(JSON.parse(event.data));
      } else {
        handleFrame(event.data);
      }
    };
    ws.onclose = () => {
      if (state.ws !== ws) return;
      const wasStreaming = state.authed;
      state.ws = null;
      state.authed = false;
      leaveStage();
      resetConnectButton();
      if (wasStreaming) showError('Disconnected from your Mac.');
      else if (!ui.error.textContent) showError("Couldn't connect to your Mac.");
    };
  }

  function send(message) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) state.ws.send(JSON.stringify(message));
  }

  function handleMessage(message) {
    switch (message.t) {
      case 'auth':
        if (message.ok) {
          state.authed = true;
          enterStage();
        } else {
          resetConnectButton();
          exitFullscreen();
          showError(message.message || 'Pairing failed.');
          ui.codeBoxes.forEach((box) => { box.value = ''; });
          ui.codeBoxes[0].focus();
        }
        break;
      case 'config':
        state.config = message;
        state.mode = message.mode;
        resetDecoder();
        setStatus(state.gotFrame ? '' : 'Starting stream…');
        break;
      case 'stats':
        state.server = { rtt: message.rtt, fps: message.fps, kbps: message.kbps };
        break;
      case 'error':
        if (state.authed) setStatus(message.message);
        else showError(message.message);
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- Video

  function resetDecoder() {
    if (state.decoder && state.decoder.state !== 'closed') {
      try { state.decoder.close(); } catch { /* already closed */ }
    }
    state.decoder = null;
  }

  function createDecoder() {
    state.decoder = new VideoDecoder({
      output: (frame) => {
        draw(frame, frame.displayWidth, frame.displayHeight);
        const ts = frame.timestamp / 1000;
        frame.close();
        send({ t: 'ack', ts });
      },
      error: (error) => {
        console.warn('Decoder error', error);
        state.decoder = null;
        send({ t: 'keyframe' });
      },
    });
  }

  /** Builds an `avc1.PPCCLL` codec string from the SPS in an Annex B access unit. */
  function codecFromSPS(bytes) {
    for (let i = 0; i + 4 < bytes.length; i++) {
      if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1 && (bytes[i + 3] & 0x1f) === 7) {
        const hex = (n) => n.toString(16).padStart(2, '0');
        return 'avc1.' + hex(bytes[i + 4]) + hex(bytes[i + 5]) + hex(bytes[i + 6]);
      }
    }
    return null;
  }

  function handleFrame(buffer) {
    if (buffer.byteLength <= FRAME_HEADER) return;
    const view = new DataView(buffer);
    const type = view.getUint8(0);
    const isKey = (view.getUint8(1) & 1) === 1;
    const ts = view.getFloat64(2, true);
    const payload = new Uint8Array(buffer, FRAME_HEADER);
    state.counters.bytes += buffer.byteLength;

    if (type === CODEC_H264) {
      if (!state.decoder || state.decoder.state === 'closed') {
        if (!('VideoDecoder' in window)) return;
        createDecoder();
      }
      if (state.decoder.state === 'unconfigured') {
        const codec = isKey ? codecFromSPS(payload) : null;
        if (!codec) {
          send({ t: 'ack', ts });
          send({ t: 'keyframe' });
          return;
        }
        // No `description`: the decoder expects Annex B, which is what the Mac sends.
        state.decoder.configure({ codec, optimizeForLatency: true });
      }
      try {
        state.decoder.decode(new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta',
          timestamp: Math.round(ts * 1000),
          data: payload,
        }));
      } catch (error) {
        console.warn('Decode failed', error);
        resetDecoder();
        send({ t: 'ack', ts });
        send({ t: 'keyframe' });
      }
    } else if (type === CODEC_JPEG) {
      const blob = new Blob([payload], { type: 'image/jpeg' });
      state.jpegChain = state.jpegChain
        .then(() => createImageBitmap(blob))
        .then((bitmap) => {
          draw(bitmap, bitmap.width, bitmap.height);
          bitmap.close();
        })
        .catch((error) => console.warn('JPEG decode failed', error))
        .then(() => send({ t: 'ack', ts }));
    }
  }

  function draw(image, width, height) {
    if (ui.canvas.width !== width || ui.canvas.height !== height) {
      ui.canvas.width = width;
      ui.canvas.height = height;
    }
    ctx.drawImage(image, 0, 0, width, height);
    state.counters.frames++;
    if (!state.gotFrame) {
      state.gotFrame = true;
      setStatus('');
    }
  }

  // ---------------------------------------------------------------- Stage

  function setStatus(text) {
    ui.status.textContent = text || '';
    ui.status.hidden = !text;
  }

  function enterStage() {
    ui.connect.hidden = true;
    ui.stage.hidden = false;
    state.gotFrame = false;
    setStatus('Starting stream…');
    ui.canvas.focus();
    showToolbar();
    requestWakeLock();
    resetConnectButton();
  }

  function leaveStage() {
    resetDecoder();
    state.config = null;
    ui.stage.hidden = true;
    ui.connect.hidden = false;
    ui.stats.hidden = true;
    $('tb-stats').classList.remove('on');
    exitFullscreen();
    releaseWakeLock();
  }

  function exitFullscreen() {
    if (navigator.keyboard && navigator.keyboard.unlock) navigator.keyboard.unlock();
    if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(() => {});
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator) state.wakeLock = await navigator.wakeLock.request('screen');
    } catch { /* not allowed */ }
  }

  function releaseWakeLock() {
    if (state.wakeLock) state.wakeLock.release().catch(() => {});
    state.wakeLock = null;
  }

  let toolbarTimer = 0;
  function showToolbar() {
    ui.toolbar.classList.remove('hidden');
    clearTimeout(toolbarTimer);
    toolbarTimer = setTimeout(() => ui.toolbar.classList.add('hidden'), 2500);
  }

  setInterval(() => {
    state.display = { fps: state.counters.frames, mbps: (state.counters.bytes * 8) / 1e6 };
    state.counters = { frames: 0, bytes: 0 };
    if (!ui.stats.hidden) {
      const c = state.config || {};
      ui.stats.textContent = [
        `${c.mode === 'mirror' ? 'Mirror' : 'Extend'}  ${c.width || '–'}×${c.height || '–'}  ${(c.codec || '').toUpperCase()}`,
        `${state.display.fps} fps  ${state.display.mbps.toFixed(1)} Mbps`,
        `latency ${Math.round(state.server.rtt || 0)} ms`,
      ].join('\n');
    }
  }, 1000);

  // ---------------------------------------------------------------- Input

  /** Maps a client point to 0…1 coordinates on the Mac display (letterbox aware). */
  function normalize(clientX, clientY) {
    const rect = ui.canvas.getBoundingClientRect();
    const cw = ui.canvas.width || 1;
    const ch = ui.canvas.height || 1;
    const scale = Math.min(rect.width / cw, rect.height / ch);
    const width = cw * scale;
    const height = ch * scale;
    const left = rect.left + (rect.width - width) / 2;
    const top = rect.top + (rect.height - height) / 2;
    const clamp = (v) => Math.min(1, Math.max(0, v));
    return { x: clamp((clientX - left) / width), y: clamp((clientY - top) / height) };
  }

  let pendingMove = null;
  function queueMove(point) {
    if (!pendingMove) {
      requestAnimationFrame(() => {
        if (pendingMove) send({ t: 'mouse', a: 'move', ...pendingMove });
        pendingMove = null;
      });
    }
    pendingMove = point;
  }

  function flushMove() {
    if (pendingMove) send({ t: 'mouse', a: 'move', ...pendingMove });
    pendingMove = null;
  }

  const touches = new Map();
  const gesture = { leftDown: false, scrolling: false, twoFingerStart: 0, moved: false, last: null };

  function centroid() {
    let x = 0;
    let y = 0;
    for (const t of touches.values()) { x += t.x; y += t.y; }
    return { x: x / touches.size, y: y / touches.size };
  }

  ui.canvas.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    ui.canvas.focus({ preventScroll: true });
    if (event.clientY < 40) showToolbar();
    try { ui.canvas.setPointerCapture(event.pointerId); } catch { /* ignore */ }
    const point = normalize(event.clientX, event.clientY);

    if (event.pointerType === 'touch') {
      touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (touches.size === 1) {
        gesture.moved = false;
        gesture.leftDown = true;
        send({ t: 'mouse', a: 'move', ...point });
        send({ t: 'mouse', a: 'down', b: 0, ...point });
      } else if (touches.size === 2) {
        // Second finger: switch from drag to two-finger scroll.
        if (gesture.leftDown) {
          send({ t: 'mouse', a: 'up', b: 0, ...point });
          gesture.leftDown = false;
        }
        gesture.scrolling = true;
        gesture.twoFingerStart = performance.now();
        gesture.moved = false;
        gesture.last = centroid();
      }
      return;
    }

    flushMove();
    send({ t: 'mouse', a: 'down', b: event.button, ...point });
  });

  ui.canvas.addEventListener('pointermove', (event) => {
    if (event.pointerType === 'mouse' && event.clientY < 24) showToolbar();
    if (event.pointerType === 'touch') {
      if (!touches.has(event.pointerId)) return;
      const previous = touches.get(event.pointerId);
      touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (Math.hypot(event.clientX - previous.x, event.clientY - previous.y) > 0) gesture.moved = true;
      if (gesture.scrolling && touches.size >= 2) {
        const now = centroid();
        const dx = now.x - gesture.last.x;
        const dy = now.y - gesture.last.y;
        gesture.last = now;
        if (dx || dy) send({ t: 'wheel', dx: -dx * 2, dy: -dy * 2 });
        return;
      }
      if (gesture.leftDown) queueMove(normalize(event.clientX, event.clientY));
      return;
    }
    queueMove(normalize(event.clientX, event.clientY));
  });

  function pointerEnd(event) {
    const point = normalize(event.clientX, event.clientY);
    if (event.pointerType === 'touch') {
      if (!touches.has(event.pointerId)) return;
      touches.delete(event.pointerId);
      if (gesture.scrolling) {
        if (touches.size === 0) {
          // Quick two-finger tap = right click.
          if (!gesture.moved && performance.now() - gesture.twoFingerStart < 300) {
            send({ t: 'mouse', a: 'down', b: 2, ...point });
            send({ t: 'mouse', a: 'up', b: 2, ...point });
          }
          gesture.scrolling = false;
        }
        return;
      }
      if (gesture.leftDown && touches.size === 0) {
        flushMove();
        send({ t: 'mouse', a: 'up', b: 0, ...point });
        gesture.leftDown = false;
      }
      return;
    }
    flushMove();
    send({ t: 'mouse', a: 'up', b: event.button, ...point });
  }
  ui.canvas.addEventListener('pointerup', pointerEnd);
  ui.canvas.addEventListener('pointercancel', pointerEnd);
  ui.canvas.addEventListener('contextmenu', (event) => event.preventDefault());

  ui.canvas.addEventListener('wheel', (event) => {
    event.preventDefault();
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
    const point = normalize(event.clientX, event.clientY);
    send({ t: 'wheel', dx: event.deltaX * unit, dy: event.deltaY * unit, ...point });
  }, { passive: false });

  const MODIFIER_SWAP = { ControlLeft: 'MetaLeft', ControlRight: 'MetaRight', MetaLeft: 'ControlLeft', MetaRight: 'ControlRight' };

  function keyMessage(event, action) {
    const swap = ui.swap.checked;
    return {
      t: 'key',
      a: action,
      code: swap ? (MODIFIER_SWAP[event.code] || event.code) : event.code,
      shift: event.shiftKey,
      alt: event.altKey,
      ctrl: swap ? event.metaKey : event.ctrlKey,
      meta: swap ? event.ctrlKey : event.metaKey,
    };
  }

  function onKey(event, action) {
    if (ui.stage.hidden || !state.authed) return;
    if (event.isComposing || event.keyCode === 229 || !event.code) return; // soft keyboard → handled by beforeinput
    event.preventDefault();
    send(keyMessage(event, action));
  }
  window.addEventListener('keydown', (event) => onKey(event, 'down'));
  window.addEventListener('keyup', (event) => onKey(event, 'up'));

  // On-screen keyboards (iPad, Android, Chromebook tablet mode).
  ui.sink.addEventListener('beforeinput', (event) => {
    event.preventDefault();
    const tap = (code) => {
      send({ t: 'key', a: 'down', code });
      send({ t: 'key', a: 'up', code });
    };
    if (event.inputType === 'deleteContentBackward') tap('Backspace');
    else if (event.inputType === 'insertLineBreak' || event.inputType === 'insertParagraph') tap('Enter');
    else if (event.data) send({ t: 'text', s: event.data });
  });
  ui.sink.addEventListener('input', () => {
    if (ui.sink.value) send({ t: 'text', s: ui.sink.value });
    ui.sink.value = '';
  });

  // ---------------------------------------------------------------- Toolbar & lifecycle

  $('tb-fullscreen').addEventListener('click', () => {
    if (document.fullscreenElement) exitFullscreen();
    else enterFullscreen();
  });
  $('tb-keyboard').addEventListener('click', () => {
    ui.sink.focus({ preventScroll: true });
  });
  $('tb-stats').addEventListener('click', (event) => {
    ui.stats.hidden = !ui.stats.hidden;
    event.currentTarget.classList.toggle('on', !ui.stats.hidden);
  });
  $('tb-disconnect').addEventListener('click', () => {
    if (state.ws) state.ws.close();
  });

  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      if (!state.authed || !state.config || state.config.mode !== 'extend') return;
      const size = screenSize();
      const last = state.lastSize;
      if (last && Math.abs(last.w - size.w) < 8 && Math.abs(last.h - size.h) < 8 && last.dpr === size.dpr) return;
      state.lastSize = size;
      send({ t: 'resize', ...size });
    }, 600);
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.authed) {
      send({ t: 'keyframe' });
      requestWakeLock();
    }
  });

  ui.mode.addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (button) setMode(button.dataset.value);
  });
  ui.form.addEventListener('submit', onSubmit);

  setupCodeBoxes();
  setMode(state.mode);
  ui.retina.checked = prefs.get('retina', true);
  ui.fullscreen.checked = prefs.get('fullscreen', !/iPhone/.test(navigator.userAgent));
  ui.swap.checked = prefs.get('swap', !isAppleDevice);
  loadInfo();
})();
