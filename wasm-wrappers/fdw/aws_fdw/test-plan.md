# AWS WASM Wrapper Test Plan

## Overview

This document defines a rigorous testing strategy for the AWS WASM FDW, covering unit tests, integration tests, security tests, performance tests, and edge case handling.

## Test Infrastructure

### LocalStack Setup

All integration tests run against [LocalStack](https://localstack.cloud/) to simulate AWS services without incurring costs or requiring real AWS credentials.

```yaml
# docker-compose.test.yml
version: '3.8'
services:
  localstack:
    image: localstack/localstack:3.0
    ports:
      - "4566:4566"
    environment:
      - SERVICES=s3,lambda,cloudwatch
      - DEBUG=1
      - AWS_DEFAULT_REGION=us-east-1
    volumes:
      - "./localstack-init:/etc/localstack/init/ready.d"
      - "/var/run/docker.sock:/var/run/docker.sock"

  postgres:
    image: postgres:15
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_PASSWORD=postgres
    volumes:
      - "./sql:/docker-entrypoint-initdb.d"
```

### Test Data Setup

```bash
# localstack-init/setup.sh
#!/bin/bash

# S3 test data
awslocal s3 mb s3://test-bucket
awslocal s3 mb s3://empty-bucket
awslocal s3 mb s3://large-bucket
echo '{"test": "data"}' | awslocal s3 cp - s3://test-bucket/data/file1.json
echo 'plain text' | awslocal s3 cp - s3://test-bucket/data/file2.txt
for i in $(seq 1 1500); do
  echo "item $i" | awslocal s3 cp - s3://large-bucket/item-$i.txt
done

# Lambda test functions
awslocal lambda create-function \
  --function-name test-function \
  --runtime python3.9 \
  --handler index.handler \
  --zip-file fileb://test-function.zip \
  --role arn:aws:iam::000000000000:role/test-role

# CloudWatch test metrics
awslocal cloudwatch put-metric-data \
  --namespace TestNamespace \
  --metric-name TestMetric \
  --value 100 \
  --unit Count
```

---

## 1. Unit Tests

### 1.1 AWS Signature V4 Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| AUTH-001 | `test_canonical_request_basic` | Verify canonical request format for simple GET | Matches AWS test suite output |
| AUTH-002 | `test_canonical_request_with_query` | Verify canonical request with query parameters | Query params sorted alphabetically |
| AUTH-003 | `test_string_to_sign` | Verify string to sign generation | Matches AWS test suite |
| AUTH-004 | `test_signature_calculation` | Verify HMAC-SHA256 signature | Matches known test vectors |
| AUTH-005 | `test_authorization_header` | Verify full auth header format | Valid AWS4-HMAC-SHA256 header |
| AUTH-006 | `test_session_token_handling` | Verify X-Amz-Security-Token header | Token included when present |
| AUTH-007 | `test_empty_body_hash` | Verify hash of empty body | SHA256 of empty string |
| AUTH-008 | `test_special_chars_in_path` | Verify URL encoding in path | Proper RFC 3986 encoding |
| AUTH-009 | `test_date_handling` | Verify ISO 8601 date format | YYYYMMDD'T'HHMMSS'Z' format |
| AUTH-010 | `test_region_in_scope` | Verify credential scope | Region correctly included |

```rust
#[cfg(test)]
mod auth_tests {
    use super::*;

    #[test]
    fn test_canonical_request_basic() {
        let canonical = build_canonical_request(
            "GET",
            "/",
            "",
            &[("host", "s3.us-east-1.amazonaws.com")],
            &EMPTY_SHA256,
        );
        assert!(canonical.starts_with("GET\n/\n\n"));
    }

    #[test]
    fn test_signature_with_aws_test_vectors() {
        // Use official AWS Signature V4 test suite
        // https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
        let credentials = AwsCredentials {
            access_key_id: "AKIDEXAMPLE".into(),
            secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".into(),
            session_token: None,
        };
        // ... verify against test vectors
    }
}
```

### 1.2 Response Parsing Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| PARSE-001 | `test_parse_list_buckets_xml` | Parse S3 ListBuckets response | Correct bucket list |
| PARSE-002 | `test_parse_list_objects_xml` | Parse S3 ListObjectsV2 response | Correct object list |
| PARSE-003 | `test_parse_lambda_list_json` | Parse Lambda ListFunctions response | Correct function list |
| PARSE-004 | `test_parse_cloudwatch_json` | Parse CloudWatch GetMetricData | Correct metric values |
| PARSE-005 | `test_parse_empty_response` | Handle empty list responses | Empty result set |
| PARSE-006 | `test_parse_truncated_response` | Handle truncated/paginated response | NextToken extracted |
| PARSE-007 | `test_parse_malformed_xml` | Handle malformed XML gracefully | Clear error message |
| PARSE-008 | `test_parse_malformed_json` | Handle malformed JSON gracefully | Clear error message |
| PARSE-009 | `test_parse_timestamp_formats` | Handle various timestamp formats | Correct conversion |
| PARSE-010 | `test_parse_unicode_content` | Handle Unicode in responses | Correct UTF-8 handling |

### 1.3 Type Conversion Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| TYPE-001 | `test_aws_timestamp_to_pg` | Convert AWS DateTime to Postgres | Correct timestamptz |
| TYPE-002 | `test_s3_size_to_bigint` | Convert S3 size to bigint | No overflow |
| TYPE-003 | `test_json_to_jsonb` | Convert JSON objects to JSONB | Valid JSONB |
| TYPE-004 | `test_null_handling` | Handle null/missing fields | SQL NULL |
| TYPE-005 | `test_boolean_conversion` | Convert AWS booleans | Correct boolean |
| TYPE-006 | `test_numeric_boundaries` | Test int/float boundaries | No precision loss |

---

## 2. Integration Tests

### 2.1 S3 Service Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| S3-INT-001 | `test_list_buckets` | List all buckets | Returns all buckets |
| S3-INT-002 | `test_list_buckets_empty` | List buckets when none exist | Empty result |
| S3-INT-003 | `test_list_objects` | List objects in bucket | Returns all objects |
| S3-INT-004 | `test_list_objects_with_prefix` | List objects with prefix filter | Filtered results |
| S3-INT-005 | `test_list_objects_empty_bucket` | List objects in empty bucket | Empty result |
| S3-INT-006 | `test_list_objects_pagination` | List >1000 objects | All objects via pagination |
| S3-INT-007 | `test_head_object` | Get object metadata | Correct metadata |
| S3-INT-008 | `test_nonexistent_bucket` | Access non-existent bucket | Clear error message |
| S3-INT-009 | `test_nonexistent_object` | HEAD non-existent object | Clear error message |
| S3-INT-010 | `test_special_chars_in_key` | Objects with special chars | Correct encoding |

```sql
-- S3-INT-001: test_list_buckets
create foreign table test_s3_buckets (
  name text,
  creation_date timestamp
)
server aws_test_server
options (service 's3', object 'buckets');

select count(*) from test_s3_buckets;
-- Expected: 3 (test-bucket, empty-bucket, large-bucket)

-- S3-INT-006: test_list_objects_pagination
create foreign table test_large_bucket_objects (
  key text,
  size bigint
)
server aws_test_server
options (service 's3', object 'objects', bucket 'large-bucket');

select count(*) from test_large_bucket_objects;
-- Expected: 1500
```

### 2.2 Lambda Service Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| LAM-INT-001 | `test_list_functions` | List all Lambda functions | Returns all functions |
| LAM-INT-002 | `test_list_functions_empty` | List when no functions | Empty result |
| LAM-INT-003 | `test_get_function` | Get specific function details | Correct details |
| LAM-INT-004 | `test_get_nonexistent_function` | Get non-existent function | Clear error |
| LAM-INT-005 | `test_list_functions_pagination` | List >50 functions | All via pagination |
| LAM-INT-006 | `test_function_with_layers` | Function with Lambda layers | Layer info included |

### 2.3 CloudWatch Service Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| CW-INT-001 | `test_list_metrics` | List all metrics | Returns metrics |
| CW-INT-002 | `test_list_metrics_by_namespace` | Filter by namespace | Filtered results |
| CW-INT-003 | `test_get_metric_data` | Get metric data points | Correct values |
| CW-INT-004 | `test_get_metric_empty_range` | Query empty time range | Empty result |
| CW-INT-005 | `test_metric_statistics` | Get Average/Sum/etc | Correct statistics |
| CW-INT-006 | `test_metric_dimensions` | Query with dimensions | Filtered by dimensions |

### 2.4 Error Handling Tests

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| ERR-INT-001 | `test_invalid_credentials` | Use invalid AWS keys | Auth error message |
| ERR-INT-002 | `test_expired_credentials` | Use expired session token | Auth error message |
| ERR-INT-003 | `test_invalid_region` | Use invalid region | Connection error |
| ERR-INT-004 | `test_network_timeout` | Simulate network timeout | Timeout error |
| ERR-INT-005 | `test_service_unavailable` | Simulate 503 response | Retry or clear error |
| ERR-INT-006 | `test_throttling` | Simulate 429 response | Throttle error message |
| ERR-INT-007 | `test_access_denied` | Insufficient IAM permissions | Permission error |
| ERR-INT-008 | `test_invalid_service_option` | Unknown service name | Validation error |
| ERR-INT-009 | `test_missing_required_option` | Missing bucket for objects | Validation error |
| ERR-INT-010 | `test_malformed_endpoint_url` | Invalid endpoint_url | Validation error |

---

## 3. Security Tests

### 3.1 Credential Security Tests

| Test ID | Test Name | Severity | Description | Expected Result |
|---------|-----------|----------|-------------|-----------------|
| SEC-001 | `test_credentials_not_in_logs` | CRITICAL | Verify credentials never appear in logs | No creds in any output |
| SEC-002 | `test_credentials_not_in_errors` | CRITICAL | Verify credentials not in error messages | Sanitized error messages |
| SEC-003 | `test_credentials_not_in_explain` | HIGH | Verify EXPLAIN doesn't expose creds | Options hidden |
| SEC-004 | `test_vault_secret_retrieval` | HIGH | Verify Vault integration works | Secrets retrieved securely |
| SEC-005 | `test_credentials_memory_clearing` | MEDIUM | Verify credentials cleared after use | No creds in memory dump |
| SEC-006 | `test_no_credential_caching` | MEDIUM | Verify no persistent cred storage | No file/memory cache |

```rust
#[test]
fn test_credentials_not_in_errors() {
    let secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    let access_key = "AKIAIOSFODNN7EXAMPLE";

    // Trigger various errors
    let errors = vec![
        trigger_auth_error(access_key, secret_key),
        trigger_network_error(access_key, secret_key),
        trigger_parse_error(access_key, secret_key),
    ];

    for error in errors {
        let error_str = format!("{:?}", error);
        assert!(!error_str.contains(secret_key), "Secret key leaked in error");
        assert!(!error_str.contains(access_key), "Access key leaked in error");
    }
}
```

### 3.2 Input Validation Security Tests

| Test ID | Test Name | Severity | Description | Expected Result |
|---------|-----------|----------|-------------|-----------------|
| SEC-010 | `test_sql_injection_bucket_name` | CRITICAL | SQL injection via bucket name | Input sanitized |
| SEC-011 | `test_sql_injection_prefix` | CRITICAL | SQL injection via prefix option | Input sanitized |
| SEC-012 | `test_path_traversal_bucket` | HIGH | Path traversal in bucket name | Rejected |
| SEC-013 | `test_path_traversal_key` | HIGH | Path traversal in object key | Rejected |
| SEC-014 | `test_ssrf_endpoint_url` | CRITICAL | SSRF via endpoint_url | Internal IPs blocked |
| SEC-015 | `test_header_injection` | HIGH | Header injection in options | Headers sanitized |
| SEC-016 | `test_xml_external_entity` | HIGH | XXE in response parsing | XXE disabled |
| SEC-017 | `test_xml_bomb` | HIGH | XML bomb (billion laughs) | Size limits enforced |
| SEC-018 | `test_oversized_response` | MEDIUM | Handle extremely large responses | Memory limits |
| SEC-019 | `test_unicode_normalization` | LOW | Unicode normalization attacks | Consistent handling |

```sql
-- SEC-010: SQL injection attempt
create foreign table injection_test (key text)
server aws_test_server
options (
  service 's3',
  object 'objects',
  bucket 'test''; DROP TABLE users; --'
);
-- Expected: Validation error, not SQL execution

-- SEC-014: SSRF attempt
create server ssrf_test_server
  foreign data wrapper aws_wrapper
  options (
    fdw_package_url '...',
    aws_access_key_id 'test',
    aws_secret_access_key 'test',
    region 'us-east-1',
    endpoint_url 'http://169.254.169.254/latest/meta-data/'
  );
-- Expected: Blocked - internal IP not allowed
```

### 3.3 Authentication Security Tests

| Test ID | Test Name | Severity | Description | Expected Result |
|---------|-----------|----------|-------------|-----------------|
| SEC-020 | `test_signature_timing_attack` | MEDIUM | Timing-safe signature comparison | Constant-time comparison |
| SEC-021 | `test_replay_attack` | MEDIUM | Reuse of signed request | Rejected (timestamp) |
| SEC-022 | `test_signature_scope_mismatch` | HIGH | Wrong region/service in scope | Rejected |
| SEC-023 | `test_credential_rotation` | MEDIUM | Handle rotated credentials | Graceful re-auth |
| SEC-024 | `test_sts_assume_role` | MEDIUM | Support for assumed roles | Session tokens work |

### 3.4 Read-Only Enforcement Tests

| Test ID | Test Name | Severity | Description | Expected Result |
|---------|-----------|----------|-------------|-----------------|
| SEC-030 | `test_no_insert_support` | HIGH | INSERT operations rejected | Not implemented error |
| SEC-031 | `test_no_update_support` | HIGH | UPDATE operations rejected | Not implemented error |
| SEC-032 | `test_no_delete_support` | HIGH | DELETE operations rejected | Not implemented error |
| SEC-033 | `test_no_post_requests` | HIGH | Verify no POST HTTP calls | Only GET/HEAD |
| SEC-034 | `test_no_put_requests` | HIGH | Verify no PUT HTTP calls | Only GET/HEAD |
| SEC-035 | `test_no_delete_requests` | HIGH | Verify no DELETE HTTP calls | Only GET/HEAD |

```sql
-- SEC-030: Attempt INSERT
insert into aws_s3_objects (key, size) values ('test', 100);
-- Expected: ERROR: operation not supported

-- SEC-031: Attempt UPDATE
update aws_s3_objects set size = 200 where key = 'test';
-- Expected: ERROR: operation not supported

-- SEC-032: Attempt DELETE
delete from aws_s3_objects where key = 'test';
-- Expected: ERROR: operation not supported
```

### 3.5 Network Security Tests

| Test ID | Test Name | Severity | Description | Expected Result |
|---------|-----------|----------|-------------|-----------------|
| SEC-040 | `test_tls_required` | CRITICAL | HTTPS enforced for AWS calls | HTTP rejected |
| SEC-041 | `test_tls_version` | HIGH | TLS 1.2+ required | Old TLS rejected |
| SEC-042 | `test_certificate_validation` | CRITICAL | Verify server certificates | Invalid certs rejected |
| SEC-043 | `test_no_localhost_endpoints` | HIGH | Block localhost endpoints | Localhost rejected |
| SEC-044 | `test_no_private_ip_endpoints` | HIGH | Block private IP ranges | 10.x, 192.168.x blocked |
| SEC-045 | `test_dns_rebinding` | MEDIUM | DNS rebinding protection | Pinned DNS resolution |

---

## 4. Performance Tests

### 4.1 Latency Tests

| Test ID | Test Name | Target | Description |
|---------|-----------|--------|-------------|
| PERF-001 | `test_list_buckets_latency` | <100ms | Time to list buckets |
| PERF-002 | `test_list_objects_small_latency` | <200ms | List <100 objects |
| PERF-003 | `test_list_objects_large_latency` | <2s | List 1000 objects |
| PERF-004 | `test_pagination_overhead` | <50ms/page | Per-page latency |
| PERF-005 | `test_signature_calculation` | <5ms | Time to sign request |

### 4.2 Throughput Tests

| Test ID | Test Name | Target | Description |
|---------|-----------|--------|-------------|
| PERF-010 | `test_concurrent_queries` | 10 QPS | Multiple simultaneous queries |
| PERF-011 | `test_large_result_set` | 10K rows/s | Large object listing |
| PERF-012 | `test_sustained_load` | 5 min stable | Continuous query load |

### 4.3 Memory Tests

| Test ID | Test Name | Target | Description |
|---------|-----------|--------|-------------|
| PERF-020 | `test_memory_baseline` | <50MB | Idle memory usage |
| PERF-021 | `test_memory_large_query` | <200MB | Large result handling |
| PERF-022 | `test_memory_leak_check` | No growth | Memory after 1000 queries |
| PERF-023 | `test_pagination_memory` | Constant | Memory during pagination |

---

## 5. Edge Case Tests

### 5.1 Boundary Conditions

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| EDGE-001 | `test_empty_bucket_name` | Empty string bucket | Validation error |
| EDGE-002 | `test_max_bucket_name` | 63-char bucket name | Accepted |
| EDGE-003 | `test_max_key_length` | 1024-char object key | Accepted |
| EDGE-004 | `test_zero_size_object` | Object with size 0 | Returns correctly |
| EDGE-005 | `test_max_size_object` | 5TB object metadata | No overflow |
| EDGE-006 | `test_unicode_bucket_name` | Unicode in bucket name | Properly encoded |
| EDGE-007 | `test_special_prefix` | Prefix with /../ | Sanitized |
| EDGE-008 | `test_null_last_modified` | Object without timestamp | NULL returned |

### 5.2 Concurrency Edge Cases

| Test ID | Test Name | Description | Expected Result |
|---------|-----------|-------------|-----------------|
| EDGE-020 | `test_parallel_scans` | Multiple FDW scans | No interference |
| EDGE-021 | `test_scan_interrupt` | Interrupted scan | Clean cleanup |
| EDGE-022 | `test_rescan_after_error` | Re-scan after failure | Works correctly |

---

## 6. Regression Tests

### 6.1 Known Issue Coverage

| Test ID | Issue | Description | Verification |
|---------|-------|-------------|--------------|
| REG-001 | N/A | AWS SigV4 special char encoding | Test with %20, + |
| REG-002 | N/A | Pagination continuation token | Test with markers |
| REG-003 | N/A | Timestamp timezone handling | UTC conversion |

### 6.2 Compatibility Tests

| Test ID | Test Name | Description |
|---------|-----------|-------------|
| COMPAT-001 | `test_postgres_15` | PostgreSQL 15 compatibility |
| COMPAT-002 | `test_postgres_16` | PostgreSQL 16 compatibility |
| COMPAT-003 | `test_postgres_17` | PostgreSQL 17 compatibility |
| COMPAT-004 | `test_wasm_runtime_v1` | Wrappers host v1 compat |

---

## 7. Test Execution

### Running Unit Tests

```bash
cd wasm-wrappers/fdw/aws_fdw
cargo test --lib
```

### Running Integration Tests

```bash
# Start test environment
docker-compose -f docker-compose.test.yml up -d

# Wait for services
./scripts/wait-for-localstack.sh

# Run integration tests
cargo test --test integration

# Cleanup
docker-compose -f docker-compose.test.yml down
```

### Running Security Tests

```bash
# Security tests require additional tooling
cargo test --test security --features security-tests

# SAST scanning
cargo clippy -- -D warnings
cargo audit

# Fuzzing (requires nightly)
cargo +nightly fuzz run fuzz_auth
cargo +nightly fuzz run fuzz_parse
```

### Running Performance Tests

```bash
# Performance tests
cargo test --test performance --release

# Benchmarks
cargo bench
```

### CI Pipeline Integration

```yaml
# .github/workflows/aws-fdw-tests.yml
name: AWS FDW Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run unit tests
        run: cargo test --lib
        working-directory: wasm-wrappers/fdw/aws_fdw

  integration-tests:
    runs-on: ubuntu-latest
    services:
      localstack:
        image: localstack/localstack:3.0
        ports:
          - 4566:4566
    steps:
      - uses: actions/checkout@v4
      - name: Setup test data
        run: ./scripts/setup-localstack.sh
      - name: Run integration tests
        run: cargo test --test integration

  security-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Security audit
        run: cargo audit
      - name: Clippy security lints
        run: cargo clippy -- -D warnings
      - name: Run security tests
        run: cargo test --test security
```

---

## 8. Test Coverage Requirements

| Category | Minimum Coverage | Target Coverage |
|----------|------------------|-----------------|
| Unit Tests | 80% | 90% |
| Integration Tests | 70% | 85% |
| Security Tests | 100% critical | 100% all |
| Error Paths | 90% | 95% |

### Coverage Measurement

```bash
# Generate coverage report
cargo tarpaulin --out Html --output-dir coverage/

# View report
open coverage/tarpaulin-report.html
```

---

## 9. Test Data Requirements

### S3 Test Data

- 3 buckets (empty, small, large)
- Objects with various sizes (0B, 1KB, 1MB)
- Objects with special characters in keys
- Objects in nested prefixes

### Lambda Test Data

- Functions with different runtimes
- Functions with environment variables
- Functions with layers

### CloudWatch Test Data

- Metrics in multiple namespaces
- Metrics with dimensions
- Historical data points

---

## 10. Acceptance Criteria

Before release, ALL of the following must pass:

1. **Unit Tests**: 100% pass rate, >80% coverage
2. **Integration Tests**: 100% pass rate for all services
3. **Security Tests**: 100% pass rate, no CRITICAL/HIGH findings
4. **Performance Tests**: All latency targets met
5. **Edge Cases**: 100% pass rate
6. **Regression Tests**: No regressions from previous versions

### Sign-off Checklist

- [ ] All unit tests passing
- [ ] All integration tests passing
- [ ] All security tests passing
- [ ] Security audit completed (cargo audit)
- [ ] Performance benchmarks acceptable
- [ ] Code coverage meets requirements
- [ ] Documentation updated
- [ ] CHANGELOG updated
