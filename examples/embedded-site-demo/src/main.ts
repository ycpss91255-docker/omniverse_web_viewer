// Demo site wiring: resolve the target, build a validated DIRECT config via
// stream-core, and connect to the <video> in the page. The pure, testable parts
// live in resolveTarget.js and stream-core (buildStreamConfig / connectStream);
// this file is DOM + library glue only.
import { buildStreamConfig, connectStream, describeStreamError } from 'stream-core';
import { resolveTarget } from './resolveTarget.js';
import target from './streamTarget.json';

function showStatus(text: string, isError = false): void {
  const el = document.getElementById('stream-status');
  if (el) {
    el.textContent = text;
    el.classList.toggle('error', isError);
  }
  (isError ? console.error : console.info)(`[stream] ${text}`);
}

function start(): void {
  // The `?server=&port=&media=` override exists for `npm run dev`, where no
  // entrypoint has substituted the sentinels (this is the query string the
  // README's "Run it (dev)" section documents). `import.meta.env.DEV` is true
  // only under the Vite dev server -- `vite build` replaces it with `false` --
  // so the BUILT demo ignores the query and the operator-configured target is
  // the only target. See the note in resolveTarget.js for why that matters.
  const { server, port, mediaPort } = resolveTarget(
    window.location.search,
    target,
    import.meta.env.DEV,
  );

  let streamConfig;
  try {
    streamConfig = buildStreamConfig(server, port, mediaPort);
  } catch (err) {
    showStatus(
      `${(err as Error).message}\n` +
        (import.meta.env.DEV
          ? 'Set the target: open ?server=<ip>&port=<port> (dev server only).'
          : 'Set the target: run the container with SIGNALING_SERVER / ' +
            'host.yaml configured.'),
      true,
    );
    return;
  }

  // onStart is NOT "the stream is live" (#63). It fires when a connect
  // ATTEMPT begins and re-fires on every session-start retry -- observed five
  // times against a producer that was never there -- so `streaming
  // <server>:<port>` reported a working stream with nothing connected. The
  // viewer app was fixed on 2026-08-14; this second consumer of the same
  // stream-core interface kept the defect, and was edited again afterwards
  // without anyone noticing. It says what it knows: an attempt is in flight.
  //
  // The demo has no frame watchdog (that is streamStatus.js, which the viewer
  // app owns), so this readout is not cleared by a rendered frame. It stays
  // until the connect settles -- deliberately less than the app, and honest
  // about it rather than claiming more.
  connectStream(streamConfig, {
    onStart: () => showStatus(`connecting to ${server}:${port}...`),
  }).catch((e: unknown) =>
    // NOT String(e) -- see the same note in apps/stream-only/src/main.ts.
    showStatus(`connection failed: ${describeStreamError(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
