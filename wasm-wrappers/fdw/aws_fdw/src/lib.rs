#[allow(warnings)]
mod bindings;

use bindings::{
    exports::supabase::wrappers::routines::Guest,
    supabase::wrappers::{
        http, stats, time,
        types::{
            Cell, Context, FdwError, FdwResult, ImportForeignSchemaStmt,
            ImportSchemaType, OptionsType, Row, Value,
        },
        utils,
    },
};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

// ============================================================================
// AWS Signature V4 Implementation
// ============================================================================

type HmacSha256 = Hmac<Sha256>;

fn sha256_hash(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn get_signature_key(secret_key: &str, date_stamp: &str, region: &str, service: &str) -> Vec<u8> {
    let k_date = hmac_sha256(format!("AWS4{}", secret_key).as_bytes(), date_stamp.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

fn url_encode(s: &str, encode_slash: bool) -> String {
    let mut result = String::new();
    for c in s.chars() {
        match c {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => result.push(c),
            '/' if !encode_slash => result.push(c),
            _ => {
                for b in c.to_string().as_bytes() {
                    result.push_str(&format!("%{:02X}", b));
                }
            }
        }
    }
    result
}

struct SignedRequest {
    headers: Vec<(String, String)>,
}

fn sign_request(
    method: &str,
    url: &str,
    headers: &[(String, String)],
    payload: &[u8],
    access_key: &str,
    secret_key: &str,
    region: &str,
    service: &str,
) -> SignedRequest {
    // Parse URL
    let url_parts: Vec<&str> = url.splitn(2, "://").collect();
    let rest = url_parts.get(1).unwrap_or(&"");
    let (host_and_path, _) = rest.split_once('?').unwrap_or((rest, ""));
    let (host, path) = host_and_path.split_once('/').unwrap_or((host_and_path, ""));
    let canonical_uri = if path.is_empty() {
        "/".to_string()
    } else {
        format!("/{}", url_encode(path, false))
    };

    // Extract query string
    let query_string = if url.contains('?') {
        url.split('?').nth(1).unwrap_or("")
    } else {
        ""
    };

    // Sort query parameters
    let canonical_querystring = if query_string.is_empty() {
        String::new()
    } else {
        let mut params: Vec<(&str, &str)> = query_string
            .split('&')
            .filter_map(|p| {
                let mut parts = p.splitn(2, '=');
                Some((parts.next()?, parts.next().unwrap_or("")))
            })
            .collect();
        params.sort_by(|a, b| a.0.cmp(b.0));
        params
            .iter()
            .map(|(k, v)| format!("{}={}", url_encode(k, true), url_encode(v, true)))
            .collect::<Vec<_>>()
            .join("&")
    };

    // Get current time (seconds since Unix epoch)
    let now_secs = time::epoch_secs();
    let amz_date = format_amz_date(now_secs);
    let date_stamp = &amz_date[..8];

    // Payload hash
    let payload_hash = sha256_hash(payload);

    // Build headers
    let mut all_headers: Vec<(String, String)> = headers.to_vec();
    all_headers.push(("host".to_string(), host.to_string()));
    all_headers.push(("x-amz-date".to_string(), amz_date.clone()));
    all_headers.push(("x-amz-content-sha256".to_string(), payload_hash.clone()));

    // Sort headers
    all_headers.sort_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));

    // Canonical headers
    let canonical_headers: String = all_headers
        .iter()
        .map(|(k, v)| format!("{}:{}\n", k.to_lowercase(), v.trim()))
        .collect();

    let signed_headers: String = all_headers
        .iter()
        .map(|(k, _)| k.to_lowercase())
        .collect::<Vec<_>>()
        .join(";");

    // Canonical request
    let canonical_request = format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        method, canonical_uri, canonical_querystring, canonical_headers, signed_headers, payload_hash
    );

    let canonical_request_hash = sha256_hash(canonical_request.as_bytes());

    // String to sign
    let credential_scope = format!("{}/{}/{}/aws4_request", date_stamp, region, service);
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{}\n{}\n{}",
        amz_date, credential_scope, canonical_request_hash
    );

    // Calculate signature
    let signing_key = get_signature_key(secret_key, date_stamp, region, service);
    let signature = hex::encode(hmac_sha256(&signing_key, string_to_sign.as_bytes()));

    // Authorization header
    let authorization = format!(
        "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
        access_key, credential_scope, signed_headers, signature
    );

    let mut result_headers = all_headers;
    result_headers.push(("authorization".to_string(), authorization));

    SignedRequest {
        headers: result_headers,
    }
}

fn format_amz_date(secs: i64) -> String {
    // Convert Unix timestamp to ISO 8601 format: YYYYMMDD'T'HHMMSS'Z'
    const SECS_PER_DAY: i64 = 86400;
    const SECS_PER_HOUR: i64 = 3600;
    const SECS_PER_MIN: i64 = 60;

    let days = secs / SECS_PER_DAY;
    let remaining = secs % SECS_PER_DAY;
    let hours = remaining / SECS_PER_HOUR;
    let remaining = remaining % SECS_PER_HOUR;
    let minutes = remaining / SECS_PER_MIN;
    let seconds = remaining % SECS_PER_MIN;

    // Calculate year, month, day from days since epoch (1970-01-01)
    let (year, month, day) = days_to_ymd(days);

    format!(
        "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn days_to_ymd(days: i64) -> (i64, u32, u32) {
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d)
}

// ============================================================================
// S3 XML Parsing
// ============================================================================

fn extract_xml_value(xml: &str, tag: &str) -> Option<String> {
    let start_tag = format!("<{}>", tag);
    let end_tag = format!("</{}>", tag);

    let start = xml.find(&start_tag)? + start_tag.len();
    let end = xml[start..].find(&end_tag)? + start;

    Some(xml[start..end].to_string())
}

fn extract_xml_elements(xml: &str, tag: &str) -> Vec<String> {
    let start_tag = format!("<{}>", tag);
    let end_tag = format!("</{}>", tag);
    let mut elements = Vec::new();
    let mut search_start = 0;

    while let Some(start) = xml[search_start..].find(&start_tag) {
        let abs_start = search_start + start;
        if let Some(end) = xml[abs_start..].find(&end_tag) {
            let element_end = abs_start + end + end_tag.len();
            elements.push(xml[abs_start..element_end].to_string());
            search_start = element_end;
        } else {
            break;
        }
    }

    elements
}

// ============================================================================
// S3 Data Structures
// ============================================================================

#[derive(Debug, Clone)]
struct S3Bucket {
    name: String,
    creation_date: String,
}

#[derive(Debug, Clone)]
struct S3Object {
    bucket: String,
    key: String,
    size: i64,
    last_modified: String,
    etag: String,
    storage_class: String,
}

// ============================================================================
// AWS FDW Implementation
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
enum S3ObjectType {
    Buckets,
    Objects,
}

#[derive(Debug, Default)]
struct AwsFdw {
    // AWS credentials and config
    access_key: String,
    secret_key: String,
    region: String,
    endpoint_url: Option<String>,

    // S3 specific options
    object_type: Option<S3ObjectType>,
    bucket: Option<String>,
    prefix: Option<String>,

    // Scan state
    buckets: Vec<S3Bucket>,
    objects: Vec<S3Object>,
    row_idx: usize,

    // Pagination
    continuation_token: Option<String>,
    is_truncated: bool,
}

static mut INSTANCE: *mut AwsFdw = std::ptr::null_mut::<AwsFdw>();
static FDW_NAME: &str = "AwsFdw";

impl AwsFdw {
    fn init_instance() {
        let instance = Self::default();
        unsafe {
            INSTANCE = Box::leak(Box::new(instance));
        }
    }

    fn this_mut() -> &'static mut Self {
        unsafe { &mut (*INSTANCE) }
    }

    fn get_s3_endpoint(&self) -> String {
        if let Some(ref endpoint) = self.endpoint_url {
            endpoint.clone()
        } else {
            format!("https://s3.{}.amazonaws.com", self.region)
        }
    }

    fn make_s3_request(&self, method: &str, path: &str, query: &str) -> Result<String, FdwError> {
        let endpoint = self.get_s3_endpoint();
        let url = if query.is_empty() {
            format!("{}{}", endpoint, path)
        } else {
            format!("{}{}?{}", endpoint, path, query)
        };

        let signed = sign_request(
            method,
            &url,
            &[],
            &[],
            &self.access_key,
            &self.secret_key,
            &self.region,
            "s3",
        );

        let req = http::Request {
            method: http::Method::Get,
            url: url.clone(),
            headers: signed.headers,
            body: String::new(),
        };

        let resp = http::get(&req)?;
        http::error_for_status(&resp)?;

        stats::inc_stats(FDW_NAME, stats::Metric::BytesIn, resp.body.len() as i64);

        Ok(resp.body)
    }

    fn list_buckets(&mut self) -> Result<(), FdwError> {
        let body = self.make_s3_request("GET", "/", "")?;

        self.buckets.clear();

        for bucket_xml in extract_xml_elements(&body, "Bucket") {
            let name = extract_xml_value(&bucket_xml, "Name").unwrap_or_default();
            let creation_date = extract_xml_value(&bucket_xml, "CreationDate").unwrap_or_default();

            self.buckets.push(S3Bucket { name, creation_date });
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.buckets.len() as i64);

        Ok(())
    }

    fn list_objects(&mut self) -> Result<(), FdwError> {
        let bucket = self.bucket.as_ref().ok_or(
            "Bucket is required. Use WHERE bucket = 'bucket-name' to query objects."
        )?;

        let path = format!("/{}", bucket);
        let mut query_parts = vec!["list-type=2".to_string()];

        if let Some(ref prefix) = self.prefix {
            query_parts.push(format!("prefix={}", url_encode(prefix, true)));
        }

        if let Some(ref token) = self.continuation_token {
            query_parts.push(format!("continuation-token={}", url_encode(token, true)));
        }

        let query = query_parts.join("&");
        let body = self.make_s3_request("GET", &path, &query)?;

        // Parse truncation status
        self.is_truncated = extract_xml_value(&body, "IsTruncated")
            .map(|v| v == "true")
            .unwrap_or(false);

        // Parse continuation token
        self.continuation_token = extract_xml_value(&body, "NextContinuationToken");

        // Parse objects
        let bucket_name = bucket.clone();
        for content_xml in extract_xml_elements(&body, "Contents") {
            let key = extract_xml_value(&content_xml, "Key").unwrap_or_default();
            let size = extract_xml_value(&content_xml, "Size")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let last_modified = extract_xml_value(&content_xml, "LastModified").unwrap_or_default();
            let etag = extract_xml_value(&content_xml, "ETag")
                .map(|s| s.trim_matches('"').to_string())
                .unwrap_or_default();
            let storage_class = extract_xml_value(&content_xml, "StorageClass")
                .unwrap_or_else(|| "STANDARD".to_string());

            self.objects.push(S3Object {
                bucket: bucket_name.clone(),
                key,
                size,
                last_modified,
                etag,
                storage_class,
            });
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.objects.len() as i64);

        Ok(())
    }

    fn parse_iso8601_timestamp(ts: &str) -> Result<i64, FdwError> {
        // Parse ISO 8601 timestamp: 2024-01-15T10:30:00.000Z
        // Returns microseconds since Unix epoch

        if ts.is_empty() {
            return Ok(0);
        }

        // Basic parsing - extract components
        let ts = ts.trim_end_matches('Z');
        let parts: Vec<&str> = ts.split('T').collect();
        if parts.len() != 2 {
            return Err(format!("Invalid timestamp format: {}", ts));
        }

        let date_parts: Vec<i64> = parts[0]
            .split('-')
            .filter_map(|s| s.parse().ok())
            .collect();

        let time_str = parts[1].split('.').next().unwrap_or(parts[1]);
        let time_parts: Vec<i64> = time_str
            .split(':')
            .filter_map(|s| s.parse().ok())
            .collect();

        if date_parts.len() != 3 || time_parts.len() != 3 {
            return Err(format!("Invalid timestamp format: {}", ts));
        }

        let year = date_parts[0];
        let month = date_parts[1] as u32;
        let day = date_parts[2] as u32;
        let hour = time_parts[0];
        let minute = time_parts[1];
        let second = time_parts[2];

        // Convert to days since epoch
        let days = ymd_to_days(year, month, day);
        let secs = days * 86400 + hour * 3600 + minute * 60 + second;

        // Return microseconds
        Ok(secs * 1_000_000)
    }
}

fn ymd_to_days(year: i64, month: u32, day: u32) -> i64 {
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe as i64 - 719468
}

impl Guest for AwsFdw {
    fn host_version_requirement() -> String {
        "^0.1.0".to_string()
    }

    fn init(ctx: &Context) -> FdwResult {
        Self::init_instance();
        let this = Self::this_mut();

        let opts = ctx.get_options(&OptionsType::Server);

        // Get credentials - either direct or from Vault
        this.access_key = match opts.get("aws_access_key_id") {
            Some(key) => key,
            None => {
                let key_id = opts.require("aws_access_key_id_id")?;
                utils::get_vault_secret(&key_id)
                    .ok_or("Failed to get aws_access_key_id from Vault")?
            }
        };

        this.secret_key = match opts.get("aws_secret_access_key") {
            Some(key) => key,
            None => {
                let key_id = opts.require("aws_secret_access_key_id")?;
                utils::get_vault_secret(&key_id)
                    .ok_or("Failed to get aws_secret_access_key from Vault")?
            }
        };

        this.region = opts.require("region")?;
        this.endpoint_url = opts.get("endpoint_url");

        stats::inc_stats(FDW_NAME, stats::Metric::CreateTimes, 1);

        Ok(())
    }

    fn begin_scan(ctx: &Context) -> FdwResult {
        let this = Self::this_mut();
        let opts = ctx.get_options(&OptionsType::Table);

        let service = opts.require("service")?;
        if service != "s3" {
            return Err(format!("Unsupported service: {}. Only 's3' is supported.", service));
        }

        let object = opts.require("object")?;
        this.object_type = Some(match object.as_str() {
            "buckets" => S3ObjectType::Buckets,
            "objects" => S3ObjectType::Objects,
            _ => return Err(format!("Unknown object type: {}. Use 'buckets' or 'objects'.", object)),
        });

        // Reset filters - these will be set from WHERE clause
        this.bucket = None;
        this.prefix = None;

        // Extract bucket and prefix from WHERE clause quals
        // This allows queries like: SELECT * FROM s3_objects WHERE bucket = 'my-bucket'
        for qual in ctx.get_quals() {
            let field = qual.field().to_lowercase();
            let value = match qual.value() {
                Value::Cell(Cell::String(s)) => s,
                _ => continue,
            };

            match field.as_str() {
                "bucket" => {
                    this.bucket = Some(value);
                }
                "prefix" => {
                    this.prefix = Some(value);
                }
                _ => {}
            }
        }

        // Reset scan state
        this.buckets.clear();
        this.objects.clear();
        this.row_idx = 0;
        this.continuation_token = None;
        this.is_truncated = false;

        // Fetch initial data
        match this.object_type {
            Some(S3ObjectType::Buckets) => this.list_buckets()?,
            Some(S3ObjectType::Objects) => this.list_objects()?,
            None => return Err("object type not set".to_string()),
        }

        Ok(())
    }

    fn iter_scan(ctx: &Context, row: &Row) -> Result<Option<u32>, FdwError> {
        let this = Self::this_mut();

        match this.object_type {
            Some(S3ObjectType::Buckets) => {
                if this.row_idx >= this.buckets.len() {
                    return Ok(None);
                }

                let bucket = &this.buckets[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "name" => Some(Cell::String(bucket.name.clone())),
                        "creation_date" => {
                            let ts = Self::parse_iso8601_timestamp(&bucket.creation_date)?;
                            Some(Cell::Timestamp(ts))
                        }
                        _ => None,
                    };
                    row.push(cell.as_ref());
                }

                this.row_idx += 1;
                Ok(Some(0))
            }
            Some(S3ObjectType::Objects) => {
                // Check if we need to fetch more objects
                if this.row_idx >= this.objects.len() {
                    if this.is_truncated && this.continuation_token.is_some() {
                        // Fetch next page
                        this.list_objects()?;
                    } else {
                        return Ok(None);
                    }
                }

                if this.row_idx >= this.objects.len() {
                    return Ok(None);
                }

                let object = &this.objects[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "bucket" => Some(Cell::String(object.bucket.clone())),
                        "key" => Some(Cell::String(object.key.clone())),
                        "size" => Some(Cell::I64(object.size)),
                        "last_modified" => {
                            let ts = Self::parse_iso8601_timestamp(&object.last_modified)?;
                            Some(Cell::Timestamp(ts))
                        }
                        "etag" => Some(Cell::String(object.etag.clone())),
                        "storage_class" => Some(Cell::String(object.storage_class.clone())),
                        _ => None,
                    };
                    row.push(cell.as_ref());
                }

                this.row_idx += 1;
                Ok(Some(0))
            }
            None => Err("object type not set".to_string()),
        }
    }

    fn re_scan(_ctx: &Context) -> FdwResult {
        let this = Self::this_mut();

        // Reset state and re-fetch
        this.buckets.clear();
        this.objects.clear();
        this.row_idx = 0;
        this.continuation_token = None;
        this.is_truncated = false;

        match this.object_type {
            Some(S3ObjectType::Buckets) => this.list_buckets()?,
            Some(S3ObjectType::Objects) => this.list_objects()?,
            None => return Err("object type not set".to_string()),
        }

        Ok(())
    }

    fn end_scan(_ctx: &Context) -> FdwResult {
        let this = Self::this_mut();
        this.buckets.clear();
        this.objects.clear();
        this.row_idx = 0;
        Ok(())
    }

    fn begin_modify(_ctx: &Context) -> FdwResult {
        Err("modify on foreign table is not supported (read-only)".to_owned())
    }

    fn insert(_ctx: &Context, _row: &Row) -> FdwResult {
        Err("insert is not supported (read-only)".to_owned())
    }

    fn update(_ctx: &Context, _rowid: Cell, _row: &Row) -> FdwResult {
        Err("update is not supported (read-only)".to_owned())
    }

    fn delete(_ctx: &Context, _rowid: Cell) -> FdwResult {
        Err("delete is not supported (read-only)".to_owned())
    }

    fn end_modify(_ctx: &Context) -> FdwResult {
        Ok(())
    }

    fn import_foreign_schema(
        _ctx: &Context,
        stmt: ImportForeignSchemaStmt,
    ) -> Result<Vec<String>, FdwError> {
        let mut tables = Vec::new();

        // Define available tables for S3
        let s3_tables = vec![
            ("buckets", r#"create foreign table if not exists s3_buckets (
    name text,
    creation_date timestamp
)
server {} options (
    service 's3',
    object 'buckets'
)"#),
            ("objects", r#"create foreign table if not exists s3_objects (
    bucket text,
    key text,
    size bigint,
    last_modified timestamp,
    etag text,
    storage_class text
)
server {} options (
    service 's3',
    object 'objects'
)"#),
        ];

        // Determine which tables to create based on remote_schema
        let available_tables: Vec<(&str, &str)> = match stmt.remote_schema.as_str() {
            "s3" => s3_tables,
            "all" => s3_tables,
            _ => {
                return Err(format!(
                    "Unknown schema '{}'. Use: 's3' or 'all'",
                    stmt.remote_schema
                ))
            }
        };

        // Apply LIMIT TO / EXCEPT filtering
        let table_list: Vec<String> = stmt.table_list.iter().map(|s| s.to_lowercase()).collect();

        for (table_name, ddl_template) in available_tables {
            let include = match stmt.list_type {
                ImportSchemaType::All => true,
                ImportSchemaType::LimitTo => table_list.contains(&table_name.to_lowercase()),
                ImportSchemaType::Except => !table_list.contains(&table_name.to_lowercase()),
            };

            if include {
                let ddl = ddl_template.replace("{}", &stmt.server_name);
                tables.push(ddl);
            }
        }

        Ok(tables)
    }
}

bindings::export!(AwsFdw with_types_in bindings);
