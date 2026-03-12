// ─── bedrock/server.js ────────────────────────────────────────
// Bedrock AI — AWS Bedrock proxy server
// Differences from chat/server.js:
// - Uses AWS Bedrock SDK instead of Anthropic API
// - Authenticates via IAM role (no API key needed)
// - Calls Claude on Bedrock via AWS SDK
// - Runs on port 3002

const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const rateLimit = require('express-rate-limit');
const { BedrockRuntimeClient, InvokeModelCommand } = require('@aws-sdk/client-bedrock-runtime');

const app         = express();
const PORT        = process.env.PORT || 3002;
const REGION      = process.env.AWS_REGION || 'us-east-1';
const DOMAIN_NAME = process.env.DOMAIN_NAME || 'YOUR_DOMAIN';

// Claude on Bedrock model ID
const MODEL_ID = 'anthropic.claude-3-haiku-20240307-v1:0';

// AWS Bedrock client — uses EC2 instance role automatically (no keys needed)
const bedrock = new BedrockRuntimeClient({ region: REGION });

// ─── SYSTEM PROMPT ────────────────────────────────────────────
// Replace all YOUR_* placeholders below with your own information.
const SYSTEM_PROMPT = `You are YOUR_AI_NAME (Bedrock Edition), an AI assistant on YOUR_NAME's portfolio website at YOUR_DOMAIN.

You are powered by AWS Bedrock — Amazon's fully managed AI service — using Claude via native AWS infrastructure rather than an external API.

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
4. **AI Chat (ai.YOUR_DOMAIN)**: YOUR_PROJECT_DESC_AI_CHAT
5. **AI Bedrock (bedrock.YOUR_DOMAIN)**: This assistant — same concept as Project 4 but powered entirely through AWS Bedrock. No external API keys — authentication via EC2 IAM instance role.

### Technical Skills
YOUR_SKILLS_LIST

## Behavior Rules
- Answer concisely — 2-4 sentences for most responses
- Be professional but conversational
- Refer to YOUR_FIRST_NAME in third person
- For questions outside YOUR_DOMAIN_AREA/YOUR_FIRST_NAME's work, politely decline
- Never fabricate experience, certifications, or projects YOUR_FIRST_NAME hasn't done
- When asked about the difference between this and ai.YOUR_DOMAIN, explain: this uses AWS Bedrock (IAM auth, stays within AWS), while ai.YOUR_DOMAIN calls Anthropic's API directly (API key auth, external service)`;

// ─── MIDDLEWARE ────────────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: false
}));

app.use(cors({
  origin: [
    `https://${DOMAIN_NAME}`,
    `https://www.${DOMAIN_NAME}`,
    `https://bedrock.${DOMAIN_NAME}`,
    'http://localhost:8080'
  ],
  methods: ['POST'],
  allowedHeaders: ['Content-Type']
}));

app.use(express.json({ limit: '10kb' }));

// Trust nginx reverse proxy for accurate IP rate limiting
app.set('trust proxy', 1);

// ─── RATE LIMITING ─────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  message: { error: 'Too many requests. Please wait a few minutes.' },
  standardHeaders: true,
  legacyHeaders: false
});

app.use('/api/chat', limiter);

// ─── DAILY REQUEST CAP ─────────────────────────────────────────
// Hard limit to control Bedrock costs — resets at midnight UTC
const DAILY_LIMIT = 50;
let dailyCount = 0;
let lastReset = new Date().toDateString();

function checkDailyLimit(req, res, next) {
  const today = new Date().toDateString();
  if (today !== lastReset) {
    dailyCount = 0;
    lastReset = today;
  }
  if (dailyCount >= DAILY_LIMIT) {
    return res.status(429).json({ error: 'Daily request limit reached. Try again tomorrow.' });
  }
  dailyCount++;
  next();
}

app.use('/api/chat', checkDailyLimit);

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

  const trimmedMessages = messages.slice(-10).map(m => ({
    role: m.role === 'user' ? 'user' : 'assistant',
    content: String(m.content).slice(0, 2000)
  }));

  try {
    // Bedrock uses the Anthropic Messages API format wrapped in InvokeModel
    const payload = {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: 512,
      system: SYSTEM_PROMPT,
      messages: trimmedMessages
    };

    const command = new InvokeModelCommand({
      modelId: MODEL_ID,
      contentType: 'application/json',
      accept: 'application/json',
      body: JSON.stringify(payload)
    });

    const response = await bedrock.send(command);
    const result = JSON.parse(new TextDecoder().decode(response.body));

    const text = result?.content?.[0]?.text;
    if (!text) {
      return res.status(500).json({ error: 'No response from Bedrock' });
    }

    console.log(`Bedrock request ${dailyCount}/${DAILY_LIMIT} today`);
    res.json({ response: text });

  } catch (err) {
    console.error('Bedrock API error:', err.message || err);
    res.status(500).json({ error: 'AI service temporarily unavailable' });
  }
});

// ─── START ─────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Bedrock AI proxy running on port ${PORT}`);
});
