import boto3
from datetime import datetime, timezone
from botocore.exceptions import ClientError
from ..models import (
    InfrastructureState, EC2Instance, VPC, Subnet,
    SecurityGroup, SGRule, EIP, ECRRepo
)


class StateManager:
    def __init__(self, region: str = "us-east-1"):
        self.region = region
        self.ec2 = boto3.client("ec2", region_name=region)
        self.ecr = boto3.client("ecr", region_name=region)
        self.ssm = boto3.client("ssm", region_name=region)

    def discover(self) -> InfrastructureState:
        return InfrastructureState(
            region=self.region,
            ec2_instances=self._get_instances(),
            vpcs=self._get_vpcs(),
            security_groups=self._get_security_groups(),
            ecr_repos=self._get_ecr_repos(),
            eips=self._get_eips(),
            ssm_parameters=self._get_ssm_params(),
            scanned_at=datetime.now(timezone.utc).isoformat(),
        )

    def _tag(self, tags: list, key: str, default: str = "") -> str:
        for t in tags or []:
            if t["Key"] == key:
                return t["Value"]
        return default

    def _tags_dict(self, tags: list) -> dict:
        return {t["Key"]: t["Value"] for t in (tags or [])}

    def _get_instances(self) -> list[EC2Instance]:
        instances = []
        try:
            paginator = self.ec2.get_paginator("describe_instances")
            for page in paginator.paginate():
                for reservation in page["Reservations"]:
                    for inst in reservation["Instances"]:
                        if inst["State"]["Name"] == "terminated":
                            continue
                        instances.append(EC2Instance(
                            instance_id=inst["InstanceId"],
                            name=self._tag(inst.get("Tags", []), "Name", inst["InstanceId"]),
                            state=inst["State"]["Name"],
                            instance_type=inst["InstanceType"],
                            public_ip=inst.get("PublicIpAddress"),
                            private_ip=inst.get("PrivateIpAddress", ""),
                            az=inst["Placement"]["AvailabilityZone"],
                            tags=self._tags_dict(inst.get("Tags", [])),
                        ))
        except ClientError:
            pass
        return instances

    def _get_vpcs(self) -> list[VPC]:
        vpcs = []
        try:
            resp = self.ec2.describe_vpcs()
            for v in resp["Vpcs"]:
                subnets = self._get_subnets(v["VpcId"])
                vpcs.append(VPC(
                    vpc_id=v["VpcId"],
                    cidr=v["CidrBlock"],
                    name=self._tag(v.get("Tags", []), "Name", v["VpcId"]),
                    subnets=subnets,
                ))
        except ClientError:
            pass
        return vpcs

    def _get_subnets(self, vpc_id: str) -> list[Subnet]:
        subnets = []
        try:
            resp = self.ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
            for s in resp["Subnets"]:
                subnets.append(Subnet(
                    subnet_id=s["SubnetId"],
                    cidr=s["CidrBlock"],
                    az=s["AvailabilityZone"],
                    public=s.get("MapPublicIpOnLaunch", False),
                ))
        except ClientError:
            pass
        return subnets

    def _get_security_groups(self) -> list[SecurityGroup]:
        sgs = []
        try:
            resp = self.ec2.describe_security_groups()
            for sg in resp["SecurityGroups"]:
                inbound = []
                for perm in sg.get("IpPermissions", []):
                    protocol = perm.get("IpProtocol", "-1")
                    from_port = perm.get("FromPort", 0)
                    to_port = perm.get("ToPort", 65535)
                    for r in perm.get("IpRanges", []):
                        inbound.append(SGRule(
                            protocol=protocol,
                            from_port=from_port,
                            to_port=to_port,
                            source=r.get("CidrIp", "?"),
                        ))
                    for r in perm.get("UserIdGroupPairs", []):
                        inbound.append(SGRule(
                            protocol=protocol,
                            from_port=from_port,
                            to_port=to_port,
                            source=f"sg:{r.get('GroupId', '?')}",
                        ))
                sgs.append(SecurityGroup(
                    group_id=sg["GroupId"],
                    name=sg["GroupName"],
                    description=sg.get("Description", ""),
                    vpc_id=sg.get("VpcId", ""),
                    inbound=inbound,
                ))
        except ClientError:
            pass
        return sgs

    def _get_ecr_repos(self) -> list[ECRRepo]:
        repos = []
        try:
            paginator = self.ecr.get_paginator("describe_repositories")
            for page in paginator.paginate():
                for repo in page["repositories"]:
                    count = 0
                    try:
                        imgs = self.ecr.list_images(repositoryName=repo["repositoryName"])
                        count = len(imgs.get("imageIds", []))
                    except ClientError:
                        pass
                    repos.append(ECRRepo(
                        name=repo["repositoryName"],
                        uri=repo["repositoryUri"],
                        image_count=count,
                    ))
        except ClientError:
            pass
        return repos

    def _get_eips(self) -> list[EIP]:
        eips = []
        try:
            resp = self.ec2.describe_addresses()
            for addr in resp["Addresses"]:
                eips.append(EIP(
                    allocation_id=addr.get("AllocationId", ""),
                    public_ip=addr["PublicIp"],
                    associated_instance=addr.get("InstanceId"),
                ))
        except ClientError:
            pass
        return eips

    def _get_ssm_params(self) -> list[str]:
        params = []
        try:
            paginator = self.ssm.get_paginator("describe_parameters")
            for page in paginator.paginate():
                for p in page["Parameters"]:
                    params.append(p["Name"])
        except ClientError:
            pass
        return params
