// Unit tests for the stream-only app's own manifest.
//   node --test
// stream-core declares the streaming library as a PEER, which means this app is
// what actually installs it -- so a correct stream-core manifest is not enough
// on its own. The two have to name the same package, or npm resolves a peer
// that nothing provides and the failure surfaces at install or, worse, as a
// second copy of the library in the bundle.
//
// Reads the manifest from disk rather than importing it, so this runs with no
// workspace install and no JSON-module flag.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const read = (rel) =>
  JSON.parse(readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8'));

const manifest = read('../package.json');

const STREAMING_LIBRARY = '@nvidia/ov-web-rtc';
const LEGACY_LIBRARY = '@nvidia/omniverse-webrtc-streaming-library';

test('installs the streaming library stream-core declares as a peer (#98)', () => {
  const deps = manifest.dependencies ?? {};
  assert.ok(
    Object.prototype.hasOwnProperty.call(deps, STREAMING_LIBRARY),
    `expected ${STREAMING_LIBRARY} in dependencies, got ${JSON.stringify(deps)}`,
  );
});

test('no longer references the renamed 5.x package anywhere (#98)', () => {
  for (const field of ['dependencies', 'devDependencies', 'peerDependencies']) {
    const deps = manifest[field] ?? {};
    assert.ok(
      !Object.prototype.hasOwnProperty.call(deps, LEGACY_LIBRARY),
      `${LEGACY_LIBRARY} is still declared in ${field}`,
    );
  }
});

// The peer and the installed copy agreeing is the actual property; asserting
// each side separately would let them drift to two different 6.x ranges.
test('the installed range satisfies stream-core peer range (#98)', () => {
  const core = read('../../../packages/stream-core/package.json');
  const peer = (core.peerDependencies ?? {})[STREAMING_LIBRARY];
  const installed = (manifest.dependencies ?? {})[STREAMING_LIBRARY];
  assert.ok(peer, `stream-core declares no peer for ${STREAMING_LIBRARY}`);
  assert.ok(installed, `stream-only installs no ${STREAMING_LIBRARY}`);
  assert.equal(
    String(installed).replace(/^\^/, '').split('.')[0],
    String(peer).replace(/^\^/, '').split('.')[0],
    `major mismatch: stream-core peer ${peer} vs stream-only ${installed}`,
  );
});
