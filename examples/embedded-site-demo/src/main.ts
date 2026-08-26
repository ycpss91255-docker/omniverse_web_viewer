// Demo site wiring: resolve the target, build a validated DIRECT config via
// stream-core, and connect to the <video> in the page. The pure, testable parts
// live in resolveTarget.js and stream-core (buildStreamConfig / connectStream);
// this file is DOM + library glue only.
import { buildStreamConfig, connectStream } from 'stream-core';
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

  connectStream(streamConfig, {
    onStart: () => showStatus(`streaming ${server}:${port}`),
  }).catch((e: unknown) => showStatus(`connection failed: ${String(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
