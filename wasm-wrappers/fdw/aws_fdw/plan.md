# AWS WASM Wrapper Plan

## Overview

This document outlines the plan for creating a WebAssembly (WASM) Foreign Data Wrapper (FDW) for AWS cloud services. The wrapper will enable PostgreSQL to query AWS resources directly using standard SQL syntax.

## Goals

1. Create a portable, secure WASM-based AWS wrapper
2. Support multiple AWS services through a unified interface
3. Follow existing WASM wrapper patterns in the codebase
4. Enable community contributions and easy deployment
5. **Read-only access** - No write/modify operations in initial release

## AWS Services to Support

### Phase 1: Initial Release (Read-Only)

| Service | Description | Operations |
|---------|-------------|------------|
| **S3** | Object storage listing | List buckets, list objects, get object metadata |
| **Lambda** | Serverless functions | List functions, get function details |
| **CloudWatch** | Metrics and logs | List metrics, get metric data |

### Future Phases

| Service | Description |
|---------|-------------|
| EC2 | Instance listing and details |
| RDS | Database instance listing |
| SQS | Queue listing and message counts |
| SNS | Topic listing |
| IAM | User/role listing |
| Secrets Manager | Secret listing (not values) |

## Architecture

### File Structure

```
wasm-wrappers/fdw/aws_fdw/
├── Cargo.toml              # Package configuration
├── src/
│   ├── lib.rs              # Main entry point and FDW implementation
│   ├── aws_client.rs       # AWS API client using HTTP
│   ├── auth.rs             # AWS Signature V4 signing
│   ├── services/
│   │   ├── mod.rs          # Service module exports
│   │   ├── s3.rs           # S3 service implementation
│   │   ├── lambda.rs       # Lambda service implementation
│   │   └── cloudwatch.rs   # CloudWatch service implementation
│   └── types.rs            # Shared types and conversions
└── wit/
    └── world.wit           # WIT interface definition
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     PostgreSQL                               │
│                         │                                    │
│                         ▼                                    │
│              ┌──────────────────┐                           │
│              │   Wrappers Host  │                           │
│              │   (WASM Runtime) │                           │
│              └────────┬─────────┘                           │
│                       │                                      │
└───────────────────────┼──────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                   AWS WASM FDW (Read-Only)                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    lib.rs                            │    │
│  │  - FDW lifecycle (init, scan only)                  │    │
│  │  - Service routing based on table options           │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                    │
│  ┌──────────────────────┴──────────────────────────────┐    │
│  │                   Services Layer                     │    │
│  │  ┌─────────┐ ┌────────┐ ┌───────────┐              │    │
│  │  │   S3    │ │ Lambda │ │CloudWatch │              │    │
│  │  └────┬────┘ └───┬────┘ └─────┬─────┘              │    │
│  └───────┼──────────┼────────────┼─────────────────────┘    │
│          │          │            │                          │
│  ┌───────┴──────────┴────────────┴───────────────────┐     │
│  │              AWS Client (auth.rs)                   │     │
│  │  - AWS Signature V4 signing                        │     │
│  │  - Request construction (GET/HEAD only)            │     │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                    │
└─────────────────────────┼────────────────────────────────────┘
                          │
                          ▼
                    ┌───────────┐
                    │  AWS API  │
                    │ (HTTPS)   │
                    └───────────┘
```

## Implementation Details

### 1. Cargo.toml Configuration

```toml
[package]
name = "aws_fdw"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen-rt = "0.41.0"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
chrono = { version = "0.4", default-features = false, features = ["alloc"] }
hmac = "0.12"
sha2 = "0.10"
hex = "0.4"
urlencoding = "2.1"

[package.metadata.component]
package = "supabase:aws-fdw"

[package.metadata.component.target.dependencies]
"supabase:wrappers" = { path = "../../wit/v2" }
```

### 2. WIT Interface Definition (wit/world.wit)

```wit
package supabase:aws-fdw;

world aws-fdw {
    include supabase:wrappers/routines@0.2.0;
}
```

### 3. AWS Authentication (auth.rs)

Implement AWS Signature Version 4 signing:

```rust
// Key components:
// - Canonical request construction
// - String to sign generation
// - Signature calculation using HMAC-SHA256
// - Authorization header construction

pub struct AwsCredentials {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: Option<String>,
}

pub fn sign_request(
    credentials: &AwsCredentials,
    method: &str,  // GET or HEAD only for read-only
    url: &str,
    headers: &[(String, String)],
    body: &[u8],
    service: &str,
    region: &str,
) -> Vec<(String, String)>;
```

### 4. FDW Implementation (lib.rs)

```rust
// Singleton pattern for FDW instance (following snowflake_fdw pattern)
static mut FDW_INSTANCE: Option<AwsFdw> = None;

struct AwsFdw {
    credentials: AwsCredentials,
    region: String,
    service: AwsService,
    rows: Vec<Row>,
    row_idx: usize,
}

enum AwsService {
    S3 { bucket: Option<String>, prefix: Option<String> },
    Lambda { function_name: Option<String> },
    CloudWatch { namespace: String, metric_name: Option<String> },
}

// Implement FDW routines (read-only):
// - init(): Parse server options, get credentials from Vault
// - begin_scan(): Call appropriate AWS service API
// - iter_scan(): Return rows one at a time
// - re_scan(): Reset row index
// - end_scan(): Cleanup
//
// NOT implemented (read-only):
// - begin_modify, insert, update, delete, end_modify
```

### 5. Service Implementations (Read-Only)

#### S3 Service (services/s3.rs)

| Operation | API Endpoint | Foreign Table Columns |
|-----------|--------------|----------------------|
| ListBuckets | GET / | name, creation_date |
| ListObjectsV2 | GET /{bucket}?list-type=2 | key, size, last_modified, etag, storage_class |
| HeadObject | HEAD /{bucket}/{key} | content_type, content_length, metadata |

#### Lambda Service (services/lambda.rs)

| Operation | API Endpoint | Foreign Table Columns |
|-----------|--------------|----------------------|
| ListFunctions | GET /2015-03-31/functions | function_name, runtime, handler, memory_size, timeout, last_modified, description |
| GetFunction | GET /2015-03-31/functions/{name} | function_name, runtime, handler, code_size, last_modified, state |

#### CloudWatch Service (services/cloudwatch.rs)

| Operation | API Action | Foreign Table Columns |
|-----------|------------|----------------------|
| ListMetrics | ListMetrics | namespace, metric_name, dimensions |
| GetMetricData | GetMetricData | timestamp, value, unit |

## Server and Table Options

### Server Options

| Option | Required | Description |
|--------|----------|-------------|
| `aws_access_key_id` | No* | AWS access key (or use Vault) |
| `aws_secret_access_key` | No* | AWS secret key (or use Vault) |
| `aws_access_key_id_id` | No* | Vault secret ID for access key |
| `aws_secret_access_key_id` | No* | Vault secret ID for secret key |
| `region` | Yes | AWS region (e.g., us-east-1) |
| `endpoint_url` | No | Custom endpoint (for LocalStack, etc.) |

*Either direct credentials or Vault secret IDs required

### Table Options

| Option | Service | Description |
|--------|---------|-------------|
| `service` | All | AWS service name: s3, lambda, cloudwatch |
| `object` | All | Object type to query (e.g., buckets, objects, functions) |
| `bucket` | S3 | S3 bucket name |
| `prefix` | S3 | Object key prefix filter |
| `function_name` | Lambda | Lambda function name (for details) |
| `namespace` | CloudWatch | CloudWatch metric namespace |
| `metric_name` | CloudWatch | CloudWatch metric name |

## SQL Usage Examples

### Setup

```sql
-- Create the FDW
create extension if not exists wrappers;

create foreign data wrapper aws_wrapper
  handler wasm_fdw_handler
  validator wasm_fdw_validator;

-- Create server with credentials from Vault
create server aws_server
  foreign data wrapper aws_wrapper
  options (
    fdw_package_url 'https://github.com/supabase/wrappers/releases/download/wasm_aws_fdw_v0.1.0/aws_fdw.wasm',
    fdw_package_name 'supabase:aws-fdw',
    fdw_package_version '0.1.0',
    fdw_package_checksum '<sha256-checksum>',
    aws_access_key_id_id '<vault_secret_id>',
    aws_secret_access_key_id '<vault_secret_id>',
    region 'us-east-1'
  );
```

### S3 Examples

```sql
-- List all S3 buckets
create foreign table aws_s3_buckets (
  name text,
  creation_date timestamp
)
server aws_server
options (
  service 's3',
  object 'buckets'
);

select * from aws_s3_buckets;

-- List objects in a bucket
create foreign table aws_s3_objects (
  key text,
  size bigint,
  last_modified timestamp,
  etag text,
  storage_class text
)
server aws_server
options (
  service 's3',
  object 'objects',
  bucket 'my-bucket',
  prefix 'data/'
);

select * from aws_s3_objects where key like '%.json';
```

### Lambda Examples

```sql
-- List Lambda functions
create foreign table aws_lambda_functions (
  function_name text,
  runtime text,
  handler text,
  memory_size int,
  timeout int,
  last_modified timestamp,
  description text
)
server aws_server
options (
  service 'lambda',
  object 'functions'
);

select * from aws_lambda_functions where runtime like 'python%';

-- Get specific function details
create foreign table my_function_details (
  function_name text,
  runtime text,
  handler text,
  code_size bigint,
  last_modified timestamp,
  state text
)
server aws_server
options (
  service 'lambda',
  object 'function',
  function_name 'my-function'
);

select * from my_function_details;
```

### CloudWatch Examples

```sql
-- List available metrics
create foreign table aws_cloudwatch_metrics (
  namespace text,
  metric_name text,
  dimensions jsonb
)
server aws_server
options (
  service 'cloudwatch',
  object 'metrics'
);

select * from aws_cloudwatch_metrics where namespace = 'AWS/EC2';

-- Query metric data
create foreign table ec2_cpu_utilization (
  timestamp timestamptz,
  value float8,
  unit text
)
server aws_server
options (
  service 'cloudwatch',
  object 'metric_data',
  namespace 'AWS/EC2',
  metric_name 'CPUUtilization'
);

select * from ec2_cpu_utilization
where timestamp > now() - interval '1 hour';
```

## Implementation Tasks

### Phase 1: Complete Implementation

#### Foundation
- [ ] Set up project structure (Cargo.toml, wit/world.wit)
- [ ] Implement AWS Signature V4 authentication
- [ ] Create base AWS HTTP client using WIT http interface
- [ ] Implement FDW lifecycle methods (init, begin_scan, iter_scan, end_scan)
- [ ] Add error handling and reporting via WIT utils

#### S3 Service
- [ ] Implement ListBuckets
- [ ] Implement ListObjectsV2 with prefix filtering
- [ ] Implement HeadObject for metadata
- [ ] Add pagination support for large result sets

#### Lambda Service
- [ ] Implement ListFunctions
- [ ] Implement GetFunction for details
- [ ] Add pagination support

#### CloudWatch Service
- [ ] Implement ListMetrics
- [ ] Implement GetMetricData
- [ ] Add time range filtering
- [ ] Support metric statistics (Average, Sum, etc.)

#### Testing & Documentation
- [ ] Integration tests with LocalStack
- [ ] Documentation for each service
- [ ] Example SQL scripts
- [ ] Performance benchmarking

#### Release
- [ ] Build WASM component
- [ ] Calculate SHA256 checksum
- [ ] Create GitHub release
- [ ] Update docs/catalog with AWS FDW entry

## Technical Considerations

### WASM Limitations

1. **No AWS SDK**: WASM cannot use the official AWS SDK; must implement HTTP calls manually
2. **Cryptography**: Need pure-Rust crypto libraries (hmac, sha2) for signing
3. **No File System**: Cannot cache credentials or responses locally
4. **Single-threaded**: All operations are synchronous from FDW perspective

### Security

1. **Credentials**: Support Vault secrets for secure credential storage
2. **Minimal Permissions**: Document IAM policies with least-privilege access
3. **No Credential Logging**: Never log or expose credentials in errors
4. **Read-Only Design**: No write operations to minimize blast radius

### Performance

1. **Pagination**: Implement efficient pagination for large datasets
2. **Connection Reuse**: Leverage HTTP connection pooling in host
3. **Caching**: Consider result caching strategies for repeated queries

## Dependencies Analysis

| Dependency | Version | Purpose | WASM Compatible |
|------------|---------|---------|-----------------|
| wit-bindgen-rt | 0.41.0 | WIT bindings runtime | Yes |
| serde | 1.0 | Serialization | Yes |
| serde_json | 1.0 | JSON parsing | Yes |
| chrono | 0.4 | Date/time handling | Yes (no-std) |
| hmac | 0.12 | HMAC for AWS signing | Yes |
| sha2 | 0.10 | SHA256 for AWS signing | Yes |
| hex | 0.4 | Hex encoding | Yes |
| urlencoding | 2.1 | URL encoding | Yes |

## References

- [AWS Signature Version 4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html)
- [Existing WASM wrappers](../../fdw/) - snowflake_fdw, paddle_fdw
- [Native AWS wrappers](../../../wrappers/src/fdw/) - s3_fdw, cognito_fdw, s3vectors_fdw
- [WIT v2 Interface](../../wit/v2/)
- [WASM Wrapper Development Guide](../../../docs/guides/create-wasm-wrapper.md)

## Success Criteria

1. All services (S3, Lambda, CloudWatch) working in read-only mode
2. Proper error handling and user-friendly error messages
3. Documentation with examples for each service
4. Integration tests passing
5. Security tests passing (see test-plan.md)
6. Published to GitHub releases with checksum
