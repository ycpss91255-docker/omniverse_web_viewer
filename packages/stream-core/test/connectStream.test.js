// Unit tests for connectStream / buildStreamProps (node --test).
// The NVIDIA library is lazy-imported only on the real path, so these tests
// run without a workspace install: buildStreamProps is pure, and connectStream
// is exercised through its injectable `_connect` fake (never loads @nvidia).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildStreamProps, connectStream } from '../src/connectStream.js';

const HANDLERS = ['onStart', 'onUpdate', 'onStop', 'onTerminate', 'onCustomEvent'];

test('buildStreamProps defaults every handler to a no-op function', () => {
  const cfg = buildStreamProps({ signalingServer: 'h', signalingPort: 1 });
  for (const h of HANDLERS) assert.equal(typeof cfg[h], 'function');
});

test('buildStreamProps preserves the streamConfig fields', () => {
  const cfg = buildStreamProps({ signalingServer: '1.2.3.4', signalingPort: 49100, mediaPort: 47998 });
  assert.equal(cfg.signalingServer, '1.2.3.4');
  assert.equal(cfg.signalingPort, 49100);
  assert.equal(cfg.mediaPort, 47998);
});

test('buildStreamProps uses a caller-supplied handler over the default', () => {
  const mine = () => 'mine';
  const cfg = buildStreamProps({ signalingServer: 'h', signalingPort: 1 }, { onStart: mine });
  assert.equal(cfg.onStart, mine);
  // unspecified handlers still defaulted
  assert.equal(typeof cfg.onUpdate, 'function');
});

test('connectStream hands the assembled cfg to the injected connector (no @nvidia load)', async () => {
  let received = null;
  const fakeConnect = (cfg) => { received = cfg; return 'connected'; };
  const out = await connectStream(
    { signalingServer: '127.0.0.1', signalingPort: 49100 },
    { onStop: () => 'bye' },
    fakeConnect,
  );
  assert.equal(out, 'connected');
  assert.equal(received.signalingServer, '127.0.0.1');
  assert.equal(received.signalingPort, 49100);
  assert.equal(received.onStop(), 'bye');
  assert.equal(typeof received.onStart, 'function');
});
