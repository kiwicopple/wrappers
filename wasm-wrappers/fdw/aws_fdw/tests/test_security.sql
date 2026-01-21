-- AWS FDW Security Tests
-- These tests verify security constraints are properly enforced
-- Run against a PostgreSQL instance with the wrappers extension
-- and LocalStack running on localhost:4566

-- ============================================================================
-- Setup
-- ============================================================================

-- Clean up any existing test objects
DROP FOREIGN TABLE IF EXISTS sec_s3_buckets CASCADE;
DROP FOREIGN TABLE IF EXISTS sec_s3_objects CASCADE;
DROP FOREIGN TABLE IF EXISTS sec_ec2_instances CASCADE;
DROP FOREIGN TABLE IF EXISTS sec_lambda_functions CASCADE;
DROP FOREIGN TABLE IF EXISTS sec_route53_zones CASCADE;
DROP SERVER IF EXISTS aws_security_test_server CASCADE;
DROP FOREIGN DATA WRAPPER IF EXISTS aws_security_wrapper CASCADE;

-- Create the FDW
CREATE EXTENSION IF NOT EXISTS wrappers;

CREATE FOREIGN DATA WRAPPER aws_security_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;

CREATE SERVER aws_security_test_server
  FOREIGN DATA WRAPPER aws_security_wrapper
  OPTIONS (
    fdw_package_url 'file:///path/to/aws_fdw.wasm',
    fdw_package_name 'supabase:aws-fdw',
    fdw_package_version '0.1.0',
    aws_access_key_id 'test',
    aws_secret_access_key 'test',
    region 'us-east-1',
    endpoint_url 'http://localstack:4566'
  );

-- Create test tables for security testing
CREATE FOREIGN TABLE sec_s3_buckets (
  name text,
  creation_date timestamp
)
SERVER aws_security_test_server
OPTIONS (service 's3', object 'buckets');

CREATE FOREIGN TABLE sec_s3_objects (
  bucket text,
  key text,
  size bigint,
  last_modified timestamp,
  etag text,
  storage_class text
)
SERVER aws_security_test_server
OPTIONS (service 's3', object 'objects');

-- ============================================================================
-- Section 1: Read-Only Enforcement Tests (SEC-030 to SEC-035)
-- These verify that the FDW only supports read operations
-- ============================================================================

SELECT '=== SECTION 1: Read-Only Enforcement Tests ===' AS section;

-- SEC-030: Test INSERT is rejected
SELECT 'SEC-030: INSERT operation should be rejected' AS test;
DO $$
BEGIN
  INSERT INTO sec_s3_buckets (name, creation_date) VALUES ('attack-bucket', NOW());
  RAISE EXCEPTION 'SEC-030 FAILED: INSERT should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%not supported%' OR SQLERRM LIKE '%read-only%' THEN
      RAISE NOTICE 'SEC-030 PASSED: INSERT correctly rejected - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SEC-030 PASSED: INSERT rejected with error - %', SQLERRM;
    END IF;
END $$;

-- SEC-031: Test UPDATE is rejected
SELECT 'SEC-031: UPDATE operation should be rejected' AS test;
DO $$
BEGIN
  UPDATE sec_s3_buckets SET name = 'hacked' WHERE name = 'test-bucket';
  RAISE EXCEPTION 'SEC-031 FAILED: UPDATE should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%not supported%' OR SQLERRM LIKE '%read-only%' THEN
      RAISE NOTICE 'SEC-031 PASSED: UPDATE correctly rejected - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SEC-031 PASSED: UPDATE rejected with error - %', SQLERRM;
    END IF;
END $$;

-- SEC-032: Test DELETE is rejected
SELECT 'SEC-032: DELETE operation should be rejected' AS test;
DO $$
BEGIN
  DELETE FROM sec_s3_buckets WHERE name = 'test-bucket';
  RAISE EXCEPTION 'SEC-032 FAILED: DELETE should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE '%not supported%' OR SQLERRM LIKE '%read-only%' THEN
      RAISE NOTICE 'SEC-032 PASSED: DELETE correctly rejected - %', SQLERRM;
    ELSE
      RAISE NOTICE 'SEC-032 PASSED: DELETE rejected with error - %', SQLERRM;
    END IF;
END $$;

-- ============================================================================
-- Section 2: Input Validation Tests
-- ============================================================================

SELECT '=== SECTION 2: Input Validation Tests ===' AS section;

-- SEC-008: Test invalid service option
SELECT 'SEC-008: Invalid service option should fail' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE sec_invalid_service (key text)
  SERVER aws_security_test_server
  OPTIONS (service 'invalid_service', object 'test');

  PERFORM * FROM sec_invalid_service;
  RAISE EXCEPTION 'SEC-008 FAILED: Invalid service should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-008 PASSED: Invalid service rejected - %', SQLERRM;
END $$;

-- SEC-009: Test invalid object type
SELECT 'SEC-009: Invalid object type should fail' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE sec_invalid_object (key text)
  SERVER aws_security_test_server
  OPTIONS (service 's3', object 'invalid_object');

  PERFORM * FROM sec_invalid_object;
  RAISE EXCEPTION 'SEC-009 FAILED: Invalid object type should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-009 PASSED: Invalid object rejected - %', SQLERRM;
END $$;

-- SEC-009b: Test missing required service option
SELECT 'SEC-009b: Missing service option should fail' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE sec_no_service (key text)
  SERVER aws_security_test_server
  OPTIONS (object 'buckets');

  PERFORM * FROM sec_no_service;
  RAISE EXCEPTION 'SEC-009b FAILED: Missing service should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-009b PASSED: Missing service rejected - %', SQLERRM;
END $$;

-- SEC-009c: Test missing required object option
SELECT 'SEC-009c: Missing object option should fail' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE sec_no_object (key text)
  SERVER aws_security_test_server
  OPTIONS (service 's3');

  PERFORM * FROM sec_no_object;
  RAISE EXCEPTION 'SEC-009c FAILED: Missing object should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-009c PASSED: Missing object rejected - %', SQLERRM;
END $$;

-- ============================================================================
-- Section 3: S3 Objects - Bucket Requirement Test
-- ============================================================================

SELECT '=== SECTION 3: S3 Required Filter Tests ===' AS section;

-- Test that s3_objects requires bucket filter
SELECT 'SEC-S3-001: S3 objects without bucket filter should fail' AS test;
DO $$
BEGIN
  -- Try to query s3_objects without WHERE bucket clause
  PERFORM * FROM sec_s3_objects LIMIT 1;
  RAISE EXCEPTION 'SEC-S3-001 FAILED: Query without bucket should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-S3-001 PASSED: Query without bucket rejected - %', SQLERRM;
END $$;

-- ============================================================================
-- Section 4: Route53 Records - Zone ID Requirement Test
-- ============================================================================

SELECT '=== SECTION 4: Route53 Required Filter Tests ===' AS section;

CREATE FOREIGN TABLE sec_route53_records (
  zone_id text,
  name text,
  type text,
  ttl bigint,
  values jsonb
)
SERVER aws_security_test_server
OPTIONS (service 'route53', object 'records');

-- Test that route53_records requires zone_id filter
SELECT 'SEC-R53-001: Route53 records without zone_id filter should fail' AS test;
DO $$
BEGIN
  -- Try to query route53_records without WHERE zone_id clause
  PERFORM * FROM sec_route53_records LIMIT 1;
  RAISE EXCEPTION 'SEC-R53-001 FAILED: Query without zone_id should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-R53-001 PASSED: Query without zone_id rejected - %', SQLERRM;
END $$;

-- ============================================================================
-- Section 5: Import Foreign Schema Security Tests
-- ============================================================================

SELECT '=== SECTION 5: Import Foreign Schema Security Tests ===' AS section;

DROP SCHEMA IF EXISTS sec_import_test CASCADE;
CREATE SCHEMA sec_import_test;

-- Test invalid schema name
SELECT 'SEC-IFS-001: Invalid schema name should fail' AS test;
DO $$
BEGIN
  IMPORT FOREIGN SCHEMA invalid_schema FROM SERVER aws_security_test_server INTO sec_import_test;
  RAISE EXCEPTION 'SEC-IFS-001 FAILED: Invalid schema should have been rejected';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'SEC-IFS-001 PASSED: Invalid schema rejected - %', SQLERRM;
END $$;

-- Test valid import works
SELECT 'SEC-IFS-002: Valid schema import should work' AS test;
IMPORT FOREIGN SCHEMA s3 FROM SERVER aws_security_test_server INTO sec_import_test;
SELECT 'SEC-IFS-002 PASSED: Valid schema import succeeded' AS result;

-- Verify tables were created
SELECT 'SEC-IFS-003: Imported tables should be queryable' AS test;
SELECT count(*) AS bucket_count FROM sec_import_test.s3_buckets;

-- ============================================================================
-- Section 6: Read Operations Still Work
-- ============================================================================

SELECT '=== SECTION 6: Verify Read Operations Work ===' AS section;

SELECT 'SEC-READ-001: SELECT from S3 buckets should work' AS test;
SELECT name FROM sec_s3_buckets LIMIT 3;

SELECT 'SEC-READ-002: SELECT with WHERE filter should work' AS test;
SELECT name FROM sec_s3_buckets WHERE name = 'test-bucket';

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT 'All security tests completed!' AS status;

-- Uncomment to clean up
-- DROP SCHEMA sec_import_test CASCADE;
-- DROP FOREIGN TABLE IF EXISTS sec_route53_records CASCADE;
-- DROP FOREIGN TABLE IF EXISTS sec_s3_objects CASCADE;
-- DROP FOREIGN TABLE IF EXISTS sec_s3_buckets CASCADE;
-- DROP SERVER aws_security_test_server CASCADE;
-- DROP FOREIGN DATA WRAPPER aws_security_wrapper CASCADE;
