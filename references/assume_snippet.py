"""
Minimal STS AssumeRole helper for AI agents.

Design:
    - The agent's IAM user has only `sts:AssumeRole`. Every actual AWS call must
      go through a 15-minute role session minted here.
    - `assume(role_key, reason)` is the ONLY public entrypoint. It:
        1) Looks up the role ARN for `role_key`.
        2) Calls `request_approval(role_key, reason)` to get a human MFA token.
        3) Calls `sts:AssumeRole` with DurationSeconds=900 and that MFA token.
        4) Returns the temporary credentials.

    - `request_approval()` is intentionally a stub. Replace it for your stack
      (Slack interactive button, Telegram bot, PagerDuty Custom Action,
      command-line prompt, in-person on-call, ...). The contract: it MUST come
      back with both the user's MFA serial and a freshly-typed TOTP code, or
      raise to abort the call. Do not make it auto-approve. Do not cache.

    - Returned creds are short-lived (15 min) by design. Use them and let them
      expire. Never write them to disk, logs, or model context.

Wire-up:
    Set ROLE_ARNS to the `role_arns` Terraform output from templates/iam_roles.tf.

Usage:
    from assume_snippet import assume
    creds = assume("ec2-read", reason="List i-* in ap-northeast-2 for daily inventory")
    ec2 = boto3.client(
        "ec2",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Role catalog. Paste the `role_arns` output of templates/iam_roles.tf here,
# or load it from your config/secret store at startup.
# Keys must match the role keys defined in the Terraform `locals.roles` map.
# ---------------------------------------------------------------------------
ROLE_ARNS: dict[str, str] = {
    # "ec2-read":         "arn:aws:iam::123456789012:role/hermes-prod-ec2-read",
    # "s3-deploy":        "arn:aws:iam::123456789012:role/hermes-prod-s3-deploy",
    # "rds-query":        "arn:aws:iam::123456789012:role/hermes-prod-rds-query",
    # "cloudwatch-read":  "arn:aws:iam::123456789012:role/hermes-prod-cloudwatch-read",
}

SESSION_DURATION_SECONDS = 900  # 15 minutes — must not exceed role's max_session_duration.


# ---------------------------------------------------------------------------
# Approval gate — REPLACE THIS for your environment.
#
# Required contract:
#   - Show `role_key` and `reason` to a human.
#   - Block until the human either:
#       (a) supplies their MFA device ARN + a fresh TOTP token, OR
#       (b) denies (raise PermissionError / your domain exception).
#   - Never auto-approve. Never store the TOTP. Never let the agent supply it.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Approval:
    mfa_serial: str  # arn:aws:iam::<acct>:mfa/<user>  (or hardware serial)
    token_code: str  # 6-digit TOTP, valid for ~30s


def request_approval(role_key: str, reason: str) -> Approval:
    """Stub: get a human MFA approval out-of-band.

    Replace with your real channel. Examples:
        - Slack: post an interactive message, wait for button + modal with TOTP.
        - CLI:   `input("MFA serial: ")` / `getpass("Token: ")` for local dev.
        - PagerDuty Custom Action with manual ack.
    """
    raise NotImplementedError(
        "Replace request_approval() for your approval channel. "
        f"Requested: role={role_key!r} reason={reason!r}"
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def assume(role_key: str, reason: str) -> dict:
    """Mint 15-minute credentials for `role_key` after human MFA approval.

    Args:
        role_key: Logical role name from ROLE_ARNS. Must exist in the catalog.
        reason:   One concrete sentence (resource + action + why). Vague reasons
                  ("do work") MUST be rejected upstream — keep this strict.

    Returns:
        Dict with AccessKeyId, SecretAccessKey, SessionToken, Expiration. Use
        and discard. Do not persist.
    """
    if role_key not in ROLE_ARNS:
        raise KeyError(
            f"Unknown role_key {role_key!r}. Allowed: {sorted(ROLE_ARNS)}. "
            "If you need a new role, add it to templates/iam_roles.tf and "
            "re-apply — do NOT widen an existing role to fit."
        )
    if not reason or len(reason.strip()) < 12:
        # Cheap guard against agents passing "do task" / "run". Your real
        # approval UI should also enforce this server-side.
        raise ValueError("`reason` must be a concrete sentence (>=12 chars).")

    approval = request_approval(role_key, reason)

    sts = boto3.client("sts")
    session_name = f"{role_key}-{os.getpid()}"[:64]

    try:
        resp = sts.assume_role(
            RoleArn=ROLE_ARNS[role_key],
            RoleSessionName=session_name,
            DurationSeconds=SESSION_DURATION_SECONDS,
            SerialNumber=approval.mfa_serial,
            TokenCode=approval.token_code,
        )
    except ClientError as e:
        # Common failures here:
        #   AccessDenied          — IAM user missing sts:AssumeRole on this ARN
        #   MultiFactorAuthFailed — wrong/expired TOTP
        #   ValidationError       — DurationSeconds > role's max_session_duration
        # Do NOT auto-retry. Surface to the human.
        raise RuntimeError(
            f"AssumeRole({role_key}) failed: {e.response['Error']['Code']}"
        ) from e

    return resp["Credentials"]


# ---------------------------------------------------------------------------
# Example usage. Delete or move to your own entrypoint.
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    creds = assume(
        "ec2-read",
        reason="List running EC2 instances in ap-northeast-2 for the 09:00 inventory report.",
    )
    print("Got temporary creds, expiring at:", creds["Expiration"])

    ec2 = boto3.client(
        "ec2",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )
    instances = ec2.describe_instances()
    print("Reservations:", len(instances.get("Reservations", [])))
