"""Synthetic uptime check (the AWS equivalent of a GCP uptime check).

Every minute: GET <TARGET_URL>/healthz, require HTTP 200 AND the body to contain
MATCH_TEXT, within TIMEOUT_SECONDS. Publishes Up (1/0) and LatencyMs to CloudWatch.
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3

cloudwatch = boto3.client("cloudwatch")
NAMESPACE = os.environ["METRIC_NAMESPACE"]


def handler(event, context):
    url = os.environ["TARGET_URL"].rstrip("/") + "/healthz"
    match = os.environ.get("MATCH_TEXT", '"status": "ok"')
    timeout = float(os.environ.get("TIMEOUT_SECONDS", "5"))
    started = time.monotonic()
    up, reason = 0, "unknown"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - fixed https/http URL from config
            body = resp.read(4096).decode("utf-8", "replace")
            if resp.status != 200:
                reason = f"status {resp.status}"
            elif match not in body:
                reason = "content mismatch"
            else:
                up, reason = 1, "ok"
    except urllib.error.HTTPError as exc:
        reason = f"status {exc.code}"
    except Exception as exc:  # noqa: BLE001
        reason = type(exc).__name__
    latency = (time.monotonic() - started) * 1000
    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {"MetricName": "Up", "Value": up, "Unit": "Count"},
            {"MetricName": "LatencyMs", "Value": latency, "Unit": "Milliseconds"},
        ],
    )
    print(json.dumps({"url": url, "up": up, "reason": reason, "latency_ms": round(latency, 1)}))
    return {"up": up, "reason": reason}
