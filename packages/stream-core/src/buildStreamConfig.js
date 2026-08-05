// buildStreamConfig -- pure, DOM-free factory for a stream-only DIRECT connect
// config. No bundler, no jsdom, no @nvidia import, so it unit-tests with plain
// `node --test`. Consumers (the stream-only app + the embedded-site example)
// pass the result to connectStream(); apps own only the DOM wiring.
//
// The server charset whitelist mirrors the container entrypoint: it rejects the
// unsubstituted `__OWV_SERVER__` sentinel (underscores are not allowed) and any
// shell/sed/JS metacharacter, so a misconfigured dev run fails with a clear
// error instead of attempting a connection to a garbage host.

const SERVER_RE = /^[A-Za-z0-9.-]+$/;

function asPort(value, label) {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(
      `buildStreamConfig: invalid ${label} ${JSON.stringify(value)} (expected an integer 1..65535)`,
    );
  }
  return n;
}

/**
 * @param {string} server  signaling/media host (IPv4 or hostname)
 * @param {number|string} port  signaling port (1..65535)
 * @param {number|string|null} [mediaPort=null]  optional media port; omitted
 *   from the config when null/undefined (D1: the library negotiates it via
 *   SDP), pinned when given. Validated like `port`.
 * @returns {object} a DIRECT-stream config for the streaming library
 * @throws {Error} if server, port, or a given mediaPort is invalid
 */
export function buildStreamConfig(server, port, mediaPort = null) {
  const host = typeof server === 'string' ? server.trim() : '';
  if (!host || !SERVER_RE.test(host)) {
    throw new Error(
      `buildStreamConfig: invalid server ${JSON.stringify(server)} ` +
        '(expected an IPv4 / hostname; did you forget to configure it?)',
    );
  }

  const signalingPort = asPort(port, 'port');

  const cfg = {
    videoElementId: 'remote-video',
    audioElementId: 'remote-audio',
    authenticate: true,
    // Deliberately kept at 20 (the library default is 5), reviewed under #58.
    // Despite the name this is NOT a mid-session reconnect budget: in the
    // shipped bundle `maxReconnects` is passed straight through as
    // `maxSessionStartRetry` and is only consumed by the session-START retry
    // decision (`sessionStartRetryLeft` in onSessionStartResult). A producer
    // that dies AFTER the stream is up never re-enters that path, so lowering
    // it would not make the terminal state arrive any sooner -- that state is
    // now derived locally in apps/stream-only/src/streamStatus.js. The viewer
    // copy was corrected to match (#60): the recoverable readout no longer
    // claims to be reconnecting, because this budget buys no such thing. What
    // it does buy is startup grace: a viewer opened before the Kit app finishes
    // booting keeps retrying the initial session setup instead of giving up
    // after 5 attempts.
    maxReconnects: 20,
    signalingServer: host,
    signalingPort,
    mediaServer: host,
    nativeTouchEvents: true,
    width: 1920,
    height: 1080,
    fps: 60,
  };

  if (mediaPort != null) {
    cfg.mediaPort = asPort(mediaPort, 'mediaPort');
  }

  return cfg;
}
