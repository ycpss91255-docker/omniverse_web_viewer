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
    // false, and it should always have been (#98). This prop asks whether the
    // stream REVERSE PROXY requires a JWT: setting it makes the library append
    // `Authorization-Bearer.<accessToken>` to the websocket's
    // Sec-WebSocket-Protocol list. This viewer dials a Kit app directly on a
    // host IP -- no proxy in front of it, no token to send -- so `true` named a
    // mechanism that is not in the path. The library's own default is false.
    //
    // It survived because 5.6.0 did not validate the pair: `true` with no
    // `accessToken` connected anyway, so the flag was wrong and inert at once.
    // 6.x validates and refuses the connect with "Invalid prop accessToken:
    // must be provided if the authenticate prop is true." Caught by the
    // config-dial e2e, which is the only layer that actually dials: the prop
    // exists in both versions with the same name and type, so no type check
    // and no manifest assertion could have seen this.
    authenticate: false,
    // How long the viewer keeps genuinely trying (#101). Under
    // `@nvidia/ov-web-rtc` 6.x this is a real reconnect budget -- logged as
    // "Reconnection attempt (N of M)" -- where 5.x passed it through as
    // `maxSessionStartRetry` and bought only startup grace (#98).
    //
    // #98 set it to 6 so that "6 x ~2 s is ~12 s" would finish inside the 15 s
    // escalation window. That reasoning is WITHDRAWN, not reworded: it was
    // measured to be wrong. Each attempt costs ~10 s of the library's internal
    // sign-in timeout (`let e=1e4` in the bundle; not `reconnectDelay`, not
    // `connectivityTimeout`, and not a public config field) plus the 2 s delay.
    // With 6, the library retried until 49 s against a refused port and 83 s
    // against a black-holed host, while the viewer had declared the source
    // gone at 20 s -- the untrue statement this number had been chosen to
    // prevent.
    //
    // The budget is therefore not computable from this config, and nothing is
    // sized against it any more: the viewer's verdict now waits for the
    // library's own STOPPED (connectStream's `onGaveUp`). 5 is the library's own
    // default, written down so a library release cannot move it silently. It
    // measures at ~37 s against a refused port (a Kit process that is down)
    // and ~71 s against a black-holed host (one that is unreachable), which
    // outlasts a cold Kit boot (~22 s to first frame on the rc2 tag run), so a
    // producer that is restarting is picked up without a reload.
    maxReconnects: 5,
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
