// Unit tests for stream-core's own manifest.
//   node --test
// The library this package wraps is the one thing about stream-core that a
// caller cannot discover from its API, and nothing asserted it: the dependency
// could be swapped, or drift back, with every other test in the repo still
// green. connectStream's `_connect` seam deliberately keeps the library off the
// test path (so these specs run without the @nvidia registry), which is the
// right trade for testing behaviour and exactly why the DECLARATION needs its
// own assertion.
//
// Reads the manifest from disk rather than importing it, so this runs with no
// workspace install and no JSON-module flag.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const manifest = JSON.parse(
  readFileSync(fileURLToPath(new URL('../package.json', import.meta.url)), 'utf8'),
);

const STREAMING_LIBRARY = '@nvidia/ov-web-rtc';
// The 5.x line this package was built against until #98. It is a RENAMED
// package, not a version bump, so the old name must be gone rather than
// pinned lower -- having both would install two copies of the same library.
const LEGACY_LIBRARY = '@nvidia/omniverse-webrtc-streaming-library';

test('declares the streaming library as a peer dependency (#98)', () => {
  const peers = manifest.peerDependencies ?? {};
  assert.ok(
    Object.prototype.hasOwnProperty.call(peers, STREAMING_LIBRARY),
    `expected ${STREAMING_LIBRARY} in peerDependencies, got ${JSON.stringify(peers)}`,
  );
});

test('pins the streaming library to a 6.x range (#98)', () => {
  const range = (manifest.peerDependencies ?? {})[STREAMING_LIBRARY];
  assert.match(
    String(range),
    /^\^?6\./,
    `expected a 6.x pin for ${STREAMING_LIBRARY}, got ${String(range)}`,
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
