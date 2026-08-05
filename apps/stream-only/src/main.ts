// Full-screen stream-only viewer: resolve the target, build a validated DIRECT
// config, and connect. The testable parts live in resolveTarget.js (pure),
// streamStatus.js (the #stream-status show/hide state machine), and stream-core
// (buildStreamConfig / connectStream); this file is DOM glue only.
import { buildStreamConfig, connectStream } from 'stream-core';
import { resolveTarget } from './resolveTarget.js';
import { createStatusController } from './streamStatus.js';
import target from './streamTarget.json';

function start(): void {
  // The controller owns #stream-status: show() writes the transient readout and
  // makes it visible; it auto-hides once #remote-video actually renders (first
  // `playing` / `loadeddata`), so the connect-time confirmation stops obscuring
  // the viewport (#53). Re-showing on error/reconnect un-hides it again.
  const status = createStatusController(
    document.getElementById('stream-status'),
    document.getElementById('remote-video'),
  );

  const { server, port, mediaPort } = resolveTarget(window.location.search, target);

  let streamConfig;
  try {
    streamConfig = buildStreamConfig(server, port, mediaPort);
  } catch (err) {
    status.show(
      `${(err as Error).message}\n` +
        'Set the target: open ?server=<ip>&port=<port>, or run the container ' +
        'with SIGNALING_SERVER / host.yaml configured.',
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

  // onStop / onTerminate are the producer-loss signals (#56): without them a
  // Kit process that dies mid-session leaves a frozen frame and no text, since
  // the readout hides on the first rendered frame (#53). The library's message
  // argument is deliberately ignored -- its shape for these two handlers is not
  // verifiable from this repo, so they are consumed as bare signals; the
  // wording / stickiness policy lives in streamStatus.js.
  connectStream(streamConfig, {
    onStart: () => status.show(`streaming ${server}:${port}`),
    onStop: () => status.stopped(),
    onTerminate: () => status.terminated(),
  }).catch((e: unknown) => status.show(`connection failed: ${String(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
