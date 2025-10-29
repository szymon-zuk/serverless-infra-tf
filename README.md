# Serverless EBS Metrics Infrastructure (Terraform + AWS Lambda)

This project provisions a **serverless AWS infrastructure** that automatically collects EBS metrics and publishes them to **CloudWatch** on a schedule.

It's lightweight, free-tier-compliant, and uses:

- **AWS Lambda** (Python)
- **Amazon EventBridge** (for scheduling)
- **Amazon CloudWatch** (for metrics and logs)
- **Terraform** (for provisioning)

---

## What It Does

Every scheduled run (default: once a day), the Lambda function collects:

| Metric                          | Unit  | Description                          |
| ------------------------------- | ----- | ------------------------------------ |
| `UnattachedVolumes`             | Count | Number of unattached EBS volumes     |
| `UnattachedVolumesTotalSizeGiB` | GiB   | Total size of unattached EBS volumes |
| `UnencryptedVolumes`            | Count | Number of unencrypted EBS volumes    |
| `UnencryptedSnapshots`          | Count | Number of unencrypted EBS snapshots  |

These metrics are pushed into the custom CloudWatch namespace  
**`ServerlessInfraTF`**

---

## Prerequisites

- AWS Account with permissions for:
  - Lambda (`lambda:*`)
  - EventBridge (`events:*`)
  - CloudWatch (`logs:*`, `cloudwatch:PutMetricData`)
  - EC2 (`ec2:DescribeVolumes`, `ec2:DescribeSnapshots`, `ec2:DescribeVolumeStatus`)
  - _(Optional for testing)_ `ec2:CreateVolume`, `ec2:CreateSnapshot`, `ec2:DeleteVolume`, `ec2:DeleteSnapshot`
- [Terraform](https://developer.hashicorp.com/terraform/downloads) v1.12+
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [UV](https://docs.astral.sh/uv/getting-started/installation/) - Python package and project manager
- Python 3.11 (for Lambda packaging)

### Installing UV

UV is a fast Python package installer and resolver. Install it with:

```bash
# On macOS and Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# On Windows
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"

# Or via pip
pip install uv
```

---

## Deployment

```bash
# Clone repository
git clone https://github.com/szymon-zuk/serverless-infra-tf.git
cd serverless-infra-tf

# Install Python dependencies (using UV)
uv sync

# Initialize Terraform
terraform init

# Plan deployment (preview)
terraform plan -out=tfplan.bin

# Apply
terraform apply "tfplan.bin"
```

After a few seconds, Terraform will output:

```ini
lambda_name = "serverless-infra-tf-ebs-metrics"
```

---

## Configuration

All configuration is handled via `variables.tf`.

| Variable           | Default               | Description              |
| ------------------ | --------------------- | ------------------------ |
| `region`           | `us-east-1`           | AWS region               |
| `aws_profile`      | `private`             | AWS CLI profile          |
| `cron_expression`  | `cron(0 2 * * ? *)`   | EventBridge schedule     |
| `metric_namespace` | `ServerlessInfraTF`   | CloudWatch namespace     |
| `scan_mode`        | `current`             | Scan only current region |
| `name_prefix`      | `serverless-infra-tf` | Resource naming prefix   |

To override defaults, create a `terraform.tfvars` file:

```hcl
region = "eu-central-1"
name_prefix = "my-ebs-metrics"
cron_expression = "cron(0 6 * * ? *)"  # 6 AM UTC daily
```

---

## Testing

### Manual Invocation

Invoke once to verify everything works:

```bash
aws --profile private --region eu-central-1 lambda invoke \
  --function-name "serverless-infra-tf-ebs-metrics" \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  output.json

cat output.json
```

Expected output:

```json
{
  "statusCode": 200,
  "body": "{\"message\":\"Successfully processed 0 volumes and sent 0 metrics\",\"volumes_processed\":0,\"metrics_sent\":0}"
}
```

### View Logs

```bash
aws --profile private --region eu-central-1 logs tail \
  "/aws/lambda/serverless-infra-tf-ebs-metrics" \
  --since 10m --follow
```

### View Metrics

```bash
aws --profile private --region eu-central-1 cloudwatch list-metrics \
  --namespace "ServerlessInfraTF"
```

---

## Add Test EBS Resources (for visible metrics)

These commands create tiny 1 GiB test volumes and snapshots that appear in metrics.
Make sure your IAM identity allows `ec2:CreateVolume` / `ec2:CreateSnapshot`.

### Create Test Resources

```bash
PROFILE=private
REGION=eu-central-1
AZ=eu-central-1a
TAG_NAME=ebs-metrics-test

# Create a 1 GiB unattached volume (encrypted by default)
VOL_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 create-volume \
  --availability-zone "$AZ" --size 1 --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --query VolumeId --output text)
echo "Created Volume: $VOL_ID"

# Wait until available
aws --profile "$PROFILE" --region "$REGION" ec2 wait volume-available --volume-ids "$VOL_ID"

# Optional: Create snapshot of that volume
SNAP_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 create-snapshot \
  --volume-id "$VOL_ID" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --query SnapshotId --output text)
echo "Created Snapshot: $SNAP_ID"

# Wait for snapshot completion
aws --profile "$PROFILE" --region "$REGION" ec2 wait snapshot-completed --snapshot-ids "$SNAP_ID"

# Invoke Lambda manually
aws --profile "$PROFILE" --region "$REGION" lambda invoke \
  --function-name "serverless-infra-tf-ebs-metrics" \
  --payload '{}' --cli-binary-format raw-in-base64-out \
  >(cat) >/dev/null
```

After a minute or two, check CloudWatch:

- `UnattachedVolumes` → >=1
- `UnattachedVolumesTotalSizeGiB` → >=1
- `UnencryptedVolumes` and `UnencryptedSnapshots` may stay 0 (if encryption-by-default is ON)

### Cleanup Resources

```bash
PROFILE=private
REGION=eu-central-1
TAG_NAME=ebs-metrics-test

# Delete snapshots
SNAPS=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Name,Values=$TAG_NAME" \
  --query "Snapshots[].SnapshotId" --output text)
for S in $SNAPS; do
  echo "Deleting snapshot $S"
  aws --profile "$PROFILE" --region "$REGION" ec2 delete-snapshot --snapshot-id "$S"
done

# Delete volumes
VOLS=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-volumes \
  --filters "Name=tag:Name,Values=$TAG_NAME" \
  --query "Volumes[].VolumeId" --output text)
for V in $VOLS; do
  echo "Deleting volume $V"
  aws --profile "$PROFILE" --region "$REGION" ec2 delete-volume --volume-id "$V"
done
```

---

## CloudWatch Logs Insights Example Query

Use this in CloudWatch Logs Insights for `/aws/lambda/serverless-infra-tf-ebs-metrics`:

```sql
fields @timestamp, @message
| filter @message like /Successfully processed/
| sort @timestamp desc
| limit 20
```

---

## Development

### Code Formatting and Linting

This project uses UV for dependency management and code formatting:

```bash
# Install dependencies
uv sync

# Format code
uv run isort .
uv run black .

# Run linting
uv run ruff check .
```

### Project Structure

```
serverless-infra-tf/
├── lambda/
│   ├── src/
│   │   └── handler.py          # Lambda function code
│   └── layer/
│       └── python/             # Lambda layer dependencies
├── build/                      # Generated ZIP files
├── main.tf                     # Terraform configuration
├── variables.tf                # Input variables
├── outputs.tf                  # Output values
├── terraform.tfvars            # Variable values
├── pyproject.toml             # UV/Python configuration
└── README.md                  # This file
```

---

## Cleanup Infrastructure

When finished testing:

```bash
terraform destroy -auto-approve
```

---

## Notes

- **Default schedule**: once per day at 02:00 UTC (`cron(0 2 * * ? *)`)
- **To test faster**: set `cron_expression = "rate(1 minute)"` and `terraform apply`
- **CloudWatch Logs retention**: 1 day (free-tier friendly)
- **Lambda runtime**: Python 3.11
- **Memory/timeout**: 128 MB / 300 seconds
- **Cost**: ~0.0001 GB-s/day (well within free tier)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.