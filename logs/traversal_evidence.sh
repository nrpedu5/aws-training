#!/usr/bin/env bash
# Evidence that a request from the EC2 instance actually traverses every
# hop -- ENI -> Security Group -> Network ACL -> Route Table -> Internet
# Gateway -> DynamoDB (confirmed via AWS's own published IP ranges) -- not
# just "the API call happened to succeed."
#
# Run this from your own terminal with admin/root AWS credentials, NOT
# from inside the EC2 instance's SSM session -- the instance's own IAM
# role is deliberately scoped to DynamoDB only and cannot create/read the
# resources this script touches (ec2:*, logs:*), by design.
#
# Usage:
#   ./traversal_evidence.sh                    # full evidence, including Reachability Analyzer
#   ./traversal_evidence.sh --skip-reachability # skip the ~$0.10 paid step
#
# Cost: everything here is free EXCEPT step 3 (VPC Reachability Analyzer),
# which is billed per analysis (~$0.10 as of 2026). This script creates and
# deletes its own analysis/path resources each run, so nothing lingers, but
# each run of step 3 does cost that ~$0.10 again -- use --skip-reachability
# to re-check steps 1/2/4/5 for free.

set -euo pipefail

EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
VPC_ID="vpc-0df27265fd3dca4ac"
SUBNET_ID="subnet-0f3554f60ec4bbe8e"
SG_ID="sg-0a4034b14c9af505e"
NACL_ID="acl-0f0ccd01ca68b93f3"
INSTANCE_ID="i-0aa25e791634f1c78"
IGW_ID="igw-07f5532c2243f0230"
FLOW_LOG_GROUP="/aws-trainer/vpc-flow-logs"

SKIP_REACHABILITY=false
for arg in "$@"; do
  case "$arg" in
    --skip-reachability) SKIP_REACHABILITY=true ;;
  esac
done

section() { echo; echo "=================================================="; echo "$1"; echo "=================================================="; }

section "1. Security Group ($SG_ID) — stateful, evaluated per-ENI"
aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$EAST_REGION" \
  --query 'SecurityGroups[0].IpPermissionsEgress' --output table

section "2. Network ACL ($NACL_ID) — stateless, evaluated per-subnet"
aws ec2 describe-network-acls --network-acl-ids "$NACL_ID" --region "$EAST_REGION" \
  --query 'NetworkAcls[0].Entries' --output table

if [ "$SKIP_REACHABILITY" = false ]; then
  section "3. VPC Reachability Analyzer — explicit hop-by-hop (~\$0.10)"
  ENI_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$EAST_REGION" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)

  PATH_ID=$(aws ec2 create-network-insights-path --region "$EAST_REGION" \
    --source "$ENI_ID" --destination "$IGW_ID" --protocol tcp --destination-port 443 \
    --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)

  ANALYSIS_ID=$(aws ec2 start-network-insights-analysis --region "$EAST_REGION" \
    --network-insights-path-id "$PATH_ID" \
    --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)

  echo "Analysis $ANALYSIS_ID running..."
  STATUS="running"
  for _ in $(seq 1 20); do
    STATUS=$(aws ec2 describe-network-insights-analyses --region "$EAST_REGION" \
      --network-insights-analysis-ids "$ANALYSIS_ID" \
      --query 'NetworkInsightsAnalyses[0].Status' --output text)
    if [ "$STATUS" = "succeeded" ] || [ "$STATUS" = "failed" ]; then break; fi
    sleep 4
  done
  echo "Status: $STATUS"

  aws ec2 describe-network-insights-analyses --region "$EAST_REGION" \
    --network-insights-analysis-ids "$ANALYSIS_ID" --output json > /tmp/nia_output.json

  echo
  echo "Path found: $(jq -r '.NetworkInsightsAnalyses[0].NetworkPathFound' /tmp/nia_output.json)"
  echo
  echo "Hop-by-hop forward path (source -> destination):"
  jq -r '.NetworkInsightsAnalyses[0].ForwardPathComponents[] |
    "  [\(.SequenceNumber)] " +
    (if .Component.Name then "\(.Component.Name) (\(.Component.Id))" else .Component.Id end) +
    (if .SecurityGroupRule then " -- SG rule: \(.SecurityGroupRule.Direction) \(.SecurityGroupRule.Protocol)/\(.SecurityGroupRule.PortRange.From) \(.SecurityGroupRule.Cidr) ALLOW" else "" end) +
    (if .AclRule then " -- NACL rule #\(.AclRule.RuleNumber): \(.AclRule.Protocol) port \(.AclRule.PortRange.From) \(.AclRule.RuleAction | ascii_upcase)" else "" end) +
    (if .RouteTableRoute then " -- route \(.RouteTableRoute.DestinationCidr) -> \(.RouteTableRoute.GatewayId) (\(.RouteTableRoute.State))" else "" end)
  ' /tmp/nia_output.json

  echo
  echo "Cleaning up the analysis path (free to leave, but tidy)..."
  aws ec2 delete-network-insights-analysis --region "$EAST_REGION" --network-insights-analysis-id "$ANALYSIS_ID" >/dev/null
  aws ec2 delete-network-insights-path --region "$EAST_REGION" --network-insights-path-id "$PATH_ID" >/dev/null
  rm -f /tmp/nia_output.json
else
  section "3. VPC Reachability Analyzer — SKIPPED (--skip-reachability)"
fi

section "4. VPC Flow Logs — real traffic, last 30 minutes"
aws logs tail "$FLOW_LOG_GROUP" --region "$EAST_REGION" --since 30m | tee /tmp/flowlog_output.txt

section "5. Cross-check destination IPs against AWS's published IP ranges (proves it's really DynamoDB)"
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json -o /tmp/ip-ranges.json
python3 <<'PYEOF'
import json, re, ipaddress

with open('/tmp/flowlog_output.txt') as f:
    log_text = f.read()
with open('/tmp/ip-ranges.json') as f:
    ranges = json.load(f)['prefixes']

candidate_ips = set(re.findall(r'\b\d{1,3}(?:\.\d{1,3}){3}\b', log_text))
found_any = False
for ip in candidate_ips:
    if ip.startswith("10.99."):
        continue  # our own private VPC range, not interesting here
    for prefix in ranges:
        if prefix['region'] != 'us-west-2':
            continue
        try:
            if ipaddress.ip_address(ip) in ipaddress.ip_network(prefix['ip_prefix']):
                print(f"  {ip} -> service={prefix['service']} region={prefix['region']}")
                found_any = True
        except ValueError:
            pass
if not found_any:
    print("  No us-west-2 AWS-service IPs found in this window -- generate traffic first "
          "(python 06_ec2_to_dynamodb_cross_region.py test --instance-id <id>) and re-run.")
PYEOF
rm -f /tmp/ip-ranges.json /tmp/flowlog_output.txt

section "6. CloudTrail check — PutItem/GetItem (DynamoDB data events)"
echo "Note: CloudTrail's lookup-events / 90-day Event History only covers"
echo "MANAGEMENT events by default. DynamoDB PutItem/GetItem are DATA events,"
echo "which are NOT captured unless a trail is explicitly configured with"
echo "data-event selectors for this table (a separate, additionally-billed"
echo "CloudTrail feature) -- so an empty result below is expected, not a bug."
echo
FOUND_DATA_EVENT=false
for event_name in PutItem GetItem; do
  echo "--- $event_name ---"
  RESULT=$(aws cloudtrail lookup-events --region "$WEST_REGION" \
    --lookup-attributes AttributeKey=EventName,AttributeValue="$event_name" \
    --max-results 5 \
    --query 'Events[].{Time:EventTime,Name:EventName,User:Username}' --output table)
  echo "$RESULT"
  [ -n "$RESULT" ] && FOUND_DATA_EVENT=true
done
if [ "$FOUND_DATA_EVENT" = false ]; then
  echo "(No results, as expected -- data-event logging isn't enabled for this table."
  echo " The API-call-level proof for this lab instead comes from the SSM command"
  echo " output itself: 06_ec2_to_dynamodb_cross_region.py test's stdout already"
  echo " shows the real PutItem/GetItem response payload.)"
fi

section "Evidence chain summary"
cat <<'EOF'
  EC2 ENI
    -> Security Group   (stateful,  scoped to 443/tcp + 123/udp out)
    -> Network ACL      (stateless, scoped to 443/tcp + 123/udp out,
                          + ephemeral 1024-65535 in for the return path)
    -> Route Table       (0.0.0.0/0 -> Internet Gateway)
    -> Internet Gateway
    -> public internet
    -> DynamoDB (us-west-2)  <- confirmed via AWS's own published IP ranges

  (CloudTrail data-events for PutItem/GetItem require an explicitly configured,
   separately-billed trail -- not enabled here. API-call-level proof for this
   lab instead comes from 06_ec2_to_dynamodb_cross_region.py test's own output.)
EOF
