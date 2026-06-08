// stream-core -- the reusable stream-only kernel. The ONLY package that touches
// the NVIDIA streaming library. Consumed by the stream-only viewer app and the
// embedded-site-demo example.
export { buildStreamConfig } from './buildStreamConfig.js';
export { buildStreamProps, connectStream } from './connectStream.js';
