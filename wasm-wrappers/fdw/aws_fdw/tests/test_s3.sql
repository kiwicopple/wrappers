-- AWS S3 FDW Integration Tests
-- Run these tests against a PostgreSQL instance with the wrappers extension
-- and LocalStack running on localhost:4566

-- ============================================================================
-- Setup
-- ============================================================================

-- Clean up any existing test objects
DROP FOREIGN TABLE IF EXISTS s3_buckets CASCADE;
DROP FOREIGN TABLE IF EXISTS s3_objects CASCADE;
DROP SERVER IF EXISTS aws_test_server CASCADE;
DROP FOREIGN DATA WRAPPER IF EXISTS aws_wrapper CASCADE;
DROP SCHEMA IF EXISTS aws_test CASCADE;
DROP SCHEMA IF EXISTS aws_limited CASCADE;
DROP SCHEMA IF EXISTS aws_except CASCADE;

-- Create the FDW (assumes wasm_fdw extension is installed)
CREATE EXTENSION IF NOT EXISTS wrappers;

-- Create foreign data wrapper
CREATE FOREIGN DATA WRAPPER aws_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;

-- Create server pointing to LocalStack
-- NOTE: fdw_package_checksum is REQUIRED for security (prevents supply chain attacks)
-- Calculate with: sha256sum aws_fdw.wasm | awk '{print "sha256:" $1}'
CREATE SERVER aws_test_server
  FOREIGN DATA WRAPPER aws_wrapper
  OPTIONS (
    fdw_package_url 'file:///path/to/aws_fdw.wasm',
    fdw_package_name 'supabase:aws-fdw',
    fdw_package_version '0.1.0',
    fdw_package_checksum 'sha256:REPLACE_WITH_ACTUAL_CHECKSUM',
    aws_access_key_id 'test',
    aws_secret_access_key 'test',
    region 'us-east-1',
    endpoint_url 'http://localstack:4566'
  );

-- ============================================================================
-- Test 1: List Buckets
-- ============================================================================

CREATE FOREIGN TABLE s3_buckets (
  name text,
  creation_date timestamp
)
SERVER aws_test_server
OPTIONS (
  service 's3',
  object 'buckets'
);

-- Should return 3 buckets: test-bucket, empty-bucket, large-bucket
SELECT 'Test 1.1: List all buckets' AS test;
SELECT * FROM s3_buckets ORDER BY name;

SELECT 'Test 1.2: Count buckets' AS test;
SELECT count(*) AS bucket_count FROM s3_buckets;
-- Expected: 3

-- ============================================================================
-- Test 2: List Objects in a Bucket (using WHERE clause)
-- ============================================================================

-- Note: bucket column is required in WHERE clause
CREATE FOREIGN TABLE s3_objects (
  bucket text,
  key text,
  size bigint,
  last_modified timestamp,
  etag text,
  storage_class text
)
SERVER aws_test_server
OPTIONS (
  service 's3',
  object 'objects'
);

SELECT 'Test 2.1: List objects in test-bucket' AS test;
SELECT bucket, key, size FROM s3_objects WHERE bucket = 'test-bucket' ORDER BY key;

SELECT 'Test 2.2: Count objects in test-bucket' AS test;
SELECT count(*) AS object_count FROM s3_objects WHERE bucket = 'test-bucket';
-- Expected: 4

-- ============================================================================
-- Test 3: List Objects with Prefix Filter
-- ============================================================================

SELECT 'Test 3.1: List objects with prefix data/' AS test;
SELECT bucket, key, size FROM s3_objects
WHERE bucket = 'test-bucket' AND prefix = 'data/'
ORDER BY key;

SELECT 'Test 3.2: Count objects with prefix' AS test;
SELECT count(*) AS object_count FROM s3_objects
WHERE bucket = 'test-bucket' AND prefix = 'data/';
-- Expected: 2

-- ============================================================================
-- Test 4: Empty Bucket
-- ============================================================================

SELECT 'Test 4.1: List objects in empty bucket' AS test;
SELECT * FROM s3_objects WHERE bucket = 'empty-bucket';
-- Expected: 0 rows

-- ============================================================================
-- Test 5: Large Bucket (Pagination)
-- ============================================================================

SELECT 'Test 5.1: Count objects in large bucket' AS test;
SELECT count(*) AS object_count FROM s3_objects WHERE bucket = 'large-bucket';
-- Expected: 100

-- ============================================================================
-- Test 6: Import Foreign Schema
-- ============================================================================

CREATE SCHEMA aws_test;

SELECT 'Test 6.1: Import S3 schema' AS test;
IMPORT FOREIGN SCHEMA s3 FROM SERVER aws_test_server INTO aws_test;

SELECT 'Test 6.2: Verify imported tables' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'aws_test'
ORDER BY table_name;
-- Expected: s3_buckets, s3_objects

SELECT 'Test 6.3: Query imported buckets table' AS test;
SELECT count(*) AS bucket_count FROM aws_test.s3_buckets;
-- Expected: 3

SELECT 'Test 6.4: Query imported objects table with WHERE bucket' AS test;
SELECT count(*) AS object_count FROM aws_test.s3_objects WHERE bucket = 'test-bucket';
-- Expected: 4

-- ============================================================================
-- Test 7: Import with LIMIT TO
-- ============================================================================

CREATE SCHEMA aws_limited;

SELECT 'Test 7.1: Import S3 schema with LIMIT TO' AS test;
IMPORT FOREIGN SCHEMA s3 LIMIT TO (buckets) FROM SERVER aws_test_server INTO aws_limited;

SELECT 'Test 7.2: Verify only buckets table imported' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'aws_limited'
ORDER BY table_name;
-- Expected: s3_buckets (only)

-- ============================================================================
-- Test 8: Import with EXCEPT
-- ============================================================================

CREATE SCHEMA aws_except;

SELECT 'Test 8.1: Import S3 schema with EXCEPT' AS test;
IMPORT FOREIGN SCHEMA s3 EXCEPT (objects) FROM SERVER aws_test_server INTO aws_except;

SELECT 'Test 8.2: Verify objects table excluded' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'aws_except'
ORDER BY table_name;
-- Expected: s3_buckets (only)

-- ============================================================================
-- Test 9: Error Cases
-- ============================================================================

-- Test 9.1: Missing bucket in WHERE clause for objects
SELECT 'Test 9.1: Missing bucket WHERE clause (should fail)' AS test;
DO $$
BEGIN
  PERFORM * FROM s3_objects LIMIT 1;
  RAISE EXCEPTION 'Should have failed - bucket is required';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- Test 9.2: Invalid service
SELECT 'Test 9.2: Invalid service (should fail)' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE s3_invalid_service (key text)
  SERVER aws_test_server
  OPTIONS (service 'invalid', object 'buckets');

  PERFORM * FROM s3_invalid_service;
  RAISE EXCEPTION 'Should have failed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- ============================================================================
-- Test 10: Query Multiple Buckets
-- ============================================================================

SELECT 'Test 10.1: Query different buckets in sequence' AS test;
SELECT 'test-bucket' AS source, count(*) AS count FROM s3_objects WHERE bucket = 'test-bucket'
UNION ALL
SELECT 'empty-bucket', count(*) FROM s3_objects WHERE bucket = 'empty-bucket'
UNION ALL
SELECT 'large-bucket', count(*) FROM s3_objects WHERE bucket = 'large-bucket';
-- Expected: test-bucket: 4, empty-bucket: 0, large-bucket: 100

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT 'All tests completed!' AS status;

-- Uncomment to clean up
-- DROP SCHEMA aws_test CASCADE;
-- DROP SCHEMA aws_limited CASCADE;
-- DROP SCHEMA aws_except CASCADE;
-- DROP FOREIGN TABLE s3_buckets CASCADE;
-- DROP FOREIGN TABLE s3_objects CASCADE;
-- DROP SERVER aws_test_server CASCADE;
-- DROP FOREIGN DATA WRAPPER aws_wrapper CASCADE;
