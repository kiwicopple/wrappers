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

echo "LocalStack initialization complete!"
echo "Buckets:"
awslocal s3 ls
echo ""
echo "Objects in test-bucket:"
awslocal s3 ls s3://test-bucket --recursive
