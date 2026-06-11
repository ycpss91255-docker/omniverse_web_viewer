// Full-screen stream-only viewer: resolve the target, build a validated DIRECT
// config, and connect. The testable parts live in resolveTarget.js (pure) and
// stream-core (buildStreamConfig / connectStream); this file is DOM glue only.
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
  const { server, port, mediaPort } = resolveTarget(window.location.search, target);

  let streamConfig;
  try {
    streamConfig = buildStreamConfig(server, port, mediaPort);
  } catch (err) {
    showStatus(
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

  connectStream(streamConfig, {
    onStart: () => showStatus(`streaming ${server}:${port}`),
  }).catch((e: unknown) => showStatus(`connection failed: ${String(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
