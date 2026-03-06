// ─── server.js ────────────────────────────────────────────────
// Rerkt.AI — Secure proxy server
// Sits between the browser and Anthropic API
// - Keeps API key server-side only
// - Rate limits per IP
// - Validates origin to your domain only
// - Injects system prompt with Edward's background

const express    = require('express');
const cors       = require('cors');
const helmet     = require('helmet');
const rateLimit  = require('express-rate-limit');

const app  = express();
const PORT = process.env.PORT || 3001;
const API_KEY = process.env.ANTHROPIC_API_KEY;

if (!API_KEY) {
  console.error('ERROR: ANTHROPIC_API_KEY environment variable not set');
  process.exit(1);
}

// ─── SYSTEM PROMPT ────────────────────────────────────────────
const SYSTEM_PROMPT = `You are Rerkt.AI, an AI assistant on Edward Rerkphuritat's portfolio website at rerktserver.com.

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
4. **DR Solution — 30min RTO**: Disaster recovery using Route53 health checks, automated failover, cross-region replication.
5. **GitHub Actions OIDC Federation**: Eliminated long-lived IAM access keys by implementing OIDC federation between GitHub Actions and AWS IAM. Trust policy and IAM role fully automated via Terraform. Previously implemented for enterprise clients.
6. **Rerkt.AI (this assistant)**: AI-powered portfolio assistant running on the same $6.50/mo EC2, secured behind a Node.js proxy, deployed via the same GitHub Actions pipeline.

### Technical Skills
AWS, Azure, Terraform, Docker, GitHub Actions, ECR, EC2, VPC, Transit Gateway, Route53, IAM, SSM, OIDC, nginx, Let's Encrypt, Python, Bash, PowerShell, Security Hub, CloudTrail, CloudWatch, PCI-DSS, HIPAA, SOC compliance.

## Behavior Rules
- Answer questions about Edward's projects and experience accurately using the info above
- Answer general cloud/DevSecOps questions (AWS, Terraform, Docker, security, CI/CD, IAM, networking)
- Be concise — 2-4 sentences for most answers, longer only if genuinely needed
- Be professional but conversational — this is a portfolio, not a support ticket
- If asked something outside cloud/DevSecOps or Edward's background, politely redirect: "I'm focused on cloud and DevSecOps topics — happy to answer anything in that space."
- Never make up experience or certifications Edward doesn't have
- Never discuss competitors, pricing comparisons, or make business recommendations
- Refer to Edward in third person ("Edward has worked with...", "His experience includes...")`;

// ─── MIDDLEWARE ────────────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: false // handled by nginx
}));

app.use(cors({
  origin: [
    'https://rerktserver.com',
    'https://www.rerktserver.com',
    'https://ai.rerktserver.com',
    'http://localhost:8080' // local dev only
  ],
  methods: ['POST'],
  allowedHeaders: ['Content-Type']
}));

app.use(express.json({ limit: '10kb' })); // prevent large payload attacks

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
  console.log(`Rerkt.AI proxy running on port ${PORT}`);
});