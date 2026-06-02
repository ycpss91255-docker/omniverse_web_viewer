// Demo site wiring: resolve the stream target, build a validated stream-only
// DIRECT config, and connect the streaming library to the <video> in the page.
// The pure, testable part lives in buildStreamConfig.js; everything here is DOM
// + library glue.
import {
  AppStreamer,
  StreamType,
  type DirectConfig,
} from '@nvidia/omniverse-webrtc-streaming-library';
import { buildStreamConfig } from './buildStreamConfig.js';
import target from './streamTarget.json';

type StreamMessage = unknown;

function showStatus(text: string, isError = false): void {
  const el = document.getElementById('stream-status');
  if (el) {
    el.textContent = text;
    el.classList.toggle('error', isError);
  }
  (isError ? console.error : console.info)(`[stream] ${text}`);
}

// host.yaml / env (substituted into streamTarget at container start) is the
// default; a ?server=&port= query overrides it for `npm run dev`.
function resolveTarget(): { server: string; port: string | number } {
  const params = new URLSearchParams(window.location.search);
  return {
    server: params.get('server') ?? String(target.server),
    port: params.get('port') ?? target.signalingPort,
  };
}

function start(): void {
  const { server, port } = resolveTarget();

  let streamConfig;
  try {
    streamConfig = buildStreamConfig(server, port);
  } catch (err) {
    showStatus(
      `${(err as Error).message}\n` +
        'Set the target: open ?server=<ip>&port=<port>, or run the container ' +
        'with SIGNALING_SERVER / host.yaml configured.',
      true,
    );
    return;
  }

  const cfg = {
    ...streamConfig,
    onStart: (m: StreamMessage) => {
      console.info(m);
      showStatus(`streaming ${server}:${port}`);
    },
    onUpdate: (m: StreamMessage) => console.info(m),
    onCustomEvent: (m: StreamMessage) => console.info(m),
    onStop: (m: StreamMessage) => console.info(m),
    onTerminate: (m: StreamMessage) => console.info(m),
  };

  AppStreamer.connect({
    streamConfig: cfg as DirectConfig,
    streamSource: StreamType.DIRECT,
  })
    .then((r: StreamMessage) => console.info(r))
    .catch((e: StreamMessage) => showStatus(`connection failed: ${String(e)}`, true));
}

window.addEventListener('DOMContentLoaded', start);
