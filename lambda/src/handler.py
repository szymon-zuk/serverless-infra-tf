import os

import boto3
from botocore.config import Config

SCAN_MODE = os.getenv("SCAN_MODE", "current")
CLOUDWATCH_NAMESPACE = os.getenv("CLOUDWATCH_NAMESPACE", "Custom/EBSMetrics")

session = boto3.Session()


def get_region() -> str:
    """Get the current AWS region."""
    current_region = session.region_name
    if current_region is None:
        raise RuntimeError("Current region is not set in the session.")
    return current_region


def collect_for_region(region: str) -> dict:
    ec2 = session.client(
        "ec2",
        region_name=region,
        config=Config(retries={"max_attempts": 10, "mode": "standard"}),
    )
    unattached_count = 0
    unattached_total_size_gb = 0
    unencrypted_volumes_count = 0
    unencrypted_snaps_count = 0

    # Volumes
    vol_p = ec2.get_paginator("describe_volumes")
    for page in vol_p.paginate():
        for v in page.get("Volumes", []):
            state = v.get("State")
            if state != "in-use":
                unattached_count += 1
                unattached_total_size_gb += v.get("Size", 0)

            if not v.get("Encrypted", False):
                unencrypted_volumes_count += 1

    # Snapshots
    snap_p = ec2.get_paginator("describe_snapshots")
    for page in snap_p.paginate(OwnerIds=["self"]):
        for s in page.get("Snapshots", []):
            if not s.get("Encrypted", False):
                unencrypted_snaps_count += 1

    return {
        "region": region,
        "UnattachedVolumesCount": unattached_count,
        "UnattachedVolumesTotalSizeGB": unattached_total_size_gb,
        "UnencryptedVolumesCount": unencrypted_volumes_count,
        "UnencryptedSnapshotsCount": unencrypted_snaps_count,
    }


def publish_metrics_to_cloudwatch(metrics: dict, region: str):
    cw = session.client("cloudwatch", region_name=region)
    total_unattached = metrics.get("UnattachedVolumesCount", 0)
    total_unattached_size = metrics.get("UnattachedVolumesTotalSizeGB", 0)
    total_unenc_vols = metrics.get("UnencryptedVolumesCount", 0)
    total_unenc_snaps = metrics.get("UnencryptedSnapshotsCount", 0)
    metric_data = [
        {"MetricName": "UnattachedVolumes", "Unit": "Count", "Value": total_unattached},
        {
            "MetricName": "UnattachedVolumesTotalSizeGiB",
            "Unit": "Gigabytes",
            "Value": total_unattached_size,
        },
        {
            "MetricName": "UnencryptedVolumes",
            "Unit": "Count",
            "Value": total_unenc_vols,
        },
        {
            "MetricName": "UnencryptedSnapshots",
            "Unit": "Count",
            "Value": total_unenc_snaps,
        },
    ]

    cw.put_metric_data(
        Namespace=CLOUDWATCH_NAMESPACE,
        MetricData=metric_data,
    )


def lambda_handler(event, context):
    if os.getenv("FREE_TIER_LOCK", "false").lower() != "true":
        raise RuntimeError("FREE_TIER_LOCK must be true")
    region = get_region()
    results = collect_for_region(region)
    publish_metrics_to_cloudwatch(results, region)

    return {
        "namespace": CLOUDWATCH_NAMESPACE,
        "scan_mode": SCAN_MODE,
        "metrics_published": results,
    }
