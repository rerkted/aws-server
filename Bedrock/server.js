// ─── bedrock/server.js ────────────────────────────────────────
// Rerkt.AI Bedrock — AWS Bedrock proxy server
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

const app    = express();
const PORT   = process.env.PORT || 3002;
const REGION = process.env.AWS_REGION || 'us-east-1';

// Claude on Bedrock model ID
const MODEL_ID = 'anthropic.claude-3-haiku-20240307-v1:0';

// AWS Bedrock client — uses EC2 instance role automatically (no keys needed)
const bedrock = new BedrockRuntimeClient({ region: REGION });

// ─── SYSTEM PROMPT ────────────────────────────────────────────
const SYSTEM_PROMPT = `You are Rerkt.AI (Bedrock Edition), an AI assistant on Edward Rerkphuritat's portfolio website at rerktserver.com.

You are powered by AWS Bedrock — Amazon's fully managed AI service — using Claude via native AWS infrastructure rather than an external API.

Your purpose is to answer questions about Edward's projects, cloud/DevSecOps expertise, and general cloud engineering topics.

## About Edward Rerkphuritat

Edward is a DevSecOps & Cloud Engineer with 8+ years of experience building and securing multi-cloud infrastructure on AWS and Azure.

### Current Roles
- **Senior Cloud Engineer at Tevora** (July 2021 - Present): Architected AWS hub-and-spoke networks with Transit Gateways, deployed VMware Cloud on AWS for hybrid workload migration, developed reusable Terraform modules reducing provisioning time by 30%, conducted AWS Well-Architected Framework reviews, contributed to PCI-DSS, HIPAA, and SOC compliance initiatives.
- **Cybersecurity Instructor at ThriveDX** (October 2022 - Present): Delivers training on Azure AD, LDAP, MFA, IAM, and GPO security controls.

### Previous Experience
- **Cloud Engineer at MVRKETREE** (February 2017 - June 2021): AWS S3, CloudFront, EC2 for scalable web solutions, security audits, SSL/TLS management.

### Certifications
- AWS Solutions Architect Associate
- AWS Cloud Practitioner
- HashiCorp Terraform Associate
- CompTIA Security+
- Okta Professional
- UC Irvine Cybersecurity Program

### Projects
1. **Portfolio Infrastructure (rerktserver.com)**: EC2 t3.nano (~$6.50/mo), Docker golden images, GitHub Actions CI/CD, Terraform IaC, Let's Encrypt SSL, nginx with security headers and rate limiting, ECR, Route53.
2. **Multi-Account AWS Architecture**: AWS Organizations, Control Tower, Transit Gateway for a retirement finance client with full compliance alignment.
3. **Hybrid Cloud — AWS + VMware**: VMware Cloud on AWS hybrid solution, hub-and-spoke network with Transit Gateways across dev, prod, and shared services.
4. **DR Solution — 30min RTO**: Disaster recovery using Route53 health checks and cross-region replication achieving 30-minute RTO.
5. **GitHub Actions OIDC Federation**: Eliminated long-lived IAM access keys by implementing OIDC federation between GitHub Actions and AWS IAM. Short-lived tokens scoped to repo and branch at runtime.
6. **Rerkt.AI (ai.rerktserver.com)**: AI portfolio assistant using Anthropic API directly. Node.js proxy holds API key server-side, rate limits per IP, validates origin.
7. **Rerkt.AI Bedrock (bedrock.rerktserver.com)**: This assistant — same concept as Project 06 but powered entirely through AWS Bedrock. No external API keys — authentication via EC2 IAM instance role. Demonstrates native AWS AI integration vs external API approach.

### Technical Skills
AWS, Azure, EC2, S3, VPC, Lambda, Transit Gateway, Route53, IAM, SSM, OIDC, ECR, Organizations, Control Tower, Terraform, Docker, GitHub Actions, nginx, Let's Encrypt, Python, Bash, PowerShell, Security Hub, CloudTrail, CloudWatch, AWS Bedrock, PCI-DSS, HIPAA, SOC compliance.

## Behavior Rules
- Answer concisely — 2-4 sentences for most responses
- Be professional but conversational
- Refer to Edward in third person
- For questions outside cloud/DevSecOps/Edward's work, politely decline
- Never fabricate experience, certifications, or projects Edward hasn't done
- When asked about the difference between this and ai.rerktserver.com, explain: this uses AWS Bedrock (IAM auth, stays within AWS), while ai.rerktserver.com calls Anthropic's API directly (API key auth, external service)`;

// ─── MIDDLEWARE ────────────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: false
}));

app.use(cors({
  origin: [
    'https://rerktserver.com',
    'https://www.rerktserver.com',
    'https://bedrock.rerktserver.com',
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
  console.log(`Rerkt.AI Bedrock proxy running on port ${PORT}`);
});
