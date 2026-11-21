// connectStream -- the single wrapper around the NVIDIA streaming library's
// DIRECT connect. The library is lazy-imported only on the real path, so
// importing this module (e.g. in node --test) never requires the @nvidia
// registry. Apps call connectStream; they do not touch the library directly.

const HANDLERS = ['onStart', 'onUpdate', 'onStop', 'onTerminate', 'onCustomEvent'];
const NOOP = () => {};

/**
 * Assemble the streamConfig the library expects: the DIRECT config plus the
 * lifecycle handlers, each defaulted to a no-op unless the caller supplies one,
 * plus the library's status callback translated into the one fact this
 * package exposes about it. Pure -- testable without the library.
 *
 * Status translation (#101). ov-web-rtc 6.7.0 added `onStreamStatusChange`,
 * and its own type comment states the semantics: retryable failures stay
 * STARTING between attempts, and "STOPPED is reported after all reconnect
 * attempts are exhausted". Exactly that one status is passed on, as
 * `onGaveUp`. The others are deliberately dropped: STREAMING in particular
 * would be a claim that the stream is live, and the viewer's readout is
 * cleared by a rendered frame and by nothing else (#53, #63) -- a second,
 * competing source of "live" is what #58, #62 and #63 were each made of.
 *
 * The comparison is against the `StreamStatus` the loaded library exports, so
 * the enum never leaves this package and never has to be copied into it.
 * Without one (the pure call, no library loaded) the translator reports
 * nothing, since it has no way to recognise a give-up.
 *
 * @param {object} streamConfig  result of buildStreamConfig()
 * @param {object} [handlers]    optional lifecycle handlers, plus `onGaveUp`
 * @param {{STOPPED: unknown} | null} [StreamStatus]  the library's enum
 * @returns {object} the merged config
 */
export function buildStreamProps(streamConfig, handlers = {}, StreamStatus = null) {
  const cfg = { ...streamConfig };
  for (const h of HANDLERS) {
    cfg[h] = typeof handlers[h] === 'function' ? handlers[h] : NOOP;
  }
  const onGaveUp = typeof handlers.onGaveUp === 'function' ? handlers.onGaveUp : NOOP;
  cfg.onStreamStatusChange = (status) => {
    if (StreamStatus && status === StreamStatus.STOPPED) {
      onGaveUp();
    }
  };
  return cfg;
}

/**
 * Connect a DIRECT stream through an AppStreamer INSTANCE (#101).
 *
 * The static `AppStreamer.connect()` this used to call is `@deprecated` in
 * 6.8.2 (dist/ov-web-rtc.d.ts:295): it forwards to a single shared instance,
 * logs a deprecation warning on every page load, and is scheduled for removal
 * in a future major. The instance form is also the only one that leaves the
 * caller holding something to stop -- which the viewer now needs, because a
 * verdict that the source is gone is only true once nothing is still trying.
 *
 * So this returns a handle, not a promise:
 *   - `connected`: the connect result. Rejects with the library's own value,
 *     unwrapped, because describeStreamError reads its shape.
 *   - `terminate()`: stops the CLIENT. Safe to call at any time, including
 *     before the lazily imported library has loaded.
 *
 * @param {object} streamConfig  result of buildStreamConfig()
 * @param {object} [handlers]    optional lifecycle handlers, plus `onGaveUp`
 * @param {object} [_lib]  test seam: a stand-in for the library MODULE
 *   (`{AppStreamer, StreamType, StreamStatus}`), so the real call path runs
 *   against it and tests stay @nvidia-free
 * @returns {{connected: Promise<any>, terminate: () => Promise<any>}}
 */
export function connectStream(streamConfig, handlers = {}, _lib) {
  const ready = (async () => {
    const lib = _lib ?? (await import('@nvidia/ov-web-rtc'));
    return { lib, streamer: new lib.AppStreamer() };
  })();
  const connected = ready.then(({ lib, streamer }) =>
    streamer.connect({
      streamConfig: buildStreamProps(streamConfig, handlers, lib.StreamStatus),
      streamSource: lib.StreamType.DIRECT,
    }));
  return {
    connected,
    // `false`, explicitly: `terminate(true)` also terminates the Kit app
    // instance. This viewer is a guest on somebody else's Kit process, and
    // stopping that is never its call. The library documents the flag as
    // applying to OVC v1 and NVCF only today; this does not rely on DIRECT
    // happening to ignore it.
    terminate: () => ready.then(({ streamer }) => streamer.terminate(false)),
  };
}
