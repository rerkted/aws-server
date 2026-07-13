// ─── server.js ────────────────────────────────────────────────
// Container entry point — reads config from env vars (set by the
// deploy pipeline via `docker run -e`) and starts a long-running
// HTTP listener. Route/middleware logic lives in app.js, shared
// with the Lambda entry point (lambda.js).

const { createApp } = require('./app');

const PORT = process.env.PORT || 3001;
const API_KEY = process.env.ANTHROPIC_API_KEY;
const DOMAIN_NAME = process.env.DOMAIN_NAME || 'YOUR_DOMAIN';

if (!API_KEY) {
  console.error('ERROR: ANTHROPIC_API_KEY environment variable not set');
  process.exit(1);
}

const app = createApp(API_KEY, DOMAIN_NAME);

app.listen(PORT, '0.0.0.0', () => {
  console.log(`AI chat proxy running on port ${PORT}`);
});
