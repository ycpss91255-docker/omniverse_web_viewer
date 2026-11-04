// Turn whatever the streaming library rejected with into a sentence a user can
// act on.
//
// WHY THIS EXISTS. Both viewers rendered a failed connect as
// `connection failed: ${String(e)}`, and the library does not reject with
// Errors. Read out of the bundle that ships in this repo's image
// (/app/stream-only/dist/assets/ov-web-rtc-*.js), there are twenty-two sites
// of the form
//
//     throw{action:je.start,status:Oe.error,info:"Failed to connect to current stream"}
//
// -- plain objects, with the only actionable sentence in `info`. `String()` of
// one of those is "[object Object]", so every real connect failure reached the
// user as `connection failed: [object Object]` and the reason was discarded.
//
// Re-checked against `ov-web-rtc` 6.8.2 under #98, because this whole module
// rests on a claim about what the library throws and a renamed package is no
// reason to assume it still holds. It does: 22 plain-object `throw{` sites
// there, up from 18 in 5.6.0. 6.x also throws real `Error`s in 10 places (3 in
// 5.6.0), which is why the `message` fallback below is not dead code -- it is
// now the path for a tenth of the library's throw sites rather than a
// defensive afterthought.
//
// It lives in stream-core because stream-core is the only module that touches
// the library, so it is the only one that has any business knowing the shape
// the library throws -- and because both consumers had the same bug.
//
// It NEVER throws and never returns an empty string: it runs inside a
// `.catch()` on the boot path, so a renderer that fails leaves the viewer with
// no message at all, which is the failure it exists to prevent.

const UNKNOWN = 'the streaming library failed without saying why';

function serialise(value) {
  try {
    const json = JSON.stringify(value);
    if (typeof json === 'string' && json !== '{}' && json !== 'undefined') {
      return json;
    }
  } catch (_ignored) {
    // Circular, or a throwing toJSON. Fall through to String(), which is a
    // poor message but is still better than propagating out of a catch block.
  }
  try {
    return String(value);
  } catch (_ignored) {
    return UNKNOWN;
  }
}

export function describeStreamError(value) {
  try {
    if (value === null || value === undefined) return UNKNOWN;
    if (typeof value === 'string') return value || UNKNOWN;
    if (value instanceof Error) return value.message || String(value) || UNKNOWN;

    if (typeof value === 'object') {
      // `info` first: it is the field the library puts its own sentence in.
      // `message` second, for anything that is Error-shaped without being an
      // Error. Both are only trusted when they are strings -- a non-string
      // `info` is data, not a sentence, and goes through serialise() so it is
      // shown rather than flattened to "[object Object]".
      for (const key of ['info', 'message']) {
        const field = value[key];
        if (typeof field === 'string' && field) return field;
      }
      return serialise(value);
    }

    return serialise(value);
  } catch (_ignored) {
    // A hostile getter, a Proxy that traps everything: still a string out.
    return UNKNOWN;
  }
}
