# S3 Gateway Endpoint Timeout — Exam Scenario, Reproduced Hands-On

**Question:** A VPC in us-east-1 has a Gateway VPC Endpoint for S3,
associated with the **main route table**, which is attached to a public
subnet. An EC2 instance in that subnet tries to access an S3 bucket in the
same region and the request fails with a **timeout**. Which two things are
most likely wrong?

**Answer:** (A) the Security Group doesn't allow outbound 443, and (B) the
Network ACL doesn't allow the necessary traffic (specifically the inbound
ephemeral-port return-path rule). A restrictive endpoint policy or missing
IAM permission would cause **Access Denied**, not a timeout.

This isn't just asserted — every state below was actually built and tested
via `aws_ws/examples/08_s3_gateway_endpoint_timeout_scenario.py`.

## The three scenarios, grouped by phase with the specific action at each hop

```mermaid
sequenceDiagram
    participant EC2 as EC2 Instance
    participant SG as Security Group
    participant NACL as Network ACL
    participant RT as Route Table + Gateway Endpoint
    participant S3 as S3 Bucket

    rect rgb(222, 245, 222)
    Note over EC2,S3: BASELINE — SG allows 443 out · NACL allows 443 out + ephemeral in
    EC2->>SG: Outbound :443
    SG->>NACL: egress rule #100 (443) → ALLOW, forwarded
    NACL->>RT: egress rule #100 (443) → ALLOW, forwarded
    RT->>S3: S3 IP matches prefix list → routed via Gateway Endpoint (not the IGW)
    S3-->>RT: response
    RT-->>NACL: response arrives at subnet boundary
    NACL-->>SG: ingress rule #100 (ephemeral 1024-65535) → ALLOW, forwarded
    SG-->>EC2: stateful — response auto-allowed back → SUCCESS (0.017s)
    end

    rect rgb(250, 214, 214)
    Note over EC2,S3: EXPERIMENT A — all Security Group outbound rules revoked
    EC2->>SG: Outbound :443
    SG--xEC2: egress rule check: NO RULES MATCH → dropped at the ENI → TIMEOUT
    end

    rect rgb(250, 214, 214)
    Note over EC2,S3: EXPERIMENT B — NACL allows 443 out, but the inbound ephemeral rule was never added
    EC2->>SG: Outbound :443 (SG fine → forwarded)
    SG->>NACL: egress rule #100 (443) → ALLOW, forwarded
    NACL->>RT: egress rule #100 (443) → ALLOW, forwarded
    RT->>S3: routed via Gateway Endpoint — request DOES reach S3
    S3-->>RT: response sent back
    RT-->>NACL: response arrives at subnet boundary
    NACL--xEC2: ingress rule check: NO EPHEMERAL RULE → response silently DROPPED (stateless) → TIMEOUT
    Note over NACL,EC2: Same missing rule also breaks SSM's own control channel for the ENTIRE subnet — not just S3 traffic
    end

    Note over EC2,S3: Fixing EITHER A or B alone (independently confirmed) restores the exact Baseline path above
```

**What this shows that a topology diagram can't:** the request in Experiment B genuinely **reaches S3 and gets a response** — the failure isn't "can't connect," it's "the response can't get back in." That's the concrete, mechanical reason a stateless NACL misconfiguration produces a timeout that looks identical from the EC2 instance's side to Experiment A's failure, even though the two are broken in opposite directions (A blocks the request from ever leaving; B blocks the response from ever arriving).

**Key point the question is testing:** the Gateway Endpoint only changes
*which route* S3-bound traffic takes (step 4 — via the endpoint instead of
the Internet Gateway). It does **not** bypass the Security Group (step 1)
or the Network ACL (step 2/7) — both are evaluated exactly the same way
regardless of which route the traffic ultimately takes.

## Empirical proof — three states, all tested live

| State | Change from baseline | Result |
|---|---|---|
| **Baseline** | SG allows 443 out; NACL allows 443 out + ephemeral in | ✅ `aws s3 ls` succeeded, curl responded in 0.017s |
| **A — SG broken** | Revoked all SG outbound rules | ❌ **Timeout** (both `aws s3 ls` and curl) |
| A fixed | Restored SG outbound 443 | ✅ Works again (0.017s) |
| **B — NACL broken** | NACL allows outbound 443, but the inbound ephemeral return-path rule was left out | ❌ **Timeout** — and this also silently broke the SSM control channel on the whole subnet, since NACLs apply to *all* traffic in the subnet, not just the traffic being tested |
| B fixed | Added the missing inbound ephemeral rule | ✅ Works again (0.016s) |

**Why "Access Denied" is the wrong mental model here:** an overly-restrictive
S3 bucket policy, endpoint policy, or missing IAM permission would all
produce an explicit `403 Access Denied` — the request *reaches* S3 and gets
a clear rejection. A **timeout** means the request never got a response at
all, which points at the network layers (SG/NACL) sitting between the
instance and the endpoint, not at authorization.

**Extra teaching point from state B:** breaking a subnet's NACL has a
**blast radius of the entire subnet** — every resource and every kind of
traffic in it, not just the one thing you meant to break. A Security Group
misconfiguration, by contrast, is scoped to just the ENIs it's attached to.
This is a sharper practical reason to be more careful with NACLs than SGs,
beyond the stateless/stateful distinction alone.

## Resources created for this scenario (see `08_s3_gateway_endpoint_timeout_scenario.py` for full create/break/fix/delete lifecycle)

| Resource | ID |
|---|---|
| VPC | `vpc-053908c4460150d9f` |
| Subnet | `subnet-095efb30769cd25f7` |
| Main route table | `rtb-009825f76a0d50710` |
| Security group | `sg-07fbe63cde49763e9` |
| Network ACL | `acl-08132fa257e30fa19` |
| S3 Gateway Endpoint | `vpce-0bd665227fffbfead` |
| EC2 instance | `i-042da759ae55e1302` |
| S3 bucket | `aws-trainer-s3-endpoint-demo-1788625046` |
| IAM role | `aws-trainer-s3-endpoint-ec2-role` |

AWS's own VPC console also renders a live visual "Resource map" for any
VPC (VPC console → your VPC → **Resource map** tab → toggle **Show all
details**) — worth viewing directly in the console alongside this diagram.
