# aws-iam-safe-agent-skill

A reusable skill + Terraform template for giving AI agents AWS access **without**
handing them the keys to your account.

> If your plan is "create an IAM User, attach `AdministratorAccess`, and paste the
> access key into the agent's `.env`", stop. That is how databases get dropped
> overnight. This repo is the fix.

---

## Why this exists

AI agents — Hermes, OpenClaw, LangGraph, CrewAI, your own boto3 loop, doesn't
matter — fail differently than humans. They retry forever. They hallucinate
resources. They run while you sleep. They share their environment variables
with whoever prompt-injects them. A permanent IAM access key bolted to a
permissive user turns each of those failure modes into an unbounded incident.

This skill replaces that pattern with **STS AssumeRole + MFA**:

1. The agent's IAM User has **only** `sts:AssumeRole` on an explicit list of role ARNs.
2. Each role is **purpose-scoped** (one task = one role), **15-minute max session**,
   and **MFA-gated** in its trust policy.
3. When the agent wants to act, it asks for approval, a human taps MFA, and the
   agent gets 15-minute credentials for one role.
4. Blast radius if anything goes wrong: **15 minutes × one role's scope**.

---

## Direct-attach vs. Role Assume

| | IAM User direct-attach | Role Assume + MFA (this skill) |
|---|---|---|
| Token lifetime | Permanent | 15 minutes |
| Permission scope | Always-on, broad | Per-task, narrow |
| Human in the loop | None | MFA on every assume |
| Blast radius on compromise | Account-wide, indefinite | One role, 15 minutes |
| Auditability | Coarse | Per-assume in CloudTrail with reason |
| Secret rotation | Manual | Automatic (expiry) |

---

## Repo layout

```
aws-iam-safe-agent-skill/
├── SKILL.md                    ← The skill. Read this first.
├── README.md                   ← You are here.
├── LICENSE                     ← MIT.
├── .gitignore
├── templates/
│   └── iam_roles.tf            ← Terraform: 1 IAM User + 4 reference roles.
└── references/
    └── assume_snippet.py       ← boto3 STS AssumeRole helper for the agent.
```

`SKILL.md` is the canonical document — design rules, agent system prompt block,
pre-deploy checklist. `templates/` and `references/` are the artifacts you
actually wire into your stack.

---

## Quickstart (Terraform)

Prereqs: Terraform >= 1.5, AWS credentials with IAM admin (for the apply only).

```bash
cd templates/

cat > terraform.tfvars <<'EOF'
agent_name    = "hermes"
env           = "dev"
account_id    = "123456789012"
region        = "ap-northeast-2"
deploy_bucket = "hermes-dev-deploy"
EOF

terraform init
terraform plan       # review every resource. especially the Trust Policies.
terraform apply
```

Outputs:

- `agent_user_arn` — the IAM User. Mint an access key for it out-of-band
  (`aws iam create-access-key`), store the key in your secret manager, give
  **only** the agent process access to it.
- `role_arns` — map of `role_key → role ARN`. Paste this into
  `references/assume_snippet.py`'s `ROLE_ARNS` (or load it from config).

Then go through the **pre-deploy checklist in `SKILL.md`** before pointing the
agent at the account. Every box. No exceptions.

---

## Wiring into the agent

1. Drop `references/assume_snippet.py` into your agent's codebase.
2. Replace `request_approval()` with your real approval channel (Slack
   interactive message, Telegram bot, CLI prompt for local dev, PagerDuty Custom
   Action — whatever fits). It must collect a fresh MFA TOTP from a human.
3. Forbid all other paths to AWS. The agent must not construct boto3 clients
   from raw env vars; every client is built from `assume(...)`'s return value.
4. Paste the "Agent System Prompt block" from `SKILL.md` into the agent's
   system prompt verbatim.

---

## Running on EC2 / ECS / Lambda?

Don't use an IAM User at all. Use the platform's native identity (Instance
Profile / Task Role / Lambda Execution Role / IRSA) as the *base* identity,
and keep only the **per-task purpose-scoped roles** half of this design.
See the closing note in `SKILL.md`.

---

## License

MIT — see [LICENSE](LICENSE).

Author: Kyle Lee &lt;markman0510@gmail.com&gt;
