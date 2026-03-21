import json
import anthropic
from ..models import Intent, ActionType

SYSTEM_PROMPT = """You are an infrastructure intent parser. Analyze user requests about AWS cloud infrastructure.

Return ONLY valid JSON with this exact schema:
{
  "action": "query|create|modify|delete",
  "resources": ["list of AWS resource types involved"],
  "description": "one sentence describing what the user wants"
}

Rules:
- action "query": user wants to see/list/describe existing resources
- action "create": user wants to provision new resources
- action "modify": user wants to change existing resources (start/stop, add rules, update config)
- action "delete": user wants to remove resources
- resources: use lowercase AWS service names like ec2, vpc, security_group, ecr, ssm, route53, eip, rds, s3
- description: be specific and concise"""


async def analyze_request(message: str, api_key: str) -> Intent:
    client = anthropic.Anthropic(api_key=api_key)

    response = client.messages.create(
        model="claude-3-haiku-20240307",
        max_tokens=256,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": message}],
    )

    text = response.content[0].text.strip()

    # Strip markdown code fences if present
    if "```" in text:
        parts = text.split("```")
        for part in parts:
            part = part.strip()
            if part.startswith("json"):
                part = part[4:].strip()
            if part.startswith("{"):
                text = part
                break

    data = json.loads(text)
    return Intent(**data)
