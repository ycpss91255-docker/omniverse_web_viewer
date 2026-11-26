// Full-screen stream-only viewer: resolve the target, build a validated DIRECT
// config, and connect. The testable parts live in resolveTarget.js (pure),
// streamStatus.js (the #stream-status show/hide state machine), and stream-core
// (buildStreamConfig / connectStream); this file is DOM glue only.
import { buildStreamConfig, connectStream, describeStreamError } from 'stream-core';
import { resolveTarget } from './resolveTarget.js';
import { createStatusController } from './streamStatus.js';
import target from './streamTarget.json';

function start(): void {
  // The controller owns #stream-status: show() writes the transient readout and
  // makes it visible; it auto-hides once #remote-video actually renders (first
  // `playing` / `loadeddata`), so the connect-time confirmation stops obscuring
  // the viewport (#53). Re-showing on error/reconnect un-hides it again.
  //
  // `abandon` is how a verdict stops the library (#101), so that "the source
  // is gone" is never on screen while something is still dialing it. The
  // stream does not exist yet -- the target is resolved and validated first --
  // so the controller is handed a function that reaches it once it does.
  let stopStreaming: () => void = () => {};
  const status = createStatusController(
    document.getElementById('stream-status'),
    document.getElementById('remote-video'),
    console,
    { abandon: () => stopStreaming() },
  );

  // The `?server=&port=&media=` override exists for `npm run dev`, where no
  // entrypoint has substituted the sentinels. `import.meta.env.DEV` is true
  // only under the Vite dev server -- `vite build` replaces it with `false` --
  // so the PUBLISHED bundle ignores the query and the operator-configured
  // target is the only target. See the note in resolveTarget.js for why that
  // matters: with nativeTouchEvents the override handed a URL sender both the
  // stream destination and the viewer user's input.
  const { server, port, mediaPort } = resolveTarget(
    window.location.search,
    target,
    import.meta.env.DEV,
  );

  let streamConfig;
  try {
    streamConfig = buildStreamConfig(server, port, mediaPort);
  } catch (err) {
    status.show(
      `${(err as Error).message}\n` +
        (import.meta.env.DEV
          ? 'Set the target: open ?server=<ip>&port=<port> (dev server only).'
          : 'Set the target: run the container with SIGNALING_SERVER / ' +
            'host.yaml configured.'),
      true,
    );
    return;
  }

  // Announce the resolved dial intent before connecting, so an embedding host
  // page can observe exactly what the viewer is about to connect to (server /
  // signaling port / media port). Behavior-neutral: it changes nothing about
  // the connection itself. Not test-only -- it is part of the embedder surface.
  document.dispatchEvent(
    new CustomEvent('owv:dial', { detail: { server, port, mediaPort } }),
  );

  // The viewer is TRYING, and that is all it can honestly say until a frame
  // renders (#63). Announced here, before the connect, so the bounded
  // connect window is armed even if the library never calls onStart -- a
  // viewer whose producer never answers reaches no other trigger (no frame, so
  // no hide() and no watchdog; no session, so no onStop and no escalation) and
  // used to sit on `streaming <server>:<port>` indefinitely. The controller
  // arms the window once and a real first frame cancels it.
  const dialing = `connecting to ${server}:${port}...`;
  status.connecting(dialing);

  // onStop is A producer-loss signal (#56): without it a Kit process that
  // dies mid-session leaves a frozen frame and no text, since the readout hides
  // on the first rendered frame (#53). The library's message argument is
  // deliberately ignored -- its shape is not verifiable from this repo, so it is
  // consumed as a bare signal; the wording, the escalation to the terminal state
  // and the stickiness policy all live in streamStatus.js.
  //
  // Since #62 it is no longer the ONLY signal: streamStatus.js also watches
  // frame progress on #remote-video and announces the same state when frames
  // stall. Keeping onStop wired makes the announcement immediate instead of
  // one stall window late -- it is an accelerator, and the controller ignores
  // whichever of the two arrives second.
  //
  // onTerminate is belt-and-braces ONLY. The 5.x build never invoked it (#58);
  // 6.8.2 has two call sites (#98), but none has been observed firing against
  // a dying producer, so do NOT treat its presence here as evidence that it
  // does. Keeping the handler costs nothing.
  //
  // onGaveUp is the library's own verdict (#101): stream-core reports it when
  // the library says STOPPED, which it does only once every reconnect attempt
  // is exhausted. That -- not a timer of ours -- is what ends the recoverable
  // and connecting states now. Measured before it was wired, the viewer told
  // the user to reload at 20 s while the library dialed on for up to a minute.
  //
  // onStart is NOT "the stream is live" (#63). It fires when a connect attempt
  // BEGINS and re-fires on every session-start retry (observed five times
  // against a producer that was never there), so mapping it onto
  // `streaming <server>:<port>` reported a working stream when nothing was
  // connected. It is mapped onto the same attempting readout instead; the
  // controller ignores the repeats rather than pushing its deadline back, and
  // the readout is cleared by a rendered frame (#53), which is the only
  // evidence that a stream exists.
  const stream = connectStream(streamConfig, {
    onStart: () => status.connecting(dialing),
    onStop: () => status.stopped(),
    onTerminate: () => status.terminated(),
    onGaveUp: () => status.gaveUp(),
  });
  // A failed stop is logged, not shown: by the time the controller asks for
  // one, its verdict is already on screen and there is nothing further the
  // user could act on.
  stopStreaming = () => {
    stream.terminate().catch((e: unknown) =>
      console.warn(`[stream] stopping the library failed: ${describeStreamError(e)}`));
  };
  stream.connected.catch((e: unknown) =>
    // NOT String(e). This library rejects with plain objects
    // (`throw{action,status,info:"..."}`, 22 sites in the 6.8.2 bundle), so
    // String() rendered every real connect failure as
    // `connection failed: [object Object]` and threw away the one sentence
    // the user could act on. describeStreamError lives in stream-core because
    // that is the only module that knows the library's shapes, and it is
    // unit-tested there.
    status.show(`connection failed: ${describeStreamError(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
