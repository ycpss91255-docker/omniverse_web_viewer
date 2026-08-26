// resolveTarget -- pure, DOM-free target resolution for the stream-only viewer.
// The entrypoint substitutes the sentinels in streamTarget.json at boot; a
// `?server=&port=&media=` query can override them, but ONLY when the caller
// opts in via `allowQueryOverride`. Kept separate from main.ts (DOM glue) so it
// unit-tests with plain `node --test`.
//
// WHY THE OVERRIDE IS OPT-IN, AND OFF IN THE PUBLISHED BUNDLE.
// It was documented in this file as an `npm run dev` convenience, but it was
// compiled into the PUBLISHED bundle and it OUTRANKED the operator-configured
// target. Together with `nativeTouchEvents: true`
// (packages/stream-core/src/buildStreamConfig.js), that meant anyone who could
// hand a viewer user a URL could repoint the stream at a host of their choosing
// AND have that user's keyboard, mouse, wheel and touch input forwarded there,
// full-screen, on a trusted origin, with nothing on the page indicating it.
// The `^[A-Za-z0-9.-]+$` server check downstream is a CHARSET check, not a
// destination check -- it permits arbitrary hostnames -- so it was never a
// mitigation.
//
// main.ts passes `import.meta.env.DEV`, which Vite replaces with `false` in
// `vite build` output, so the dev workflow the override exists for is unchanged
// and the shipped viewer ignores the query entirely. The parameter defaults to
// false so a caller that forgets it is safe rather than exposed.
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
 * @param {boolean} [allowQueryOverride]  honour `search`; dev builds only
 * @returns {{server: any, port: any, mediaPort: (string|number|null)}}
 */
export function resolveTarget(search, target, allowQueryOverride = false) {
  const params = new URLSearchParams(allowQueryOverride ? search || '' : '');
  return {
    server: params.get('server') ?? target.server,
    port: params.get('port') ?? target.signalingPort,
    mediaPort: sanitizeMedia(params.get('media') ?? target.mediaPort),
  };
}
