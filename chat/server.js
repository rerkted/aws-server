// ─── server.js ────────────────────────────────────────────────
// AI Chat — Secure proxy server
// Sits between the browser and Anthropic API
// - Keeps API key server-side only
// - Rate limits per IP
// - Validates origin to your domain only
// - Injects system prompt with your background

const express    = require('express');
const cors       = require('cors');
const helmet     = require('helmet');
const rateLimit  = require('express-rate-limit');

const app  = express();
const PORT = process.env.PORT || 3001;
const API_KEY = process.env.ANTHROPIC_API_KEY;
const DOMAIN_NAME = process.env.DOMAIN_NAME || 'YOUR_DOMAIN';

if (!API_KEY) {
  console.error('ERROR: ANTHROPIC_API_KEY environment variable not set');
  process.exit(1);
}

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

// ─── MIDDLEWARE ────────────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: false // handled by nginx
}));

app.use(cors({
  origin: [
    `https://${DOMAIN_NAME}`,
    `https://www.${DOMAIN_NAME}`,
    `https://ai.${DOMAIN_NAME}`,
    'http://localhost:8080' // local dev only
  ],
  methods: ['POST'],
  allowedHeaders: ['Content-Type']
}));

app.use(express.json({ limit: '10kb' })); // prevent large payload attacks

// Trust nginx reverse proxy for accurate IP rate limiting
app.set('trust proxy', 1);

// ─── RATE LIMITING ─────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 20,                   // 20 requests per IP per 15 min
  message: { error: 'Too many requests. Please wait a few minutes.' },
  standardHeaders: true,
  legacyHeaders: false
});

app.use('/api/chat', limiter);

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
        'x-api-key': API_KEY,
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

// ─── START ─────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`AI chat proxy running on port ${PORT}`);
});