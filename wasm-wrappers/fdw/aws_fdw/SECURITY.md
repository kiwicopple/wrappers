# AWS FDW Security Analysis

> **Security Disclosure**: If you discover a security vulnerability, please report it via https://supabase.com/.well-known/security.txt

This document covers security considerations **specific to the AWS WASM FDW**.

For platform-wide security (credential masking, WASM checksum verification), see [/SECURITY.md](/SECURITY.md).

---

## AWS FDW Specific Vulnerabilities

### 1. SSRF via endpoint_url - CRITICAL

**Status: ✓ MITIGATED**

#### Attack Vector
The `endpoint_url` option could be abused to access internal resources:

```sql
-- Attack: Steal IAM credentials from EC2 metadata service
CREATE SERVER evil_server
  FOREIGN DATA WRAPPER aws_wrapper
  OPTIONS (
    endpoint_url 'http://169.254.169.254/latest/meta-data/iam/security-credentials/'
    -- ...
  );
```

#### Impact
- Steal IAM credentials from EC2 instance metadata
- Access internal services (databases, admin panels)
- Port scan internal network

#### Protection
The `validate_endpoint_url()` function in `lib.rs` blocks:

| Target | Example | Status |
|--------|---------|--------|
| AWS metadata | `http://169.254.169.254/` | BLOCKED |
| Localhost IP | `http://127.0.0.1/` | BLOCKED |
| Localhost name | `http://localhost/` | BLOCKED |
| Private 10.x | `http://10.0.0.1/` | BLOCKED |
| Private 172.16-31.x | `http://172.16.0.1/` | BLOCKED |
| Private 192.168.x | `http://192.168.1.1/` | BLOCKED |
| Link-local | `http://169.254.1.1/` | BLOCKED |
| IPv6 loopback | `http://[::1]/` | BLOCKED |
| DNS rebinding | `http://metadata.evil.com/` | BLOCKED |

---

### 2. Read-Only Enforcement

**Status: ✓ ENFORCED**

The AWS FDW only supports read operations:

```sql
-- These all fail with "operation not supported"
INSERT INTO aws_s3_objects ...;
UPDATE aws_s3_objects ...;
DELETE FROM aws_s3_objects ...;
```

---

### 3. XML Parsing Safety

**Status: ✓ SAFE**

Uses simple string parsing (not a full XML parser), immune to XXE attacks:

```rust
fn extract_xml_value(xml: &str, tag: &str) -> Option<String> {
    // Simple find-based parsing - no entity expansion
}
```

---

### 4. Input Validation

**Status: ✓ MITIGATED**

Input validation is now enforced for all user-provided filter values:

#### Bucket Names
The `validate_bucket_name()` function enforces AWS S3 bucket naming rules:
- Length: 3-63 characters
- Characters: lowercase letters, numbers, hyphens, periods
- No consecutive periods
- Cannot be formatted as IP address

#### Zone IDs
The `validate_zone_id()` function ensures Route53 zone IDs are valid:
- Length: 1-32 characters
- Characters: alphanumeric only

#### Header Injection Protection
The `validate_no_header_injection()` function blocks:
- CRLF characters (`\r`, `\n`) that could inject HTTP headers
- Null bytes (`\0`) that could cause parsing issues

---

### 5. DoS via Large Responses

**Status: ✓ MITIGATED**

Response size is now limited to prevent memory exhaustion:

```rust
const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024; // 10 MB limit
```

All HTTP responses are checked before processing:
- S3 ListBuckets/ListObjects
- EC2 DescribeInstances
- Lambda ListFunctions
- Route53 ListHostedZones/ListResourceRecordSets

---

## AWS Credential Best Practices

### Use Vault for Production
```sql
CREATE SERVER aws_server
  FOREIGN DATA WRAPPER aws_wrapper
  OPTIONS (
    aws_access_key_id_id 'vault-uuid-for-access-key',      -- Vault reference
    aws_secret_access_key_id 'vault-uuid-for-secret-key',  -- Vault reference
    region 'us-east-1'
  );
```

### Use IAM Roles When Possible
On EC2/ECS, prefer instance roles over access keys.

---

## Security Summary

All identified vulnerabilities have been mitigated:

| Issue | Severity | Status |
|-------|----------|--------|
| SSRF via endpoint_url | CRITICAL | ✓ MITIGATED |
| Read-only enforcement | HIGH | ✓ ENFORCED |
| DoS via large responses | MEDIUM | ✓ MITIGATED |
| Input validation | MEDIUM | ✓ MITIGATED |
| Header injection | LOW | ✓ MITIGATED |
| XML parsing (XXE) | MEDIUM | ✓ SAFE |

### Residual Risk: Path Traversal

**Status: Acceptable Risk**

S3 treats object keys as literal strings, so path traversal attempts like `../../../etc/passwd` are simply stored/retrieved as literal key names. This is by design and not exploitable.

---

## Testing

Security tests are in `tests/test_security_advanced.sql`:
- SSRF-001 to SSRF-006: SSRF blocking tests
- Tests verify server creation fails for blocked URLs

```bash
# Run security tests
psql -f tests/test_security_advanced.sql
```
