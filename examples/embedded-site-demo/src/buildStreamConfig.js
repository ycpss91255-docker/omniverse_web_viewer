// buildStreamConfig -- pure, DOM-free factory for a stream-only DIRECT
// connect config, kept separate from main.ts so it can be unit-tested with
// `node --test` (no bundler, no jsdom). main.ts adds the runtime callbacks
// and hands the result to AppStreamer.connect({ streamConfig, streamSource }).
//
// The server charset whitelist mirrors the container entrypoint: it rejects
// the unsubstituted `__OWV_SERVER__` sentinel (underscores are not allowed)
// and any shell/sed/JS metacharacter, so a misconfigured dev run fails with a
// clear error instead of attempting a connection to a garbage host.

const SERVER_RE = /^[A-Za-z0-9.-]+$/;

/**
 * @param {string} server  signaling/media host (IPv4 or hostname)
 * @param {number|string} port  signaling port (1..65535)
 * @returns {object} a DIRECT-stream config for the streaming library
 * @throws {Error} if server or port is invalid
 */
export function buildStreamConfig(server, port) {
  const host = typeof server === 'string' ? server.trim() : '';
  if (!host || !SERVER_RE.test(host)) {
    throw new Error(
      `buildStreamConfig: invalid server ${JSON.stringify(server)} ` +
        '(expected an IPv4 / hostname; did you forget to configure it?)',
    );
  }

  const portNum = typeof port === 'number' ? port : Number(port);
  if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
    throw new Error(
      `buildStreamConfig: invalid port ${JSON.stringify(port)} ` +
        '(expected an integer 1..65535)',
    );
  }

  return {
    videoElementId: 'remote-video',
    audioElementId: 'remote-audio',
    authenticate: true,
    maxReconnects: 20,
    signalingServer: host,
    signalingPort: portNum,
    mediaServer: host,
    nativeTouchEvents: true,
    width: 1920,
    height: 1080,
    fps: 60,
  };
}
