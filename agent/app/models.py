from pydantic import BaseModel
from typing import Optional, Any
from enum import Enum


class ActionType(str, Enum):
    QUERY = "query"
    CREATE = "create"
    MODIFY = "modify"
    DELETE = "delete"


class Intent(BaseModel):
    action: ActionType
    resources: list[str]
    description: str


class EC2Instance(BaseModel):
    instance_id: str
    name: str
    state: str
    instance_type: str
    public_ip: Optional[str] = None
    private_ip: str
    az: str
    tags: dict[str, str] = {}


class Subnet(BaseModel):
    subnet_id: str
    cidr: str
    az: str
    public: bool


class VPC(BaseModel):
    vpc_id: str
    cidr: str
    name: str
    subnets: list[Subnet] = []


class SGRule(BaseModel):
    protocol: str
    from_port: int
    to_port: int
    source: str


class SecurityGroup(BaseModel):
    group_id: str
    name: str
    description: str
    vpc_id: str
    inbound: list[SGRule] = []


class EIP(BaseModel):
    allocation_id: str
    public_ip: str
    associated_instance: Optional[str] = None


class ECRRepo(BaseModel):
    name: str
    uri: str
    image_count: int = 0


class InfrastructureState(BaseModel):
    region: str
    ec2_instances: list[EC2Instance] = []
    vpcs: list[VPC] = []
    security_groups: list[SecurityGroup] = []
    ecr_repos: list[ECRRepo] = []
    eips: list[EIP] = []
    ssm_parameters: list[str] = []
    scanned_at: str


class PlanOperation(BaseModel):
    phase: int
    action: str  # CREATE | MODIFY | DELETE | REUSE | QUERY | GENERATE
    resource_type: str
    resource_name: str
    details: str
    safe: bool = True


class ExecutionPlan(BaseModel):
    intent_summary: str
    operations: list[PlanOperation]
    risk_level: str  # LOW | MEDIUM | HIGH
    estimated_impact: str
    requires_approval: bool
    is_readonly: bool


class ExecutionResult(BaseModel):
    success: bool
    message: str
    details: list[str] = []
    terraform_snippet: Optional[str] = None
