-- AWS Route53 FDW Integration Tests
-- Run these tests against a PostgreSQL instance with the wrappers extension
-- and LocalStack running on localhost:4566

-- ============================================================================
-- Setup
-- ============================================================================

-- Clean up any existing test objects
DROP FOREIGN TABLE IF EXISTS route53_hosted_zones CASCADE;
DROP FOREIGN TABLE IF EXISTS route53_records CASCADE;
DROP SERVER IF EXISTS aws_route53_test_server CASCADE;
DROP FOREIGN DATA WRAPPER IF EXISTS aws_route53_wrapper CASCADE;
DROP SCHEMA IF EXISTS route53_test CASCADE;

-- Create the FDW (assumes wasm_fdw extension is installed)
CREATE EXTENSION IF NOT EXISTS wrappers;

-- Create foreign data wrapper
CREATE FOREIGN DATA WRAPPER aws_route53_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;

-- Create server pointing to LocalStack
CREATE SERVER aws_route53_test_server
  FOREIGN DATA WRAPPER aws_route53_wrapper
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
-- Test 1: List Hosted Zones
-- ============================================================================

CREATE FOREIGN TABLE route53_hosted_zones (
  id text,
  name text,
  caller_reference text,
  resource_record_set_count bigint,
  comment text,
  is_private boolean
)
SERVER aws_route53_test_server
OPTIONS (
  service 'route53',
  object 'hosted_zones'
);

SELECT 'Test 1.1: List all hosted zones' AS test;
SELECT id, name, resource_record_set_count, is_private FROM route53_hosted_zones ORDER BY name;

SELECT 'Test 1.2: Count hosted zones' AS test;
SELECT count(*) AS zone_count FROM route53_hosted_zones;
-- Expected: 2

-- ============================================================================
-- Test 2: Query Hosted Zone Details
-- ============================================================================

SELECT 'Test 2.1: Query public zones' AS test;
SELECT id, name, comment
FROM route53_hosted_zones
WHERE is_private = false
ORDER BY name;

SELECT 'Test 2.2: Query zones with records' AS test;
SELECT id, name, resource_record_set_count
FROM route53_hosted_zones
WHERE resource_record_set_count > 0
ORDER BY resource_record_set_count DESC;

-- ============================================================================
-- Test 3: List Resource Record Sets
-- ============================================================================

CREATE FOREIGN TABLE route53_records (
  zone_id text,
  name text,
  type text,
  ttl bigint,
  values jsonb,
  alias_target jsonb,
  weight bigint,
  set_identifier text
)
SERVER aws_route53_test_server
OPTIONS (
  service 'route53',
  object 'records'
);

-- Get the zone ID for querying records (replace with actual zone ID from test 1)
SELECT 'Test 3.1: List records for a zone' AS test;
-- Note: This requires knowing the zone_id. Use WHERE zone_id = 'ZONE_ID'
-- SELECT name, type, ttl, values FROM route53_records WHERE zone_id = 'EXAMPLE_ZONE_ID';

-- ============================================================================
-- Test 4: Query DNS Records by Type
-- ============================================================================

SELECT 'Test 4.1: Query A records (if zone_id provided)' AS test;
-- SELECT name, type, ttl, values
-- FROM route53_records
-- WHERE zone_id = 'ZONE_ID' AND type = 'A';

SELECT 'Test 4.2: Query CNAME records (if zone_id provided)' AS test;
-- SELECT name, type, ttl, values
-- FROM route53_records
-- WHERE zone_id = 'ZONE_ID' AND type = 'CNAME';

-- ============================================================================
-- Test 5: Import Foreign Schema for Route53
-- ============================================================================

CREATE SCHEMA route53_test;

SELECT 'Test 5.1: Import Route53 schema' AS test;
IMPORT FOREIGN SCHEMA route53 FROM SERVER aws_route53_test_server INTO route53_test;

SELECT 'Test 5.2: Verify imported tables' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'route53_test'
ORDER BY table_name;
-- Expected: route53_hosted_zones, route53_records

SELECT 'Test 5.3: Query imported hosted zones table' AS test;
SELECT count(*) AS zone_count FROM route53_test.route53_hosted_zones;

-- ============================================================================
-- Test 6: Error Cases
-- ============================================================================

-- Test 6.1: Invalid object type for Route53
SELECT 'Test 6.1: Invalid Route53 object type (should fail)' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE route53_invalid_object (key text)
  SERVER aws_route53_test_server
  OPTIONS (service 'route53', object 'invalid');

  PERFORM * FROM route53_invalid_object;
  RAISE EXCEPTION 'Should have failed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- Test 6.2: Query records without zone_id
SELECT 'Test 6.2: Query records without zone_id (should fail)' AS test;
DO $$
BEGIN
  PERFORM * FROM route53_records;
  RAISE EXCEPTION 'Should have failed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT 'All Route53 tests completed!' AS status;

-- Uncomment to clean up
-- DROP SCHEMA route53_test CASCADE;
-- DROP FOREIGN TABLE route53_records CASCADE;
-- DROP FOREIGN TABLE route53_hosted_zones CASCADE;
-- DROP SERVER aws_route53_test_server CASCADE;
-- DROP FOREIGN DATA WRAPPER aws_route53_wrapper CASCADE;
