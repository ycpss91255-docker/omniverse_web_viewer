// resolveTarget -- pure, DOM-free target resolution for the stream-only viewer.
// The entrypoint substitutes the sentinels in streamTarget.json at boot; a
// `?server=&port=&media=` query overrides them for `npm run dev`. Kept separate
// from main.ts (DOM glue) so it unit-tests with plain `node --test`.
//
// server / port are passed through verbatim -- buildStreamConfig validates them
// and throws the "did you forget to configure it?" error on the unsubstituted
// server sentinel. mediaPort is OPTIONAL, so an unsubstituted / empty /
// non-numeric value is sanitized to null (omit + SDP-negotiate, D1) rather than
// passed on to throw.

function sanitizeMedia(value) {
  return /^\d+$/.test(String(value ?? '')) ? value : null;
}

/**
 * @param {string} search  location.search (e.g. "?server=1.2.3.4&port=49100")
 * @param {{server: any, signalingPort: any, mediaPort?: any}} target  streamTarget.json
 * @returns {{server: any, port: any, mediaPort: (string|number|null)}}
 */
export function resolveTarget(search, target) {
  const params = new URLSearchParams(search || '');
  return {
    server: params.get('server') ?? target.server,
    port: params.get('port') ?? target.signalingPort,
    mediaPort: sanitizeMedia(params.get('media') ?? target.mediaPort),
  };
}
