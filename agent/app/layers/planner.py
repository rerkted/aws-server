import json
import anthropic
from ..models import Intent, InfrastructureState, ExecutionPlan, PlanOperation

SYSTEM_PROMPT = """You are an AWS infrastructure planning engine. Given a user's intent and the current state of their AWS environment, generate a precise execution plan.

Return ONLY valid JSON with this schema:
{
  "intent_summary": "one sentence summary of what will be done",
  "operations": [
    {
      "phase": 1,
      "action": "QUERY|CREATE|MODIFY|DELETE|REUSE|GENERATE",
      "resource_type": "aws resource type",
      "resource_name": "specific resource name or identifier",
      "details": "exactly what will happen",
      "safe": true
    }
  ],
  "risk_level": "LOW|MEDIUM|HIGH",
  "estimated_impact": "brief description of impact",
  "requires_approval": false,
  "is_readonly": true
}

Rules:
- QUERY: read-only, no changes (safe=true, requires_approval=false, is_readonly=true)
- REUSE: using an existing resource without changes (safe=true)
- CREATE: provisioning new resources (safe=false, requires_approval=true)
- MODIFY: changing existing resources — start/stop/update (safe=false, requires_approval=true)
- DELETE: removing resources (safe=false, requires_approval=true, risk_level=HIGH)
- GENERATE: producing Terraform code (safe=true)
- requires_approval: true if ANY operation is CREATE/MODIFY/DELETE
- is_readonly: true only if ALL operations are QUERY or REUSE
- For complex changes (new EC2, RDS, ELB), use GENERATE to produce Terraform — do not attempt direct API changes
- For simple changes (start/stop instance, add SG rule, update SSM param), use MODIFY
- risk_level LOW: read-only or trivial changes; MEDIUM: config changes; HIGH: deletions or large-scale changes
- Order operations by phase: networking before compute, compute before load balancers
- If something already exists, use REUSE not CREATE"""


def _format_state(state: InfrastructureState) -> str:
    lines = [f"AWS Region: {state.region}", f"Scanned: {state.scanned_at}", ""]

    lines.append("=== EC2 INSTANCES ===")
    if state.ec2_instances:
        for inst in state.ec2_instances:
            lines.append(f"  {inst.name} ({inst.instance_id}): {inst.state} | {inst.instance_type} | {inst.az} | IP: {inst.public_ip or inst.private_ip}")
    else:
        lines.append("  none")

    lines.append("\n=== VPCs ===")
    if state.vpcs:
        for vpc in state.vpcs:
            lines.append(f"  {vpc.name} ({vpc.vpc_id}): {vpc.cidr} | {len(vpc.subnets)} subnets")
            for s in vpc.subnets:
                lines.append(f"    subnet {s.subnet_id}: {s.cidr} | {s.az} | {'public' if s.public else 'private'}")
    else:
        lines.append("  none")

    lines.append("\n=== SECURITY GROUPS ===")
    if state.security_groups:
        for sg in state.security_groups:
            lines.append(f"  {sg.name} ({sg.group_id})")
            for rule in sg.inbound[:5]:
                lines.append(f"    inbound: {rule.protocol} {rule.from_port}-{rule.to_port} from {rule.source}")
    else:
        lines.append("  none")

    lines.append("\n=== ECR REPOSITORIES ===")
    if state.ecr_repos:
        for repo in state.ecr_repos:
            lines.append(f"  {repo.name}: {repo.image_count} images | {repo.uri}")
    else:
        lines.append("  none")

    lines.append("\n=== ELASTIC IPs ===")
    if state.eips:
        for eip in state.eips:
            assoc = f"-> {eip.associated_instance}" if eip.associated_instance else "(unattached)"
            lines.append(f"  {eip.public_ip} {assoc}")
    else:
        lines.append("  none")

    lines.append("\n=== SSM PARAMETERS ===")
    if state.ssm_parameters:
        for p in state.ssm_parameters:
            lines.append(f"  {p}")
    else:
        lines.append("  none")

    return "\n".join(lines)


async def generate_plan(intent: Intent, state: InfrastructureState, api_key: str) -> ExecutionPlan:
    client = anthropic.Anthropic(api_key=api_key)

    state_text = _format_state(state)
    user_content = f"""User request: {intent.description}
Action type: {intent.action.value}
Resources involved: {", ".join(intent.resources)}

Current infrastructure state:
{state_text}

Generate the execution plan."""

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=2048,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )

    text = response.content[0].text.strip()

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
    ops = [PlanOperation(**op) for op in data.get("operations", [])]
    return ExecutionPlan(
        intent_summary=data["intent_summary"],
        operations=ops,
        risk_level=data.get("risk_level", "LOW"),
        estimated_impact=data.get("estimated_impact", ""),
        requires_approval=data.get("requires_approval", False),
        is_readonly=data.get("is_readonly", True),
    )
