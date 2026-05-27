---
name: aws-iam-safe-agent
description: Use this whenever an AI agent (Hermes, OpenClaw, LangGraph, CrewAI, Autogen, custom boto3 loops, etc.) needs AWS credentials, or when designing IAM for any autonomous/semi-autonomous workload. Stop and apply this BEFORE you attach an IAM policy to a user, paste an access key into an agent's env, or write `aws_access_key_id=...` for a bot. If your plan involves "give the agent admin and we'll see what happens", you must read this first. Skipping this is how databases get dropped overnight.
author: Kyle Lee <markman0510@gmail.com>
version: 1.0.0
---

# AWS IAM Safe Agent

## TL;DR

Do **not** attach permissions directly to an IAM User that an AI agent will use.
A long-lived access key is an open window: an agent that runs all night with
`AmazonRDSFullAccess` can drop production at 3am before anyone notices.

Instead:

1. The agent's IAM User holds **only** `sts:AssumeRole` against a known set of role ARNs.
2. Every actual permission lives on a **purpose-scoped Role** (one role = one task type).
3. Each Role has `max_session_duration = 900` (15 minutes).
4. Each Role's Trust Policy requires `aws:MultiFactorAuthPresent = true`, forcing a
   human to participate in every assume.
5. When an agent wants to do something, it calls `sts:AssumeRole` with a justification,
   a human MFA-approves, and the agent gets 15-minute credentials limited to that one job.

Blast radius if the agent goes rogue: **15 minutes × one role's scope**, not "your entire AWS account, forever".

---

## Why this matters

AI agents fail in ways human operators do not:

- They retry. A lot. A loop bug + `s3:DeleteObject` = empty bucket.
- They invent. A model that hallucinates a flag may also hallucinate a resource ARN
  it "needs to clean up".
- They run while you sleep. A bad plan executes for 8 hours before you see it.
- They share credentials with their context window. A prompt-injected agent walks
  the key out the front door.

A permanent access key bolted to a permissive IAM User turns each of those failures
into an unbounded incident. STS short-lived credentials + human-in-the-loop assume
turns them into a bounded one.

---

## IAM User direct-attach vs. Role Assume

| Dimension | IAM User direct-attach (the bad way) | Role Assume + MFA (this skill) |
|---|---|---|
| Token lifetime | Permanent until manually rotated | 15 min, then expires hard |
| Permission scope | Whatever you attached, all the time | Only the assumed role's policy, for one session |
| Human in the loop | None — agent just acts | MFA prompt on every assume |
| Blast radius on compromise | Entire account, indefinite | One role's scope, 15 minutes |
| Auditability | "User X did 4,812 things" | "Agent assumed `s3-deploy` at 14:02 with reason X" in CloudTrail |
| Secret rotation | Manual, easy to forget | Automatic (creds expire on their own) |
| If the prompt is injected | Attacker has your key | Attacker gets denied at the MFA step |

---

## Architecture

```
                   ┌────────────────────────────┐
                   │   AI Agent (Hermes, etc.)  │
                   │   - long-lived IAM User    │
                   │   - permissions: NOTHING   │
                   │     except sts:AssumeRole  │
                   └──────────────┬─────────────┘
                                  │
                       sts:AssumeRole(role_arn, reason)
                                  │
                                  ▼
                   ┌────────────────────────────┐
                   │   Approval Gate (human)    │
                   │   - sees: role, reason     │
                   │   - taps MFA               │
                   └──────────────┬─────────────┘
                                  │
                MFA token + AssumeRole succeeds
                                  │
                                  ▼
        ┌─────────────────────────────────────────────────┐
        │  Purpose-scoped Roles (max_session_duration=900) │
        │                                                 │
        │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────┐ │
        │  │ec2-read  │ │s3-deploy │ │rds-query │ │ ... │ │
        │  └──────────┘ └──────────┘ └──────────┘ └─────┘ │
        │   read-only    write only   read only           │
        │   one service  one bucket   one DB              │
        └─────────────────────────────────────────────────┘
                                  │
                                  ▼
                   ┌────────────────────────────┐
                   │     CloudTrail (audit)     │
                   │  every AssumeRole logged   │
                   └────────────────────────────┘
```

Agent has no standing power. Every action is a fresh, narrow, audited 15-minute lease.

---

## Design rules

### IAM User (the agent's identity)

- Exactly **one** policy: `sts:AssumeRole` on an explicit list of role ARNs. No wildcards.
- Never attach `AmazonS3FullAccess`, `AdministratorAccess`, or *anything* else here.
- Never give this user console access.
- Rotate the access key on a schedule even though it can do almost nothing — defense in depth.

### Roles (the actual permissions)

- **One role per task type.** `ec2-read` is not allowed to write S3. `s3-deploy` is not
  allowed to read RDS. If you find yourself reaching for `ec2:*`, stop and split.
- Required separation axes:
  - **Read vs. Write vs. Delete** — never combine. Delete should be its own role if it
    exists at all, and prefer not to grant it.
  - **Per service** — `s3-*`, `rds-*`, `ec2-*` are separate.
  - **Per environment** — `*-dev`, `*-staging`, `*-prod` are separate roles with
    separate trust policies. Production assume should be louder than dev assume.
  - **Per data domain** — the role that touches `bucket-customer-pii` is not the same
    role that touches `bucket-public-assets`.
- `max_session_duration = 900`. Not 3600. Not 43200. Fifteen minutes.
- Trust Policy must include:
  ```
  "Condition": { "Bool": { "aws:MultiFactorAuthPresent": "true" } }
  ```
  This is the hinge of the whole design — without it, the agent can self-serve and
  the rest of the architecture is theater.
- Permission policy is the **minimum** action list for the task. Start with deny-all,
  add one action at a time, watch CloudTrail for `AccessDenied`, add only what is
  actually needed.

### Recommended split unit

For most agents, four roles cover real-world needs and force good hygiene:

| Role | What it can do | What it must not do |
|---|---|---|
| `ec2-read` | `ec2:Describe*`, `ec2:Get*` | Any `Create`, `Modify`, `Delete`, `Run`, `Terminate`, `Stop`, `Start` |
| `s3-deploy` | `s3:PutObject`, `s3:GetObject` on **one** bucket prefix | `s3:DeleteObject`, anything on other buckets |
| `rds-query` | `rds:Describe*`, `rds-data:ExecuteStatement` (SELECT only via Data API) | DDL, any `Modify`, `Delete`, `Reboot`, `FailoverDB`, `Restore` |
| `cloudwatch-read` | `cloudwatch:Get*`, `logs:Filter*`, `logs:Get*` | `Put`, `Delete`, anything that mutates dashboards or alarms |

Add or split further. Never collapse.

---

## Agent System Prompt block

Paste this verbatim into the system prompt of any agent that touches AWS:

```
=== AWS ACCESS POLICY (non-negotiable) ===

You have an IAM User whose only permission is sts:AssumeRole on a known list of
Role ARNs. You CANNOT call AWS APIs with your own user credentials. Any direct
boto3 call you make using the user identity WILL be denied — this is by design.

To do AWS work:
1. Identify the smallest role that can do the task (e.g. ec2-read, s3-deploy).
   If no listed role fits, you MUST stop and report this to a human. Do NOT try
   to use a broader role "because it includes the permission".
2. Call assume(role_key, reason) where `reason` is a single concrete sentence
   explaining the specific operation you intend to perform (resource ARN, action,
   why). Vague reasons ("run task", "do work") will be rejected.
3. A human will be prompted for MFA. Wait. Do not retry on denial.
4. If approved, you receive 15-minute credentials. Do the one task, then let the
   credentials expire. Never cache them, never write them to disk, never include
   them in logs or model context.
5. For a different task, call assume() again with a new reason. Each task gets
   its own assume.

Prohibited:
- Trying to attach policies, create roles, or modify IAM in any way.
- Calling sts:GetSessionToken, sts:AssumeRoleWithWebIdentity, or any STS variant
  that bypasses the configured role list.
- Storing credentials beyond the lifetime of the single task they were minted for.
- Asking the human to "increase the session duration" or "remove MFA for this
  task". These requests are themselves a signal of misuse.

=== END AWS ACCESS POLICY ===
```

---

## Pre-deploy checklist

Before pointing a real agent at a real AWS account, every box must be checked.

- [ ] The agent's IAM User has **exactly one** inline or attached policy, and that
      policy's only action is `sts:AssumeRole`.
- [ ] That policy's `Resource` is an **explicit list of role ARNs**. No `*`. No
      `arn:aws:iam::*:role/*`. No `arn:aws:iam::123456789012:role/*`.
- [ ] Every assumable Role has `max_session_duration = 900`.
- [ ] Every assumable Role's Trust Policy contains
      `"Bool": { "aws:MultiFactorAuthPresent": "true" }`.
- [ ] No Role uses `AdministratorAccess`, `PowerUserAccess`, or any `*FullAccess`
      managed policy. Permission policies are hand-written, action-by-action.
- [ ] CloudTrail is enabled in the account **and** you have verified that
      `sts:AssumeRole` events show up in the trail (issue one test assume, find it
      in the event history, confirm `userIdentity`, `requestParameters.roleArn`,
      and `sourceIPAddress` are recorded). If CloudTrail is off, you have no audit.
- [ ] You have set up an alert on `sts:AssumeRole` failures and on assumes that
      happen outside expected hours (e.g. CloudWatch Alarm or a SIEM rule).
- [ ] You have run an end-to-end dry-run: agent attempts task → MFA prompt fires →
      approve → 15-min creds work → after 15 min, same creds return
      `ExpiredToken`. All four steps must visibly happen.
- [ ] The agent system prompt contains the policy block above, verbatim.
- [ ] The agent's environment has **no** other AWS credentials configured. No
      stale `~/.aws/credentials` profile, no `AWS_ACCESS_KEY_ID` env var pointing
      at something more permissive.
- [ ] The agent's code does not write credentials to logs, traces, or the model's
      context window. Search the repo for `aws_access_key`, `aws_session_token`,
      and `print(creds`. Then search again.

If any box is unchecked, do not deploy. There is no "we'll fix it after launch".

---

## What's in this skill bundle

- `templates/iam_roles.tf` — Terraform that provisions the IAM User + the four
  reference roles (`ec2-read`, `s3-deploy`, `rds-query`, `cloudwatch-read`) with
  the safety properties above already wired up. Fill in five variables and
  `terraform apply`. Do **not** paste this into the SKILL.md body of your
  derived skills — keep it as a file you can `terraform plan` against.
- `references/assume_snippet.py` — Minimal `boto3` STS assume-role helper.
  Exposes `assume(role_key, reason)` which routes through a `request_approval()`
  function (which you must replace to match your approval channel — Slack bot,
  Telegram, PagerDuty, in-person, etc.) and returns 15-minute credentials. Drop
  this into your agent and forbid any other path to AWS.

---

## Note: when the agent runs on AWS itself

If your agent runs on **EC2 / ECS / EKS / Lambda / App Runner**, do not create an
IAM User at all. Use the platform's native identity:

- **EC2** → Instance Profile attached to the instance role.
- **ECS / Fargate** → Task Role on the task definition.
- **EKS** → IRSA (IAM Roles for Service Accounts) bound to the pod's ServiceAccount.
- **Lambda** → Execution Role on the function.

Then the agent's "base" identity is already a role with no standing keys, and you
only need the **per-task purpose-scoped roles** half of this design (with `sts:AssumeRole`
allowed *from the platform role*, MFA replaced by a `sts:ExternalId` condition or
a source-VPC condition where MFA isn't available). Everything else — 15-minute
sessions, one-role-per-task, narrow policies, CloudTrail audit — still applies
exactly as above.

Short version: if you can avoid having an IAM User in this picture at all, do.
