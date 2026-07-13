// ─── lambda.js ────────────────────────────────────────────────
// Lambda entry point — fetches the Anthropic API key from SSM
// Parameter Store at cold start (using this function's own execution
// role), caches it for the life of the execution environment, and
// wraps the shared Express app (app.js) with serverless-http so it
// can run behind a Lambda Function URL.
//
// Note: the SSM parameter is shared with the agent-ai service.
// Don't rename/restructure it without checking that dependency.

const serverless = require('serverless-http');
const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const { createApp } = require('./app');

const DOMAIN_NAME = process.env.DOMAIN_NAME || 'YOUR_DOMAIN';
const SSM_PARAM_NAME = process.env.ANTHROPIC_API_KEY_PARAM; // e.g. /rerktserver/anthropic-api-key

const ssm = new SSMClient({});

let cachedHandler = null;

async function getApiKey() {
  if (!SSM_PARAM_NAME) {
    throw new Error('ANTHROPIC_API_KEY_PARAM environment variable not set');
  }
  const result = await ssm.send(new GetParameterCommand({
    Name: SSM_PARAM_NAME,
    WithDecryption: true,
  }));
  return result.Parameter.Value;
}

async function getHandler() {
  if (cachedHandler) return cachedHandler;

  const apiKey = await getApiKey();
  const app = createApp(apiKey, DOMAIN_NAME);
  cachedHandler = serverless(app);
  return cachedHandler;
}

exports.handler = async (event, context) => {
  const handler = await getHandler();
  return handler(event, context);
};
