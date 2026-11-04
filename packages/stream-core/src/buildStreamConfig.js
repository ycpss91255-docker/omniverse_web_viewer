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
    // 6, not the 20 this carried against the 5.x library (#98). Under
    // `@nvidia/ov-web-rtc` 6.x this IS a mid-session reconnect budget: the
    // library spaces attempts by `reconnectDelay` (~2 s by default) and logs
    // them as "Reconnection attempt (N of M)". The 5.x internals the old value
    // was reasoned from -- `maxSessionStartRetry`, `sessionStartRetryLeft`,
    // `onSessionStartResult` -- do not exist in 6.8.2 at all.
    //
    // The number is set by the window it has to fit inside, not by taste.
    // apps/stream-only/src/streamStatus.js declares the source gone after
    // TERMINAL_ESCALATION_MS (15 s). At ~2 s per attempt, 20 would spend ~40 s
    // retrying, so the viewer would print "the source is gone. Reload once it
    // is back." while the library was still retrying and might yet succeed.
    // 6 x ~2 s is ~12 s, inside the window: the recoverable readout is true
    // while the library retries, and the terminal readout is true because by
    // then it has given up. Raising this means moving that window with it --
    // a unit spec pins the two together so the pair cannot drift apart.
    //
    // What it costs is attempts 7..20, which 6.x would have been willing to
    // make. That is the deliberate trade: a user told "reconnecting" for 12 s
    // and then "gone" is better served than one watching a dead picture for
    // 40 s, which is the failure #58 set the window to 15 s to avoid.
    maxReconnects: 6,
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
