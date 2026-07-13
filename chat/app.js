// ─── app.js ───────────────────────────────────────────────────
// AI Chat — Secure proxy app factory
// Sits between the browser and Anthropic API
// - Keeps API key server-side only
// - Validates origin to your domain only
// - Injects system prompt with your background
//
// Rate limiting is NOT handled here — nginx's limit_req zone on
// ai.DOMAIN_NAME/api/ already enforces it in front of every request,
// for both the container and Lambda deployment targets.

const express = require('express');
const cors    = require('cors');
const helmet  = require('helmet');

// ─── SYSTEM PROMPT ────────────────────────────────────────────
// Replace all YOUR_* placeholders below with your own information.
const SYSTEM_PROMPT = `You are YOUR_AI_NAME, an AI assistant on YOUR_NAME's portfolio website at YOUR_DOMAIN.

Your purpose is to answer questions about YOUR_FIRST_NAME's projects, YOUR_SPECIALIZATION expertise, and general cloud engineering topics.

## About YOUR_NAME

YOUR_NAME is a YOUR_TITLE with YOUR_YEARS+ years of experience YOUR_EXPERTISE_SUMMARY.

### Current Roles
- **YOUR_ROLE_1 at YOUR_COMPANY_1** (YOUR_DATE_1 - Present): YOUR_BULLET_1
- **YOUR_ROLE_2 at YOUR_COMPANY_2** (YOUR_DATE_2 - Present): YOUR_BULLET_2

### Previous Experience
- **YOUR_ROLE_3 at YOUR_COMPANY_3** (YOUR_DATE_3 - YOUR_DATE_END_3): YOUR_BULLET_3

### Certifications
- YOUR_CERT_NAME_1
- YOUR_CERT_NAME_2
- YOUR_CERT_NAME_3
- YOUR_CERT_NAME_4

### Projects
1. **YOUR_PROJECT_NAME_1**: YOUR_PROJECT_DESC_1
2. **YOUR_PROJECT_NAME_2**: YOUR_PROJECT_DESC_2
3. **YOUR_PROJECT_NAME_3**: YOUR_PROJECT_DESC_3
4. **YOUR_PROJECT_NAME_4 (this assistant)**: YOUR_PROJECT_DESC_4

### Technical Skills
YOUR_SKILLS_LIST

## Behavior Rules
- Answer questions about YOUR_FIRST_NAME's projects and experience accurately using the info above
- Answer general YOUR_DOMAIN_AREA questions (AWS, Terraform, Docker, security, CI/CD, IAM, networking)
- Be concise — 2-4 sentences for most answers, longer only if genuinely needed
- Be professional but conversational — this is a portfolio, not a support ticket
- If asked something outside YOUR_DOMAIN_AREA or YOUR_FIRST_NAME's background, politely redirect
- Never make up experience or certifications YOUR_FIRST_NAME doesn't have
- Never discuss competitors, pricing comparisons, or make business recommendations
- Refer to YOUR_FIRST_NAME in third person ("YOUR_FIRST_NAME has worked with...", "Their experience includes...")`;

/**
 * Builds the configured Express app. Takes the Anthropic API key as a
 * parameter rather than reading it from process.env directly, so the
 * container entry point (server.js, env var) and the Lambda entry point
 * (lambda.js, SSM fetch at cold start) can each resolve it their own way.
 */
function createApp(apiKey, domainName) {
  if (!apiKey) {
    throw new Error('createApp: apiKey is required');
  }

  const app = express();

  app.use(helmet({
    // Mirrors the CSP already enforced at the nginx layer for ai.DOMAIN_NAME,
    // so the app is still protected if it's ever reached without nginx in front.
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", "'unsafe-inline'"],
        styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
        fontSrc: ["'self'", "https://fonts.gstatic.com"],
        imgSrc: ["'self'", "data:"],
        connectSrc: ["'self'"],
        frameAncestors: ["'none'"],
      },
    },
  }));

  app.use(cors({
    origin: [
      `https://${domainName}`,
      `https://www.${domainName}`,
      `https://ai.${domainName}`,
      'http://localhost:8080' // local dev only
    ],
    methods: ['POST'],
    allowedHeaders: ['Content-Type']
  }));

  app.use(express.json({ limit: '10kb' })); // prevent large payload attacks

  // ─── HEALTH CHECK ──────────────────────────────────────────────
  app.get('/health', (req, res) => {
    res.status(200).send('OK');
  });

  // ─── CHAT ENDPOINT ─────────────────────────────────────────────
  app.post('/api/chat', async (req, res) => {
    const { messages } = req.body;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return res.status(400).json({ error: 'Invalid request — messages array required' });
    }

    // Limit conversation history to last 10 messages to control token usage
    const trimmedMessages = messages.slice(-10).map(m => ({
      role: m.role === 'user' ? 'user' : 'assistant',
      content: String(m.content).slice(0, 2000) // cap per message
    }));

    try {
      const response = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify({
          model: 'claude-haiku-4-5-20251001',
          max_tokens: 512,
          system: SYSTEM_PROMPT,
          messages: trimmedMessages
        })
      });

      if (!response.ok) {
        const err = await response.text();
        console.error('Anthropic API error:', err);
        return res.status(502).json({ error: 'AI service temporarily unavailable' });
      }

      const data = await response.json();
      const text = data.content?.[0]?.text || 'Sorry, I could not generate a response.';
      res.json({ response: text });

    } catch (err) {
      console.error('Proxy error:', err);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  return app;
}

module.exports = { createApp };
