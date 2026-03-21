# Infrastructure AI Agent

A production-grade AI agent that understands and manages live AWS infrastructure through natural language. Deployed at `agent.rerktserver.com`.

## Purpose

Demonstrates a multi-layer AIOps pattern where an AI agent can:
- Discover real AWS infrastructure state in real time
- Reason over that state to generate safe execution plans
- Gate all mutating operations behind a human approval step
- Stream every layer's output to the user via WebSocket

Built as a portfolio project to showcase AI + DevSecOps engineering — not a toy chatbot, but a structured agent with explicit separation of concerns across four layers.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Browser                                │
│                    agent.rerktserver.com                            │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ HTTPS + WebSocket (wss://)
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    nginx (portfolio container)                       │
│              Reverse proxy — port 443 → :3003                       │
│           WebSocket upgrade headers + TLS termination               │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ proxy_pass http://172.17.0.1:3003
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│              FastAPI + uvicorn  (agent-ai container)                │
│                    WebSocket /ws/{session_id}                        │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  LAYER 1 — Request Analysis                                  │   │
│  │  Natural language → structured Intent (action + target)      │   │
│  │  Model: Claude Haiku  (fast + cheap)                         │   │
│  └────────────────────────────┬─────────────────────────────────┘   │
│                               │ Intent                              │
│  ┌────────────────────────────▼─────────────────────────────────┐   │
│  │  LAYER 2 — State Discovery                                   │   │
│  │  boto3 scans live AWS: EC2, VPC, SG, ECR, EIP, SSM          │   │
│  │  Auth: EC2 instance role via IMDS (no hardcoded keys)        │   │
│  └────────────────────────────┬─────────────────────────────────┘   │
│                               │ InfrastructureState                 │
│  ┌────────────────────────────▼─────────────────────────────────┐   │
│  │  LAYER 3 — Planning                                          │   │
│  │  Claude reasons over Intent + State → ExecutionPlan          │   │
│  │  Flags risk level + requires_approval for mutating ops       │   │
│  │  Model: Claude Sonnet 4.6  (complex reasoning)               │   │
│  └────────────────────────────┬─────────────────────────────────┘   │
│                               │ ExecutionPlan                       │
│  ┌────────────────────────────▼─────────────────────────────────┐   │
│  │  LAYER 4 — Executor                                          │   │
│  │                                                              │   │
│  │   READ-ONLY ops ──────────────────► Execute immediately      │   │
│  │                                                              │   │
│  │   MUTATING ops ───► Human approval gate ──► boto3 / TF      │   │
│  │   (CREATE / MODIFY / DELETE)    ▲                            │   │
│  │                                 │ approve / reject           │   │
│  │                              User Browser                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                           │
          ┌────────────────┴───────────────┐
          ▼                                ▼
┌──────────────────┐             ┌──────────────────────┐
│  Anthropic API   │             │      AWS APIs         │
│  Claude Haiku    │             │  EC2 / VPC / SG / ECR │
│  Claude Sonnet   │             │  SSM Parameter Store  │
└──────────────────┘             └──────────────────────┘
```

## How It Works

1. **User types** a natural language request (e.g. "show me all running EC2 instances")
2. **Layer 1** (Haiku) parses the intent into a structured action type: `DESCRIBE`, `CREATE`, `MODIFY`, `DELETE`, or `COST_ESTIMATE`
3. **Layer 2** (boto3) scans the live AWS account — EC2, VPCs, security groups, ECR repos, EIPs, SSM parameters
4. **Layer 3** (Sonnet) receives both the intent and the current state, then generates a phased execution plan with risk assessment
5. **Layer 4** checks `requires_approval`:
   - Read-only → executes immediately, streams results
   - Mutating → sends plan to UI, waits for user to click Approve or Reject
6. All layer outputs stream to the browser in real time via WebSocket (`thinking` → `state` → `plan` → `result`)

## Stack

| Component | Technology |
|---|---|
| Backend | Python 3.12, FastAPI, uvicorn |
| AI | Anthropic Claude (Haiku + Sonnet 4.6) |
| AWS SDK | boto3 (EC2, SSM, ECR) |
| Transport | WebSocket (real-time streaming) |
| Auth | EC2 IAM instance role via IMDS |
| Container | Docker, Amazon ECR |
| Reverse proxy | nginx (WebSocket upgrade) |
| TLS | Let's Encrypt |
| CI/CD | GitHub Actions + OIDC |

## Project Structure

```
agent/
├── Dockerfile
├── requirements.txt
├── app/
│   ├── main.py              # FastAPI app, WebSocket endpoint, session store
│   ├── models.py            # Pydantic models (Intent, InfrastructureState, ExecutionPlan)
│   └── layers/
│       ├── request_analysis.py   # Layer 1 — Claude Haiku
│       ├── state_manager.py      # Layer 2 — boto3 discovery
│       ├── planner.py            # Layer 3 — Claude Sonnet
│       └── executor.py           # Layer 4 — boto3 execution + Terraform generation
└── static/
    └── index.html           # Dark terminal UI, WebSocket client
```

## Security

- **No hardcoded credentials** — boto3 authenticates via EC2 instance role (IMDS)
- **Human approval gate** — all CREATE/MODIFY/DELETE operations require explicit user confirmation
- **Rate limiting** — nginx limits agent endpoint to 10 req/min
- **IAM least privilege** — EC2 role scoped to Describe + limited Modify only
