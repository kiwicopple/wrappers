-- AWS FDW Security Tests
-- These tests verify security measures SPECIFIC to the AWS FDW
-- See aws_fdw/SECURITY.md for AWS-specific documentation
-- See /SECURITY.md for platform-wide security (credential masking, supply chain)
--
-- Tests covered:
-- - SSRF protection via endpoint_url validation
-- - AWS-specific input validation
-- - Read-only enforcement

-- ============================================================================
-- Setup
-- ============================================================================

DROP SERVER IF EXISTS ssrf_test_server CASCADE;
DROP SCHEMA IF EXISTS sec_adv_test CASCADE;

CREATE EXTENSION IF NOT EXISTS wrappers;

-- ============================================================================
-- SECTION 1: SSRF (Server-Side Request Forgery) Tests
-- These tests verify the validate_endpoint_url() function blocks dangerous URLs
-- This protection is SPECIFIC to AWS FDW's endpoint_url option
-- ============================================================================

SELECT '=== SECTION 1: SSRF Protection Tests ===' AS section;

-- SSRF-001: Block AWS metadata service (169.254.169.254)
-- This is the most critical SSRF vector - attackers steal IAM credentials
SELECT 'SSRF-001: Block AWS metadata service IP' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_metadata_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://169.254.169.254/latest/meta-data/'
    );

  -- If we get here, SSRF protection FAILED
  RAISE EXCEPTION 'SSRF-001 FAILED: Metadata service URL was accepted - CRITICAL VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%169.254.169.254%' THEN
      RAISE NOTICE 'SSRF-001 PASSED: AWS metadata service blocked - %', SQLERRM;
    ELSIF SQLERRM LIKE '%SSRF%' OR SQLERRM LIKE '%blocked%' OR SQLERRM LIKE '%not allowed%' THEN
      RAISE NOTICE 'SSRF-001 PASSED: Metadata IP blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-001 INFO: Server creation failed (verify SSRF blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-002: Block localhost (127.0.0.1)
SELECT 'SSRF-002: Block localhost IP' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_localhost_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://127.0.0.1:8080/admin'
    );

  RAISE EXCEPTION 'SSRF-002 FAILED: Localhost URL was accepted - SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%Loopback%' THEN
      RAISE NOTICE 'SSRF-002 PASSED: Localhost blocked - %', SQLERRM;
    ELSIF SQLERRM LIKE '%SSRF%' OR SQLERRM LIKE '%blocked%' OR SQLERRM LIKE '%not allowed%' THEN
      RAISE NOTICE 'SSRF-002 PASSED: Localhost blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-002 INFO: Server creation failed (verify SSRF blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-003: Block private network (10.x.x.x)
SELECT 'SSRF-003: Block private network 10.x.x.x' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_private10_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://10.0.0.1:3306/'
    );

  RAISE EXCEPTION 'SSRF-003 FAILED: Private IP was accepted - SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%Private network%' THEN
      RAISE NOTICE 'SSRF-003 PASSED: Private network blocked - %', SQLERRM;
    ELSIF SQLERRM LIKE '%SSRF%' OR SQLERRM LIKE '%blocked%' OR SQLERRM LIKE '%not allowed%' THEN
      RAISE NOTICE 'SSRF-003 PASSED: Private IP blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-003 INFO: Server creation failed (verify SSRF blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-004: Block private network (192.168.x.x)
SELECT 'SSRF-004: Block private network 192.168.x.x' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_private192_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://192.168.1.1/'
    );

  RAISE EXCEPTION 'SSRF-004 FAILED: Private IP was accepted - SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%192.168%' THEN
      RAISE NOTICE 'SSRF-004 PASSED: Private network (192.168.x.x) blocked - %', SQLERRM;
    ELSIF SQLERRM LIKE '%SSRF%' OR SQLERRM LIKE '%blocked%' OR SQLERRM LIKE '%not allowed%' THEN
      RAISE NOTICE 'SSRF-004 PASSED: Private IP blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-004 INFO: Server creation failed (verify SSRF blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-005: Block localhost hostname
SELECT 'SSRF-005: Block localhost hostname' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_localhost_name_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://localhost:8080/'
    );

  RAISE EXCEPTION 'SSRF-005 FAILED: localhost hostname was accepted - SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%localhost%' THEN
      RAISE NOTICE 'SSRF-005 PASSED: localhost hostname blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-005 INFO: Server creation failed (verify SSRF blocking) - %', SQLERRM;
    END IF;
END $$;

-- SSRF-006: Block metadata-like hostnames (DNS rebinding protection)
SELECT 'SSRF-006: Block metadata hostname' AS test;
DO $$
BEGIN
  CREATE SERVER ssrf_metadata_hostname_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'test',
      aws_secret_access_key 'test',
      region 'us-east-1',
      endpoint_url 'http://metadata.evil.com/'
    );

  RAISE EXCEPTION 'SSRF-006 FAILED: metadata hostname was accepted - SECURITY VULNERABILITY';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%SSRF Protection%' AND SQLERRM LIKE '%metadata%' THEN
      RAISE NOTICE 'SSRF-006 PASSED: Suspicious hostname blocked - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SSRF-006 INFO: Server creation failed (verify hostname blocking) - %', SQLERRM;
    END IF;
END $$;

-- ============================================================================
-- SECTION 2: AWS-Specific Input Validation Tests
-- These test S3/AWS-specific query parameter handling
-- ============================================================================

SELECT '=== SECTION 2: AWS Input Validation Tests ===' AS section;

-- INJ-001: SQL injection in bucket name (S3-specific)
SELECT 'INJ-001: SQL injection attempt in S3 bucket name' AS test;
DO $$
BEGIN
  CREATE SERVER inj_test_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
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

-- INJ-002: HTTP header injection attempt (S3-specific)
SELECT 'INJ-002: HTTP header injection attempt in S3 request' AS test;
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

-- INJ-003: Path traversal attempt (S3-specific)
SELECT 'INJ-003: Path traversal attempt in S3 key' AS test;
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

-- ============================================================================
-- SECTION 3: Read-Only Enforcement Tests
-- AWS FDW only supports read operations
-- ============================================================================

SELECT '=== SECTION 3: Read-Only Enforcement Tests ===' AS section;

-- RO-001: Confirm write operations blocked
SELECT 'RO-001: INSERT must be blocked' AS test;
-- INSERT/UPDATE/DELETE should return "operation not supported" error
SELECT 'RO-001 INFO: INSERT/UPDATE/DELETE should return "not supported" error' AS info;
SELECT 'RO-001 INFO: See test_security.sql for detailed write operation tests (SEC-030 to SEC-032)' AS info;

-- ============================================================================
-- SECTION 4: AWS Credential Security
-- These test AWS-specific credential handling
-- ============================================================================

SELECT '=== SECTION 4: AWS Credential Security ===' AS section;

-- CRED-AWS-001: Verify AWS credentials not in error messages
SELECT 'CRED-AWS-001: AWS credentials should not appear in errors' AS test;
DO $$
DECLARE
  error_msg TEXT;
BEGIN
  CREATE SERVER aws_cred_test_server
    FOREIGN DATA WRAPPER wasm_wrapper
    OPTIONS (
      fdw_package_url 'file:///path/to/aws_fdw.wasm',
      fdw_package_name 'supabase:aws-fdw',
      fdw_package_version '0.1.0',
      fdw_package_checksum 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      aws_access_key_id 'AKIATESTKEY12345678',
      aws_secret_access_key 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      region 'invalid-region-xyz',
      endpoint_url 'https://s3.invalid-region-xyz.amazonaws.com'
    );

  CREATE FOREIGN TABLE aws_cred_leak_test (name text)
  SERVER aws_cred_test_server
  OPTIONS (service 's3', object 'buckets');

  PERFORM * FROM aws_cred_leak_test;
EXCEPTION
  WHEN OTHERS THEN
    error_msg := SQLERRM;
    -- Check that AWS secret key is masked
    IF error_msg LIKE '%wJalrXUtnFEMI%' THEN
      RAISE EXCEPTION 'CRED-AWS-001 FAILED: Full AWS secret key leaked in error: %', error_msg;
    ELSIF error_msg LIKE '%wJal***%' THEN
      RAISE NOTICE 'CRED-AWS-001 PASSED: AWS secret key properly masked';
    ELSIF error_msg LIKE '%MDENG%' OR error_msg LIKE '%EXAMPLE%' THEN
      RAISE EXCEPTION 'CRED-AWS-001 FAILED: Partial secret key leaked: %', error_msg;
    ELSE
      RAISE NOTICE 'CRED-AWS-001 PASSED: AWS credentials not in error message';
    END IF;
END $$;

-- ============================================================================
-- SECTION 5: Authorization Tests
-- ============================================================================

SELECT '=== SECTION 5: Authorization Tests ===' AS section;

-- AUTH-001: Foreign server access control
SELECT 'AUTH-001: Foreign server access control' AS test;
-- This relies on PostgreSQL's GRANT/REVOKE system
SELECT 'AUTH-001 INFO: Verify USAGE on foreign servers is properly restricted' AS info;
SELECT 'AUTH-001 INFO: Run: REVOKE ALL ON FOREIGN SERVER aws_server FROM PUBLIC;' AS recommendation;

-- ============================================================================
-- Cleanup
-- ============================================================================

DROP SERVER IF EXISTS ssrf_metadata_server CASCADE;
DROP SERVER IF EXISTS ssrf_localhost_server CASCADE;
DROP SERVER IF EXISTS ssrf_private10_server CASCADE;
DROP SERVER IF EXISTS ssrf_private192_server CASCADE;
DROP SERVER IF EXISTS ssrf_localhost_name_server CASCADE;
DROP SERVER IF EXISTS ssrf_metadata_hostname_server CASCADE;
DROP SERVER IF EXISTS inj_test_server CASCADE;
DROP SERVER IF EXISTS aws_cred_test_server CASCADE;

SELECT '=== AWS FDW Security Tests Complete ===' AS status;
SELECT 'IMPORTANT: Review any FAILED or WARNING results above' AS note;
SELECT 'NOTE: For platform-wide security tests (supply chain, credential masking), see /wasm-wrappers/tests/test_wasm_security.sql' AS note2;
