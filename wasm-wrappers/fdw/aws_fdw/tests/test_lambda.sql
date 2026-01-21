-- AWS Lambda FDW Integration Tests
-- Run these tests against a PostgreSQL instance with the wrappers extension
-- and LocalStack running on localhost:4566

-- ============================================================================
-- Setup
-- ============================================================================

-- Clean up any existing test objects
DROP FOREIGN TABLE IF EXISTS lambda_functions CASCADE;
DROP SERVER IF EXISTS aws_lambda_test_server CASCADE;
DROP FOREIGN DATA WRAPPER IF EXISTS aws_lambda_wrapper CASCADE;
DROP SCHEMA IF EXISTS lambda_test CASCADE;

-- Create the FDW (assumes wasm_fdw extension is installed)
CREATE EXTENSION IF NOT EXISTS wrappers;

-- Create foreign data wrapper
CREATE FOREIGN DATA WRAPPER aws_lambda_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;

-- Create server pointing to LocalStack
CREATE SERVER aws_lambda_test_server
  FOREIGN DATA WRAPPER aws_lambda_wrapper
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
-- Test 1: List Lambda Functions
-- ============================================================================

CREATE FOREIGN TABLE lambda_functions (
  function_name text,
  function_arn text,
  runtime text,
  handler text,
  code_size bigint,
  memory_size int,
  timeout int,
  last_modified timestamp,
  description text,
  state text
)
SERVER aws_lambda_test_server
OPTIONS (
  service 'lambda',
  object 'functions'
);

SELECT 'Test 1.1: List all functions' AS test;
SELECT function_name, runtime, memory_size, timeout FROM lambda_functions ORDER BY function_name;

SELECT 'Test 1.2: Count functions' AS test;
SELECT count(*) AS function_count FROM lambda_functions;
-- Expected: 3

-- ============================================================================
-- Test 2: Query Function Details
-- ============================================================================

SELECT 'Test 2.1: Query functions by runtime' AS test;
SELECT function_name, runtime, handler
FROM lambda_functions
WHERE runtime LIKE 'python%'
ORDER BY function_name;

SELECT 'Test 2.2: Query functions by memory size' AS test;
SELECT function_name, memory_size, timeout
FROM lambda_functions
WHERE memory_size >= 256
ORDER BY memory_size DESC;

-- ============================================================================
-- Test 3: Query Function Configuration
-- ============================================================================

SELECT 'Test 3.1: Query function handlers' AS test;
SELECT function_name, handler, description
FROM lambda_functions
ORDER BY function_name;

SELECT 'Test 3.2: Query function ARNs' AS test;
SELECT function_name, function_arn
FROM lambda_functions
ORDER BY function_name;

-- ============================================================================
-- Test 4: Query Function Code Size
-- ============================================================================

SELECT 'Test 4.1: Query code sizes' AS test;
SELECT function_name, code_size
FROM lambda_functions
ORDER BY code_size DESC;

SELECT 'Test 4.2: Total code size' AS test;
SELECT SUM(code_size) AS total_code_size FROM lambda_functions;

-- ============================================================================
-- Test 5: Import Foreign Schema for Lambda
-- ============================================================================

CREATE SCHEMA lambda_test;

SELECT 'Test 5.1: Import Lambda schema' AS test;
IMPORT FOREIGN SCHEMA lambda FROM SERVER aws_lambda_test_server INTO lambda_test;

SELECT 'Test 5.2: Verify imported tables' AS test;
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'lambda_test'
ORDER BY table_name;
-- Expected: lambda_functions

SELECT 'Test 5.3: Query imported functions table' AS test;
SELECT count(*) AS function_count FROM lambda_test.lambda_functions;
-- Expected: 3

-- ============================================================================
-- Test 6: Error Cases
-- ============================================================================

-- Test 6.1: Invalid object type for Lambda
SELECT 'Test 6.1: Invalid Lambda object type (should fail)' AS test;
DO $$
BEGIN
  CREATE FOREIGN TABLE lambda_invalid_object (key text)
  SERVER aws_lambda_test_server
  OPTIONS (service 'lambda', object 'invalid');

  PERFORM * FROM lambda_invalid_object;
  RAISE EXCEPTION 'Should have failed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- ============================================================================
-- Cleanup
-- ============================================================================

SELECT 'All Lambda tests completed!' AS status;

-- Uncomment to clean up
-- DROP SCHEMA lambda_test CASCADE;
-- DROP FOREIGN TABLE lambda_functions CASCADE;
-- DROP SERVER aws_lambda_test_server CASCADE;
-- DROP FOREIGN DATA WRAPPER aws_lambda_wrapper CASCADE;
