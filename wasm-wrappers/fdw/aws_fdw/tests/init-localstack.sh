#!/bin/bash
set -e

echo "Initializing LocalStack S3 test data..."

# Create test buckets
awslocal s3 mb s3://test-bucket
awslocal s3 mb s3://empty-bucket
awslocal s3 mb s3://large-bucket

# Add objects to test-bucket
echo '{"id": 1, "name": "test1"}' | awslocal s3 cp - s3://test-bucket/data/file1.json
echo '{"id": 2, "name": "test2"}' | awslocal s3 cp - s3://test-bucket/data/file2.json
echo 'plain text content' | awslocal s3 cp - s3://test-bucket/file.txt
echo 'nested file' | awslocal s3 cp - s3://test-bucket/nested/deep/file.txt

# Add objects to large-bucket for pagination testing
for i in $(seq 1 100); do
  echo "item $i" | awslocal s3 cp - s3://large-bucket/item-$i.txt
done

echo "LocalStack S3 initialization complete!"
echo "Buckets:"
awslocal s3 ls
echo ""
echo "Objects in test-bucket:"
awslocal s3 ls s3://test-bucket --recursive

# ============================================================================
# EC2 Test Data
# ============================================================================

echo ""
echo "Initializing LocalStack EC2 test data..."

# Run EC2 instances with different configurations
# Instance 1: Web server
INSTANCE1=$(awslocal ec2 run-instances \
  --image-id ami-12345678 \
  --instance-type t2.micro \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=web-server},{Key=Environment,Value=production}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "Created instance: $INSTANCE1 (web-server)"

# Instance 2: Database server
INSTANCE2=$(awslocal ec2 run-instances \
  --image-id ami-12345678 \
  --instance-type t2.large \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=db-server},{Key=Environment,Value=production}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "Created instance: $INSTANCE2 (db-server)"

# Instance 3: Development server
INSTANCE3=$(awslocal ec2 run-instances \
  --image-id ami-87654321 \
  --instance-type t2.small \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=dev-server},{Key=Environment,Value=development}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "Created instance: $INSTANCE3 (dev-server)"

echo ""
echo "EC2 Instances:"
awslocal ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name]' --output table

# ============================================================================
# Lambda Test Data
# ============================================================================

echo ""
echo "Initializing LocalStack Lambda test data..."

# Create a simple Lambda function code
mkdir -p /tmp/lambda
cat > /tmp/lambda/handler.py << 'PYEOF'
def handler(event, context):
    return {"statusCode": 200, "body": "Hello from Lambda!"}
PYEOF

cd /tmp/lambda && zip -r function.zip handler.py

# Function 1: Python API handler
awslocal lambda create-function \
  --function-name api-handler \
  --runtime python3.9 \
  --handler handler.handler \
  --zip-file fileb:///tmp/lambda/function.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --memory-size 128 \
  --timeout 30 \
  --description "API request handler"
echo "Created Lambda function: api-handler"

# Function 2: Data processor
awslocal lambda create-function \
  --function-name data-processor \
  --runtime python3.9 \
  --handler handler.handler \
  --zip-file fileb:///tmp/lambda/function.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --memory-size 512 \
  --timeout 300 \
  --description "Processes data from S3"
echo "Created Lambda function: data-processor"

# Function 3: Notification sender
awslocal lambda create-function \
  --function-name notification-sender \
  --runtime python3.9 \
  --handler handler.handler \
  --zip-file fileb:///tmp/lambda/function.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --memory-size 256 \
  --timeout 60 \
  --description "Sends notifications"
echo "Created Lambda function: notification-sender"

echo ""
echo "Lambda Functions:"
awslocal lambda list-functions --query 'Functions[*].[FunctionName,Runtime,MemorySize]' --output table

# Cleanup temp files
rm -rf /tmp/lambda

# ============================================================================
# Route53 Test Data
# ============================================================================

echo ""
echo "Initializing LocalStack Route53 test data..."

# Create hosted zone 1: example.com
ZONE1=$(awslocal route53 create-hosted-zone \
  --name example.com \
  --caller-reference "example-com-$(date +%s)" \
  --hosted-zone-config Comment="Primary domain" \
  --query 'HostedZone.Id' \
  --output text)
ZONE1_ID=$(echo $ZONE1 | sed 's/\/hostedzone\///')
echo "Created hosted zone: $ZONE1_ID (example.com)"

# Create hosted zone 2: internal.local (private zone concept)
ZONE2=$(awslocal route53 create-hosted-zone \
  --name internal.local \
  --caller-reference "internal-local-$(date +%s)" \
  --hosted-zone-config Comment="Internal services" \
  --query 'HostedZone.Id' \
  --output text)
ZONE2_ID=$(echo $ZONE2 | sed 's/\/hostedzone\///')
echo "Created hosted zone: $ZONE2_ID (internal.local)"

# Add DNS records to example.com
awslocal route53 change-resource-record-sets \
  --hosted-zone-id $ZONE1_ID \
  --change-batch '{
    "Changes": [
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "www.example.com",
          "Type": "A",
          "TTL": 300,
          "ResourceRecords": [{"Value": "192.0.2.1"}]
        }
      },
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "api.example.com",
          "Type": "A",
          "TTL": 300,
          "ResourceRecords": [{"Value": "192.0.2.2"}]
        }
      },
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "mail.example.com",
          "Type": "MX",
          "TTL": 3600,
          "ResourceRecords": [{"Value": "10 mail1.example.com"}, {"Value": "20 mail2.example.com"}]
        }
      },
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "example.com",
          "Type": "TXT",
          "TTL": 300,
          "ResourceRecords": [{"Value": "\"v=spf1 include:_spf.example.com ~all\""}]
        }
      }
    ]
  }'
echo "Added DNS records to example.com"

# Add DNS records to internal.local
awslocal route53 change-resource-record-sets \
  --hosted-zone-id $ZONE2_ID \
  --change-batch '{
    "Changes": [
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "db.internal.local",
          "Type": "A",
          "TTL": 60,
          "ResourceRecords": [{"Value": "10.0.0.10"}]
        }
      },
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "cache.internal.local",
          "Type": "A",
          "TTL": 60,
          "ResourceRecords": [{"Value": "10.0.0.20"}]
        }
      }
    ]
  }'
echo "Added DNS records to internal.local"

echo ""
echo "Route53 Hosted Zones:"
awslocal route53 list-hosted-zones --query 'HostedZones[*].[Id,Name]' --output table

echo ""
echo "LocalStack initialization complete!"
