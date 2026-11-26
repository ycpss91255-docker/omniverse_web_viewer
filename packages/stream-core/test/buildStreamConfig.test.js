// Unit tests for buildStreamConfig (Node's built-in runner, no vitest).
//   node --test
// Pure ESM, no DOM, no bundler, no @nvidia import -- runs without a workspace
// install. Imports the source by relative path; apps import via 'stream-core'.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildStreamConfig } from '../src/buildStreamConfig.js';

test('builds a DIRECT config for a valid server + numeric port', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal(cfg.signalingServer, '127.0.0.1');
  assert.equal(cfg.mediaServer, '127.0.0.1');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(typeof cfg.signalingPort, 'number');
  assert.equal(cfg.videoElementId, 'remote-video');
  assert.equal(cfg.audioElementId, 'remote-audio');
  // false, not true (#98). `authenticate` asks whether the stream REVERSE
  // PROXY requires a JWT, and setting it adds `Authorization-Bearer.<token>`
  // to the websocket's Sec-WebSocket-Protocol list. This viewer dials a Kit app
  // directly on a host IP: no proxy, no JWT, nothing to put in that header.
  // 5.6.0 accepted `true` with no `accessToken` and connected anyway, so the
  // flag was wrong and inert at the same time; 6.x validates it and refuses the
  // connect outright with "Invalid prop accessToken: must be provided if the
  // authenticate prop is true." The config-dial e2e is what caught it -- no
  // type signature could, because the prop exists in both versions with the
  // same name and type.
  assert.equal(cfg.authenticate, false);
});

// The reconnect budget is pinned, and for a different reason than before (#101).
//
// #98 pinned it at 6 so that "6 x ~2 s is ~12 s" would finish inside the 15 s
// escalation window. That model was wrong and is withdrawn, not reworded:
// measured against 6.8.2, each attempt costs ~10 s of the library's INTERNAL
// sign-in timeout (`let e=1e4` in the bundle -- not `reconnectDelay`, not
// `connectivityTimeout`, and not in the public config at all) plus the 2 s
// delay. 6 attempts took 49 s against a refused port and 83 s against a
// black-holed host, while the viewer declared the source gone at 20 s.
//
// The budget is not computable from this config, so no window can be sized
// against it. The terminal readout is therefore driven by the library's own
// STOPPED status now, and this number no longer has to fit anything: it is
// how long the viewer keeps genuinely trying. 5 is the library's own default,
// written down so it cannot move underneath us, and measures at ~37 s (refused
// -- a Kit process that is down) / ~71 s (black-holed -- a host that is
// unreachable). That outlasts a cold Kit boot (~22 s to first frame, rc2), so a
// producer that is restarting is picked up without a reload.
test('pins the reconnect budget at the library default (#101)', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal(cfg.maxReconnects, 5);
});

test('accepts a numeric string port and coerces it to a number', () => {
  const cfg = buildStreamConfig('host.local', '49100');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(typeof cfg.signalingPort, 'number');
});

test('accepts a hostname as server', () => {
  const cfg = buildStreamConfig('isaac-host', 8011);
  assert.equal(cfg.signalingServer, 'isaac-host');
});

test('throws on empty server', () => {
  assert.throws(() => buildStreamConfig('', 49100), /server/i);
});

test('throws on whitespace-only server', () => {
  assert.throws(() => buildStreamConfig('   ', 49100), /server/i);
});

test('throws on an unsubstituted sentinel server (dev without config)', () => {
  assert.throws(() => buildStreamConfig('__OWV_SERVER__', 49100), /server/i);
});

test('throws on a server with illegal characters', () => {
  assert.throws(() => buildStreamConfig('a;rm -rf /', 49100), /server/i);
});

test('throws on a non-numeric port', () => {
  assert.throws(() => buildStreamConfig('host', 'not-a-port'), /port/i);
});

test('throws on a non-integer port', () => {
  assert.throws(() => buildStreamConfig('host', 49100.5), /port/i);
});

test('throws on an out-of-range port', () => {
  assert.throws(() => buildStreamConfig('host', 0), /port/i);
  assert.throws(() => buildStreamConfig('host', 70000), /port/i);
});

// --- media port (D1): optional 3rd arg, omitted when null, pinned when given ---

test('omits mediaPort when not given (default null = negotiate)', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100);
  assert.equal('mediaPort' in cfg, false);
});

test('omits mediaPort when explicitly null', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, null);
  assert.equal('mediaPort' in cfg, false);
});

test('pins mediaPort when given a valid integer', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, 47998);
  assert.equal(cfg.mediaPort, 47998);
  assert.equal(typeof cfg.mediaPort, 'number');
});

test('coerces a numeric string mediaPort', () => {
  const cfg = buildStreamConfig('127.0.0.1', 49100, '48098');
  assert.equal(cfg.mediaPort, 48098);
  assert.equal(typeof cfg.mediaPort, 'number');
});

test('throws on a non-integer mediaPort', () => {
  assert.throws(() => buildStreamConfig('host', 49100, 47998.5), /mediaPort/i);
});

test('throws on an out-of-range mediaPort', () => {
  assert.throws(() => buildStreamConfig('host', 49100, 0), /mediaPort/i);
  assert.throws(() => buildStreamConfig('host', 49100, 70000), /mediaPort/i);
});
