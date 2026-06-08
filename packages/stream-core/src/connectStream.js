// connectStream -- the single wrapper around the NVIDIA streaming library's
// DIRECT connect. The library is lazy-imported only on the real path, so
// importing this module (e.g. in node --test) never requires the @nvidia
// registry. Apps call connectStream; they do not touch the library directly.

const HANDLERS = ['onStart', 'onUpdate', 'onStop', 'onTerminate', 'onCustomEvent'];
const NOOP = () => {};

/**
 * Assemble the streamConfig the library expects: the DIRECT config plus the
 * lifecycle handlers, each defaulted to a no-op unless the caller supplies one.
 * Pure -- testable without the library.
 * @param {object} streamConfig  result of buildStreamConfig()
 * @param {object} [handlers]    optional subset of the 5 lifecycle handlers
 * @returns {object} the merged config
 */
export function buildStreamProps(streamConfig, handlers = {}) {
  const cfg = { ...streamConfig };
  for (const h of HANDLERS) {
    cfg[h] = typeof handlers[h] === 'function' ? handlers[h] : NOOP;
  }
  return cfg;
}

/**
 * Connect a DIRECT stream. Defaults handlers, then calls the streaming library.
 * @param {object} streamConfig  result of buildStreamConfig()
 * @param {object} [handlers]    optional lifecycle handlers
 * @param {(cfg: object) => any} [_connect]  test seam: when provided, called
 *   with the assembled cfg instead of the real library (keeps tests @nvidia-free)
 * @returns {Promise<any>} the connect promise
 */
export async function connectStream(streamConfig, handlers = {}, _connect) {
  const cfg = buildStreamProps(streamConfig, handlers);
  if (_connect) {
    return _connect(cfg);
  }
  const { AppStreamer, StreamType } = await import('@nvidia/omniverse-webrtc-streaming-library');
  return AppStreamer.connect({ streamConfig: cfg, streamSource: StreamType.DIRECT });
}
