# AWS FDW Integration Tests

This directory contains integration tests for the AWS WASM FDW.

## Prerequisites

- Docker and Docker Compose
- PostgreSQL with the `wrappers` extension installed
- The `aws_fdw.wasm` component built

## Security: Checksum Requirement

**IMPORTANT**: The `fdw_package_checksum` option is now **REQUIRED** for all WASM FDW servers. This prevents supply chain attacks where a malicious actor could substitute a backdoored WASM package.

Before running tests, calculate the checksum of your built WASM component:

```bash
# Calculate checksum
sha256sum target/wasm32-unknown-unknown/release/aws_fdw.wasm | awk '{print "sha256:" $1}'

# Example output: sha256:abc123def456...

# Replace REPLACE_WITH_ACTUAL_CHECKSUM in test files with the actual value
```

The test files contain placeholder checksums (`sha256:REPLACE_WITH_ACTUAL_CHECKSUM`) that must be updated with the actual checksum before running tests.

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

# Run Lambda tests
psql -f test_lambda.sql

# Run Route53 tests
psql -f test_route53.sql

# Run Security tests
psql -f test_security.sql

# Run Advanced Security tests (attack vector coverage)
psql -f test_security_advanced.sql
```

Or run the test files manually in your PostgreSQL client.

## Security Testing

The AWS FDW includes comprehensive security tests covering AWS-specific concerns.

For platform-wide security tests (supply chain, credential masking), see `/wasm-wrappers/tests/`.

### Basic Security (`test_security.sql`)
- Read-only enforcement (INSERT/UPDATE/DELETE blocked)
- Input validation
- Required filter enforcement

### AWS-Specific Security (`test_security_advanced.sql`)
- **SSRF Protection**: Tests for blocking metadata service, localhost, private IPs via `endpoint_url`
- **AWS Input Validation**: SQL injection, header injection in S3 requests
- **AWS Credential Masking**: Ensures AWS credentials don't leak in error messages
- **Read-Only Enforcement**: Confirms write operations are blocked

See `SECURITY.md` for detailed AWS-specific attack vector analysis.
See `/SECURITY.md` for platform-wide security documentation.

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

### Lambda Service Tests

| Test | Description |
|------|-------------|
| Test 1 | List all functions |
| Test 2 | Query functions by runtime |
| Test 3 | Query function configuration |
| Test 4 | Query function code size |
| Test 5 | Import foreign schema for Lambda |
| Test 6 | Error cases |

### Route53 Service Tests

| Test | Description |
|------|-------------|
| Test 1 | List all hosted zones |
| Test 2 | Query hosted zone details |
| Test 3 | List resource record sets |
| Test 4 | Query DNS records by type |
| Test 5 | Import foreign schema for Route53 |
| Test 6 | Error cases |

### Security Tests

| Test | Severity | Description |
|------|----------|-------------|
| SEC-030 | HIGH | INSERT operations rejected |
| SEC-031 | HIGH | UPDATE operations rejected |
| SEC-032 | HIGH | DELETE operations rejected |
| SEC-008 | MEDIUM | Invalid service option rejected |
| SEC-009 | MEDIUM | Invalid object type rejected |
| SEC-S3-001 | MEDIUM | S3 objects requires bucket filter |
| SEC-R53-001 | MEDIUM | Route53 records requires zone_id filter |
| SEC-IFS-001 | LOW | Invalid schema import rejected |

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

### Lambda Functions
- `api-handler`: Python 3.9, 128MB memory, 30s timeout, API request handler
- `data-processor`: Python 3.9, 512MB memory, 300s timeout, Data processing
- `notification-sender`: Python 3.9, 256MB memory, 60s timeout, Notification service

### Route53 Hosted Zones
- `example.com`: Public zone with A, MX, TXT records
- `internal.local`: Internal zone with A records for db and cache

### Route53 DNS Records
- `www.example.com`: A record pointing to 192.0.2.1
- `api.example.com`: A record pointing to 192.0.2.2
- `mail.example.com`: MX record with two mail servers
- `example.com`: TXT record with SPF configuration
- `db.internal.local`: A record pointing to 10.0.0.10
- `cache.internal.local`: A record pointing to 10.0.0.20

## Cleanup

To stop LocalStack:

```bash
docker-compose down
```

To clean up test objects in PostgreSQL, uncomment the cleanup section at the end of `test_s3.sql`.
