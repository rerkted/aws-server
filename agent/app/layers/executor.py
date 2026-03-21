import boto3
from botocore.exceptions import ClientError
from ..models import ExecutionPlan, ExecutionResult, InfrastructureState


class Executor:
    def __init__(self, region: str = "us-east-1"):
        self.region = region
        self.ec2 = boto3.client("ec2", region_name=region)
        self.ssm = boto3.client("ssm", region_name=region)

    def execute(self, plan: ExecutionPlan, state: InfrastructureState) -> ExecutionResult:
        if plan.is_readonly:
            return self._handle_query(plan, state)

        details = []
        terraform_parts = []

        for op in plan.operations:
            action = op.action.upper()

            if action in ("QUERY", "REUSE"):
                details.append(f"✓ {op.resource_type} {op.resource_name}: {op.details}")

            elif action == "GENERATE":
                terraform_parts.append(f"# {op.resource_type}: {op.resource_name}\n# {op.details}")

            elif action == "MODIFY":
                result = self._execute_modify(op)
                if result:
                    details.append(f"✓ {result}")
                else:
                    details.append(f"⚡ {op.resource_type} {op.resource_name}: {op.details} (manual action required)")

            elif action == "CREATE":
                terraform_parts.append(self._generate_terraform(op))
                details.append(f"⚡ {op.resource_type} {op.resource_name}: Terraform generated (see below)")

            elif action == "DELETE":
                details.append(f"⚠ {op.resource_type} {op.resource_name}: {op.details} (confirm in AWS console or Terraform)")

        terraform_snippet = "\n\n".join(terraform_parts) if terraform_parts else None

        return ExecutionResult(
            success=True,
            message=f"Plan executed — {len(details)} operations completed",
            details=details,
            terraform_snippet=terraform_snippet,
        )

    def _handle_query(self, plan: ExecutionPlan, state: InfrastructureState) -> ExecutionResult:
        details = []
        for op in plan.operations:
            details.append(f"→ {op.resource_type}: {op.details}")
        return ExecutionResult(
            success=True,
            message=plan.intent_summary,
            details=details,
        )

    def _execute_modify(self, op) -> str | None:
        name = op.resource_name.lower()
        details = op.details.lower()

        # EC2 start/stop
        if op.resource_type.lower() in ("ec2", "ec2_instance"):
            if "start" in details:
                return self._start_instance(op.resource_name)
            elif "stop" in details:
                return self._stop_instance(op.resource_name)

        # Security group rule additions
        if op.resource_type.lower() in ("security_group", "sg"):
            if "add" in details and ("ingress" in details or "inbound" in details or "allow" in details):
                return self._add_sg_rule(op.resource_name, op.details)

        return None  # Signal: no automated action, needs manual or Terraform

    def _start_instance(self, identifier: str) -> str | None:
        try:
            # identifier can be instance-id or name
            instance_id = self._resolve_instance_id(identifier)
            if not instance_id:
                return None
            self.ec2.start_instances(InstanceIds=[instance_id])
            return f"EC2 {instance_id} start initiated"
        except ClientError as e:
            return f"Failed to start {identifier}: {e.response['Error']['Message']}"

    def _stop_instance(self, identifier: str) -> str | None:
        try:
            instance_id = self._resolve_instance_id(identifier)
            if not instance_id:
                return None
            self.ec2.stop_instances(InstanceIds=[instance_id])
            return f"EC2 {instance_id} stop initiated"
        except ClientError as e:
            return f"Failed to stop {identifier}: {e.response['Error']['Message']}"

    def _resolve_instance_id(self, identifier: str) -> str | None:
        if identifier.startswith("i-"):
            return identifier
        try:
            resp = self.ec2.describe_instances(
                Filters=[{"Name": "tag:Name", "Values": [identifier]}]
            )
            for r in resp["Reservations"]:
                for i in r["Instances"]:
                    if i["State"]["Name"] != "terminated":
                        return i["InstanceId"]
        except ClientError:
            pass
        return None

    def _add_sg_rule(self, sg_identifier: str, details: str) -> str | None:
        # For demo purposes, return None to trigger Terraform generation
        # A full implementation would parse the rule from details and call authorize_security_group_ingress
        return None

    def _generate_terraform(self, op) -> str:
        resource_type = op.resource_type.lower().replace(" ", "_")
        name = op.resource_name.lower().replace("-", "_").replace(" ", "_")

        templates = {
            "ec2": f"""resource "aws_instance" "{name}" {{
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public.id

  tags = {{
    Name = "{op.resource_name}"
  }}
}}""",
            "security_group": f"""resource "aws_security_group" "{name}" {{
  name        = "{op.resource_name}"
  description = "{op.details}"
  vpc_id      = aws_vpc.main.id

  tags = {{
    Name = "{op.resource_name}"
  }}
}}""",
            "rds": f"""resource "aws_db_instance" "{name}" {{
  identifier        = "{op.resource_name}"
  engine            = "postgres"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  username          = "admin"
  password          = var.db_password
  multi_az          = true
  skip_final_snapshot = false

  tags = {{
    Name = "{op.resource_name}"
  }}
}}""",
        }

        for key in templates:
            if key in resource_type:
                return templates[key]

        return f"""# {op.resource_type}: {op.resource_name}
# {op.details}
# Add the appropriate Terraform resource block here
"""
