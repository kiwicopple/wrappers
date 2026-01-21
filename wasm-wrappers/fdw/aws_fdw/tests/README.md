# AWS FDW Integration Tests

This directory contains integration tests for the AWS WASM FDW.

## Prerequisites

- Docker and Docker Compose
- PostgreSQL with the `wrappers` extension installed
- The `aws_fdw.wasm` component built

## Running Tests

### 1. Start LocalStack

```bash
docker-compose up -d
```

Wait for LocalStack to be ready and initialized with test data.

### 2. Build the WASM Component

```bash
cd ..
cargo component build --release
```

### 3. Run the Tests

Connect to your PostgreSQL instance and run:

```bash
# Run S3 tests
psql -f test_s3.sql

# Run EC2 tests
psql -f test_ec2.sql
```

Or run the test files manually in your PostgreSQL client.

## Test Coverage

### S3 Service Tests

| Test | Description |
|------|-------------|
| Test 1 | List all buckets |
| Test 2 | List objects in a bucket |
| Test 3 | List objects with prefix filter |
| Test 4 | Empty bucket handling |
| Test 5 | Large bucket pagination |
| Test 6 | Import foreign schema |
| Test 7 | Import with LIMIT TO |
| Test 8 | Import with EXCEPT |
| Test 9 | Error cases |
| Test 10 | Query multiple buckets |

### EC2 Service Tests

| Test | Description |
|------|-------------|
| Test 1 | List all instances |
| Test 2 | Query instance details and types |
| Test 3 | Query instance tags (JSONB) |
| Test 4 | Instance state queries |
| Test 5 | Network information queries |
| Test 6 | Import foreign schema for EC2 |
| Test 7 | Cross-service query demonstration |
| Test 8 | Error cases |

## Test Data

The LocalStack initialization script (`init-localstack.sh`) creates:

### S3 Buckets
- `test-bucket`: Contains 4 objects (2 JSON files, 1 text file, 1 nested file)
- `empty-bucket`: Empty bucket for edge case testing
- `large-bucket`: Contains 100 objects for pagination testing

### EC2 Instances
- `web-server`: t2.micro instance with Name=web-server, Environment=production
- `db-server`: t2.large instance with Name=db-server, Environment=production
- `dev-server`: t2.small instance with Name=dev-server, Environment=development

## Cleanup

To stop LocalStack:

```bash
docker-compose down
```

To clean up test objects in PostgreSQL, uncomment the cleanup section at the end of `test_s3.sql`.
