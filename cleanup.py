"""Consolidated cleanup for the aws-training cross-region EC2->DynamoDB lab.

Removes, in dependency order: EC2 instance, VPC Flow Log, CloudWatch Log
Group, DynamoDB table, both IAM roles (+ the EC2 instance profile), then
each VPC's networking (subnets, route tables, internet gateways, non-default
security groups), then the VPCs themselves.

Safe to re-run: every step tolerates "already gone" (catches the relevant
NotFound/DoesNotExist exceptions) so a partial prior run or manual deletion
of something doesn't block the rest.

Usage:
    python cleanup.py                 # uses the IDs baked in below (this lab's actual resources)
    python cleanup.py --dry-run       # print what would be deleted, delete nothing
"""
import argparse

import boto3

EAST_REGION = "us-east-1"
WEST_REGION = "us-west-2"

EAST_VPC_ID = "vpc-0df27265fd3dca4ac"
WEST_VPC_ID = "vpc-0e2bafe7b31c1c5fd"
INSTANCE_ID = "i-0aa25e791634f1c78"
TABLE_NAME = "aws-trainer-demo-table"
EC2_ROLE_NAME = "aws-trainer-ec2-dynamodb-role"
EC2_INSTANCE_PROFILE = "aws-trainer-ec2-dynamodb-profile"
FLOW_LOGS_ROLE_NAME = "aws-trainer-vpc-flow-logs-role"
FLOW_LOGS_LOG_GROUP = "/aws-trainer/vpc-flow-logs"


def step(label: str, dry_run: bool, fn, *args, **kwargs):
    print(f"-> {label}")
    if dry_run:
        return
    try:
        fn(*args, **kwargs)
    except Exception as e:  # noqa: BLE001 - cleanup should not stop on one failure
        print(f"   (skipped/already gone: {type(e).__name__}: {str(e)[:150]})")


def terminate_ec2(dry_run: bool):
    ec2 = boto3.client("ec2", region_name=EAST_REGION)

    def _do():
        ec2.terminate_instances(InstanceIds=[INSTANCE_ID])
        ec2.get_waiter("instance_terminated").wait(InstanceIds=[INSTANCE_ID])

    step(f"Terminate EC2 instance {INSTANCE_ID}", dry_run, _do)


def delete_flow_logs(dry_run: bool):
    ec2 = boto3.client("ec2", region_name=EAST_REGION)
    logs = boto3.client("logs", region_name=EAST_REGION)

    def _delete_flow_log():
        resp = ec2.describe_flow_logs(
            Filters=[{"Name": "resource-id", "Values": [EAST_VPC_ID]}]
        )
        ids = [f["FlowLogId"] for f in resp["FlowLogs"]]
        if ids:
            ec2.delete_flow_logs(FlowLogIds=ids)

    def _delete_log_group():
        logs.delete_log_group(logGroupName=FLOW_LOGS_LOG_GROUP)

    step("Delete VPC Flow Log(s) on east VPC", dry_run, _delete_flow_log)
    step(f"Delete CloudWatch Log Group {FLOW_LOGS_LOG_GROUP}", dry_run, _delete_log_group)


def delete_dynamodb_table(dry_run: bool):
    ddb = boto3.client("dynamodb", region_name=WEST_REGION)
    step(f"Delete DynamoDB table {TABLE_NAME}", dry_run, ddb.delete_table, TableName=TABLE_NAME)


def delete_iam_resources(dry_run: bool):
    iam = boto3.client("iam")

    def _delete_ec2_role():
        try:
            iam.remove_role_from_instance_profile(
                InstanceProfileName=EC2_INSTANCE_PROFILE, RoleName=EC2_ROLE_NAME
            )
        except iam.exceptions.NoSuchEntityException:
            pass
        try:
            iam.delete_instance_profile(InstanceProfileName=EC2_INSTANCE_PROFILE)
        except iam.exceptions.NoSuchEntityException:
            pass
        try:
            iam.detach_role_policy(
                RoleName=EC2_ROLE_NAME,
                PolicyArn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
            )
        except iam.exceptions.NoSuchEntityException:
            pass
        try:
            iam.delete_role_policy(
                RoleName=EC2_ROLE_NAME, PolicyName="aws-trainer-dynamodb-scoped-access"
            )
        except iam.exceptions.NoSuchEntityException:
            pass
        iam.delete_role(RoleName=EC2_ROLE_NAME)

    def _delete_flow_logs_role():
        try:
            iam.delete_role_policy(
                RoleName=FLOW_LOGS_ROLE_NAME,
                PolicyName="aws-trainer-flow-logs-cloudwatch-delivery",
            )
        except iam.exceptions.NoSuchEntityException:
            pass
        iam.delete_role(RoleName=FLOW_LOGS_ROLE_NAME)

    step(f"Delete IAM role/profile {EC2_ROLE_NAME}", dry_run, _delete_ec2_role)
    step(f"Delete IAM role {FLOW_LOGS_ROLE_NAME}", dry_run, _delete_flow_logs_role)


def teardown_vpc_networking(region: str, vpc_id: str, dry_run: bool):
    ec2 = boto3.client("ec2", region_name=region)

    def _do():
        for sg in ec2.describe_security_groups(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["SecurityGroups"]:
            if sg["GroupName"] != "default":
                ec2.delete_security_group(GroupId=sg["GroupId"])

        for rt in ec2.describe_route_tables(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["RouteTables"]:
            if not any(assoc.get("Main") for assoc in rt["Associations"]):
                for assoc in rt["Associations"]:
                    if assoc.get("RouteTableAssociationId"):
                        ec2.disassociate_route_table(
                            AssociationId=assoc["RouteTableAssociationId"]
                        )
                ec2.delete_route_table(RouteTableId=rt["RouteTableId"])

        for igw in ec2.describe_internet_gateways(
            Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
        )["InternetGateways"]:
            ec2.detach_internet_gateway(
                InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc_id
            )
            ec2.delete_internet_gateway(InternetGatewayId=igw["InternetGatewayId"])

        for subnet in ec2.describe_subnets(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["Subnets"]:
            ec2.delete_subnet(SubnetId=subnet["SubnetId"])

    step(f"Tear down networking in VPC {vpc_id} ({region})", dry_run, _do)


def delete_vpcs(dry_run: bool):
    ec2_east = boto3.client("ec2", region_name=EAST_REGION)
    ec2_west = boto3.client("ec2", region_name=WEST_REGION)
    step(f"Delete east VPC {EAST_VPC_ID}", dry_run, ec2_east.delete_vpc, VpcId=EAST_VPC_ID)
    step(f"Delete west VPC {WEST_VPC_ID}", dry_run, ec2_west.delete_vpc, VpcId=WEST_VPC_ID)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.dry_run:
        print("DRY RUN -- nothing will actually be deleted.\n")

    terminate_ec2(args.dry_run)
    delete_flow_logs(args.dry_run)
    delete_dynamodb_table(args.dry_run)
    delete_iam_resources(args.dry_run)
    teardown_vpc_networking(EAST_REGION, EAST_VPC_ID, args.dry_run)
    teardown_vpc_networking(WEST_REGION, WEST_VPC_ID, args.dry_run)
    delete_vpcs(args.dry_run)

    print("\nDone." if not args.dry_run else "\nDry run complete.")


if __name__ == "__main__":
    main()
