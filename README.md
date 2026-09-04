# aws-training

Hands-on AWS lab: an EC2 instance in one VPC (us-east-1) reaching a
DynamoDB table in another region's VPC (us-west-2), with IAM least-privilege
access, SSM-based (no SSH) instance access, and VPC Flow Logs used to
validate the traffic at the network layer.

See [`EC2-TO-DYNAMODB-CROSS-REGION-SPEC.md`](./EC2-TO-DYNAMODB-CROSS-REGION-SPEC.md)
for the architecture diagram and full step-by-step record of what was built
and why, including the architecture decisions (why DynamoDB isn't "inside" a
VPC, why an Internet Gateway was used instead of a NAT Gateway, etc.) and
the exact resource IDs created.

Run `python cleanup.py` (`--dry-run` to preview first) to tear down every
resource this lab created.
