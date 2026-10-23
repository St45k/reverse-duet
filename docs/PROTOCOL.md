# Wire protocol

The Mac serves everything from one port (default `7280`), plus the same routes over TLS on `port + 1` when the secure link is on.

## HTTP

| Route | Response |
| --- | --- |
| `GET /` | Browser client (`index.html`, `app.js`, `style.css`, `logo.svg`, `manifest.webmanifest`) |
| `GET /info` | `{ "name": "Stas's MacBook", "requiresCode": true, "version": "0.1.0", "securePort": 7281, "defaults": { "mode": "extend", "retina": true } }` |
| `GET /ws` | WebSocket upgrade |

## WebSocket: browser → Mac (JSON text frames)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `hello` | `code`, `mode` (`extend`/`mirror`), `retina`, `ua`, `touch` (maxTouchPoints), `codecs` (`["h264","jpeg"]`), `w`, `h` (CSS px), `dpr` | Pair and start. Can be re-sent on the same socket after a wrong code. |
| `ack` | `ts` | The frame with capture time `ts` was drawn. Drives flow control and latency stats. |
| `keyframe` | | Decoder lost state; send an IDR now. |
| `resize` | `w`, `h`, `dpr` | Screen size changed (rotation, full screen). Extend mode recreates the virtual display. |
| `mouse` | `a` (`move`/`down`/`up`), `b` (0 left, 1 middle, 2 right), `x`, `y` (0…1) | Pointer |
| `wheel` | `dx`, `dy` (pixels, browser sign convention), optional `x`, `y` | Scroll |
| `key` | `a` (`down`/`up`), `code` (`KeyboardEvent.code`), `shift`, `ctrl`, `alt`, `meta` | Physical key |
| `text` | `s` | Text from an on-screen keyboard |

## WebSocket: Mac → browser

JSON text frames:

| `t` | Fields |
| --- | --- |
| `auth` | `ok`, `message` (on failure), `name` |
| `config` | `codec` (`h264`/`jpeg`), `width`, `height`, `mode`, `fps`, `retina`. Sent whenever the pipeline (re)starts. |
| `stats` | `fps`, `kbps`, `rtt` (ms), once per second |
| `error` | `message` |

Binary frames carry video:

```
offset 0  u8      codec   1 = H.264 Annex B access unit, 2 = JPEG
offset 1  u8      flags   bit 0 = key frame
offset 2  f64 LE  capture time, ms since Unix epoch (echoed in `ack`)
offset 10 …       payload
```

H.264 key frames start with SPS and PPS. The browser builds the WebCodecs codec string (`avc1.PPCCLL`) from the SPS and configures `VideoDecoder` without a `description`, so it accepts Annex B directly.

## Flow control

The Mac keeps at most 3 frames un-acked per client. For JPEG, extra frames are dropped. For H.264, dropping a P-frame breaks the reference chain, so the Mac stops sending until the next key frame and forces one. If no `ack` arrives for 2 s, the window is reset and a key frame is forced.
