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

#### Bucket Names
Bucket names from WHERE clauses are passed to S3 API which handles validation.

#### Recommendation (Defense-in-Depth)
Consider adding pattern validation:
- Bucket names: `^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`
- Zone IDs: `^[A-Z0-9]+$`

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

## Open Considerations

| Issue | Severity | Notes |
|-------|----------|-------|
| DoS via large responses | MEDIUM | No response size limits |
| Header injection | LOW | URL encoding should prevent |
| Path traversal | LOW | S3 keys are just strings |

---

## Testing

Security tests are in `tests/test_security_advanced.sql`:
- SSRF-001 to SSRF-006: SSRF blocking tests
- Tests verify server creation fails for blocked URLs

```bash
# Run security tests
psql -f tests/test_security_advanced.sql
```
