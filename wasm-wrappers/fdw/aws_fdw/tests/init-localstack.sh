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

echo ""
echo "LocalStack initialization complete!"
