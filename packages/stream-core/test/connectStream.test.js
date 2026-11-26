// Unit tests for connectStream / buildStreamProps (node --test).
// The NVIDIA library is lazy-imported only on the real path, so these tests
// run without a workspace install. buildStreamProps is pure, and connectStream
// is exercised through its injectable `_lib`: a stand-in for the library
// MODULE, so the real call path -- construct an instance, connect through it,
// translate its status -- runs against it.
//
// The seam used to be `_connect`, one function that replaced that entire path.
// That is why nothing could see the difference between the deprecated static
// `AppStreamer.connect()` and the instance form (#101): the part that differs
// was exactly the part the seam skipped.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildStreamProps, connectStream } from '../src/connectStream.js';

const HANDLERS = ['onStart', 'onUpdate', 'onStop', 'onTerminate', 'onCustomEvent'];

// Deliberately NOT the library's real enum values (6.8.2 declares STOPPED = 4).
// Production has to compare against the StreamStatus it was handed; a
// hardcoded `=== 4` would pass against the real numbers and fails here.
const FAKE_STATUS = Object.freeze({
  NONE: 'none-x',
  STARTING: 'starting-x',
  STREAMING: 'streaming-x',
  STOPPING: 'stopping-x',
  STOPPED: 'stopped-x',
});

function fakeLib({ connectRejects } = {}) {
  const calls = { constructed: 0, connect: [], terminate: [], staticConnect: 0 };
  class AppStreamer {
    constructor() {
      calls.constructed += 1;
    }

    connect(props) {
      calls.connect.push(props);
      return connectRejects ? Promise.reject(connectRejects) : Promise.resolve('connected');
    }

    terminate(terminateApp) {
      calls.terminate.push(terminateApp);
      return Promise.resolve('terminated');
    }

    // 6.x keeps the static form WORKING -- it forwards to a shared instance and
    // logs a one-time deprecation warning -- so a regression back to it would
    // not fail loudly against the real library. Against this fake it does.
    static connect() {
      calls.staticConnect += 1;
      return Promise.reject(new Error('static AppStreamer.connect() used'));
    }
  }
  return {
    lib: { AppStreamer, StreamType: { DIRECT: 'direct-x' }, StreamStatus: FAKE_STATUS },
    calls,
  };
}

const CFG = { signalingServer: '127.0.0.1', signalingPort: 49100 };

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

// --- the library's own status (issue #101) ---------------------------------
// ov-web-rtc 6.7.0 added onStreamStatusChange, and its own type comment states
// the semantics this relies on: retryable failures stay STARTING between
// attempts, and "STOPPED is reported after all reconnect attempts are
// exhausted". That is the one fact the viewer's escalation windows had been
// guessing at with a timer.

test('buildStreamProps reports STOPPED to the caller as onGaveUp (#101)', () => {
  let gaveUp = 0;
  const cfg = buildStreamProps(CFG, { onGaveUp: () => { gaveUp += 1; } }, FAKE_STATUS);
  cfg.onStreamStatusChange(FAKE_STATUS.STOPPED);
  assert.equal(gaveUp, 1);
});

test('buildStreamProps passes no other status through, so none can claim the stream is live (#101)', () => {
  // The readout is cleared by a rendered frame and by nothing else (#53, #63).
  // STREAMING reaching the app would be one more claim competing with that
  // observation -- which is what #58, #62 and #63 were each made of. So exactly
  // one status is translated, and it is the one that means the library has
  // stopped trying.
  const seen = [];
  const handlers = Object.fromEntries(
    [...HANDLERS, 'onGaveUp'].map((h) => [h, () => seen.push(h)]),
  );
  const cfg = buildStreamProps(CFG, handlers, FAKE_STATUS);
  for (const s of ['NONE', 'STARTING', 'STREAMING', 'STOPPING']) {
    cfg.onStreamStatusChange(FAKE_STATUS[s]);
  }
  assert.deepEqual(seen, []);
});

test('buildStreamProps compares against the StreamStatus it is given, not a remembered number (#101)', () => {
  let gaveUp = 0;
  const cfg = buildStreamProps(CFG, { onGaveUp: () => { gaveUp += 1; } }, FAKE_STATUS);
  cfg.onStreamStatusChange(4); // 6.8.2's real STOPPED -- meaningless against FAKE_STATUS
  assert.equal(gaveUp, 0);
});

test('buildStreamProps without a StreamStatus installs a translator that reports nothing (#101)', () => {
  // The pure call -- no library loaded -- must not be able to report a give-up
  // it has no way to recognise.
  let gaveUp = 0;
  const cfg = buildStreamProps(CFG, { onGaveUp: () => { gaveUp += 1; } });
  assert.equal(typeof cfg.onStreamStatusChange, 'function');
  cfg.onStreamStatusChange(FAKE_STATUS.STOPPED);
  assert.equal(gaveUp, 0);
});

// --- the instance API (issue #101) ------------------------------------------
// 6.8.2 marks the static form `@deprecated` (dist/ov-web-rtc.d.ts:295): it
// forwards to a single shared instance, logs a deprecation warning on every
// page load, and is scheduled for removal in a future major.

test('connectStream connects through an INSTANCE, never the deprecated static (#101)', async () => {
  const { lib, calls } = fakeLib();
  const stream = connectStream(CFG, {}, lib);
  assert.equal(await stream.connected, 'connected');
  assert.equal(calls.staticConnect, 0, 'the deprecated static connect was used');
  assert.equal(calls.constructed, 1);
  assert.equal(calls.connect.length, 1);
  assert.equal(calls.connect[0].streamSource, 'direct-x');
  assert.equal(calls.connect[0].streamConfig.signalingServer, '127.0.0.1');
  assert.equal(calls.connect[0].streamConfig.signalingPort, 49100);
});

test('connectStream connects with the caller handlers and the status translation in place (#101)', async () => {
  const { lib, calls } = fakeLib();
  let gaveUp = 0;
  const stream = connectStream(
    CFG,
    { onStop: () => 'bye', onGaveUp: () => { gaveUp += 1; } },
    lib,
  );
  await stream.connected;
  const cfg = calls.connect[0].streamConfig;
  assert.equal(cfg.onStop(), 'bye');
  assert.equal(typeof cfg.onStart, 'function');
  // The translation is built from the LOADED library's StreamStatus.
  cfg.onStreamStatusChange(FAKE_STATUS.STOPPED);
  assert.equal(gaveUp, 1);
});

test('the handle stops the CLIENT only, never the Kit app (#101)', async () => {
  // `terminate(true)` also terminates the Kit app instance. This viewer is a
  // guest on somebody else's Kit process; stopping that is never ours to do,
  // so false is passed explicitly rather than relying on DIRECT happening not
  // to honour it today.
  const { lib, calls } = fakeLib();
  const stream = connectStream(CFG, {}, lib);
  await stream.connected;
  await stream.terminate();
  assert.deepEqual(calls.terminate, [false]);
});

test('the handle can be terminated before the library has finished loading (#101)', async () => {
  // The library is imported lazily, so at the instant connectStream returns the
  // instance does not exist yet. terminate() still has to mean something.
  const { lib, calls } = fakeLib();
  const stream = connectStream(CFG, {}, lib);
  await stream.terminate();
  assert.deepEqual(calls.terminate, [false]);
  await stream.connected;
});

test('a rejected connect reaches the caller through `connected`, unchanged (#101)', async () => {
  // describeStreamError depends on seeing the library's own plain-object
  // rejection, so the handle must not wrap or replace it.
  const boom = { action: 'start', status: 'error', info: 'nope' };
  const { lib } = fakeLib({ connectRejects: boom });
  const stream = connectStream(CFG, {}, lib);
  await assert.rejects(stream.connected, (e) => e === boom);
});
