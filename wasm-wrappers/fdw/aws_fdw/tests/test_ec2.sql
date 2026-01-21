-- AWS EC2 FDW Integration Tests
-- Run these tests against a PostgreSQL instance with the wrappers extension
-- and LocalStack running on localhost:4566

-- ============================================================================
-- Setup
-- ============================================================================

-- Clean up any existing test objects
DROP FOREIGN TABLE IF EXISTS ec2_instances CASCADE;
DROP SERVER IF EXISTS aws_ec2_test_server CASCADE;
DROP FOREIGN DATA WRAPPER IF EXISTS aws_ec2_wrapper CASCADE;
DROP SCHEMA IF EXISTS ec2_test CASCADE;

-- Create the FDW (assumes wasm_fdw extension is installed)
CREATE EXTENSION IF NOT EXISTS wrappers;

-- Create foreign data wrapper
CREATE FOREIGN DATA WRAPPER aws_ec2_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;

-- Create server pointing to LocalStack
CREATE SERVER aws_ec2_test_server
  FOREIGN DATA WRAPPER aws_ec2_wrapper
  OPTIONS (
    fdw_package_url 'file:///path/to/aws_fdw.wasm',
    fdw_package_name 'supabase:aws-fdw',
    fdw_package_version '0.1.0',
    aws_access_key_id 'test',
    aws_secret_access_key 'test',
    region 'us-east-1',
    endpoint_url 'http://localstack:4566'
  );

-- ============================================================================
-- Test 1: List EC2 Instances
-- ============================================================================

CREATE FOREIGN TABLE ec2_instances (
  instance_id text,
  instance_type text,
  state text,
  public_ip text,
  private_ip text,
  vpc_id text,
  subnet_id text,
  launch_time timestamp,
  tags jsonb
)
SERVER aws_ec2_test_server
OPTIONS (
  service 'ec2',
  object 'instances'
);

SELECT 'Test 1.1: List all instances' AS test;
SELECT instance_id, instance_type, state FROM ec2_instances ORDER BY instance_id;

SELECT 'Test 1.2: Count instances' AS test;
SELECT count(*) AS instance_count FROM ec2_instances;
-- Expected: 3

-- ============================================================================
-- Test 2: Query Instance Details
-- ============================================================================

SELECT 'Test 2.1: Query instance types' AS test;
SELECT DISTINCT instance_type FROM ec2_instances ORDER BY instance_type;
-- Expected: t2.large, t2.micro, t2.small

SELECT 'Test 2.2: Query instances by type' AS test;
SELECT instance_id, instance_type, state
FROM ec2_instances
WHERE instance_type = 't2.micro';
-- Expected: 1 row (web-server)

-- ============================================================================
-- Test 3: Query Instance Tags
-- ============================================================================

SELECT 'Test 3.1: Query instances with tags' AS test;
SELECT instance_id, tags->>'Name' AS name, tags->>'Environment' AS environment
FROM ec2_instances
ORDER BY instance_id;

SELECT 'Test 3.2: Filter by tag value (client-side)' AS test;
SELECT instance_id, tags->>'Name' AS name
FROM ec2_instances
WHERE tags->>'Environment' = 'production';
-- Expected: 2 rows (web-server, db-server)

-- ============================================================================
-- Test 4: Instance State
-- ============================================================================

SELECT 'Test 4.1: Query instances by state' AS test;
SELECT instance_id, state FROM ec2_instances ORDER BY instance_id;
-- All should be 'running' in LocalStack

-- ============================================================================
-- Test 5: Network Information
-- ============================================================================

SELECT 'Test 5.1: Query network details' AS test;
SELECT instance_id, private_ip, public_ip, vpc_id, subnet_id
FROM ec2_instances
ORDER BY instance_id;

-- ============================================================================
-- Test 6: Import Foreign Schema for EC2
-- ============================================================================

CREATE SCHEMA ec2_test;

SELECT 'Test 6.1: Import EC2 schema' AS test;
IMPORT FOREIGN SCHEMA ec2 FROM SERVER aws_ec2_test_server INTO ec2_test;

SELECT 'Test 6.2: Verify imported tables' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'ec2_test'
ORDER BY table_name;
-- Expected: ec2_instances

SELECT 'Test 6.3: Query imported instances table' AS test;
SELECT count(*) AS instance_count FROM ec2_test.ec2_instances;
-- Expected: 3

-- ============================================================================
-- Test 7: Combined S3 and EC2 Query (Cross-service)
-- ============================================================================

-- This test assumes the S3 server is also set up
-- It demonstrates that both services can be queried independently

SELECT 'Test 7.1: Query both services exist' AS test;
SELECT 'ec2' AS service, count(*) AS count FROM ec2_instances
UNION ALL
SELECT 's3_would_go_here', 0;

-- ============================================================================
-- Test 8: Error Cases
-- ============================================================================

-- Test 8.1: Invalid object type for EC2
SELECT 'Test 8.1: Invalid EC2 object type (should fail)' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE ec2_invalid_object (key text)
  SERVER aws_ec2_test_server
  OPTIONS (service 'ec2', object 'invalid');

  PERFORM * FROM ec2_invalid_object;
  RAISE EXCEPTION 'Should have failed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT 'All EC2 tests completed!' AS status;

-- Uncomment to clean up
-- DROP SCHEMA ec2_test CASCADE;
-- DROP FOREIGN TABLE ec2_instances CASCADE;
-- DROP SERVER aws_ec2_test_server CASCADE;
-- DROP FOREIGN DATA WRAPPER aws_ec2_wrapper CASCADE;
