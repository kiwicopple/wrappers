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
// XML Parsing Helpers
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
// JSON Parsing Helpers
// ============================================================================

fn extract_json_string(json: &str, key: &str) -> Option<String> {
    // Find "key": "value" pattern
    let key_pattern = format!("\"{}\"", key);
    let key_pos = json.find(&key_pattern)?;

    // Find the colon after the key
    let after_key = &json[key_pos + key_pattern.len()..];
    let colon_pos = after_key.find(':')?;
    let after_colon = &after_key[colon_pos + 1..];

    // Skip whitespace and find opening quote
    let trimmed = after_colon.trim_start();
    if !trimmed.starts_with('"') {
        return None;
    }

    // Find closing quote (handling escaped quotes)
    let value_start = 1; // Skip opening quote
    let chars: Vec<char> = trimmed.chars().collect();
    let mut i = value_start;
    let mut escaped = false;

    while i < chars.len() {
        if escaped {
            escaped = false;
        } else if chars[i] == '\\' {
            escaped = true;
        } else if chars[i] == '"' {
            // Found closing quote
            let value: String = chars[value_start..i].iter().collect();
            // Unescape the string
            return Some(value.replace("\\\"", "\"").replace("\\\\", "\\"));
        }
        i += 1;
    }

    None
}

fn extract_json_number(json: &str, key: &str) -> Option<i64> {
    // Find "key": number pattern
    let key_pattern = format!("\"{}\"", key);
    let key_pos = json.find(&key_pattern)?;

    // Find the colon after the key
    let after_key = &json[key_pos + key_pattern.len()..];
    let colon_pos = after_key.find(':')?;
    let after_colon = &after_key[colon_pos + 1..];

    // Skip whitespace and collect digits
    let trimmed = after_colon.trim_start();
    let num_end = trimmed.find(|c: char| !c.is_ascii_digit() && c != '-').unwrap_or(trimmed.len());
    let num_str = &trimmed[..num_end];

    num_str.parse().ok()
}

fn find_json_array_end(json: &str) -> Option<usize> {
    // Find matching ] for [ at position 0
    let mut depth = 0;
    let mut in_string = false;
    let mut escaped = false;

    for (i, c) in json.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }

        match c {
            '\\' if in_string => escaped = true,
            '"' => in_string = !in_string,
            '[' if !in_string => depth += 1,
            ']' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }

    None
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
// EC2 Data Structures
// ============================================================================

#[derive(Debug, Clone)]
struct Ec2Instance {
    instance_id: String,
    instance_type: String,
    state: String,
    public_ip: Option<String>,
    private_ip: Option<String>,
    vpc_id: Option<String>,
    subnet_id: Option<String>,
    launch_time: String,
    tags: String, // JSON string
}

// ============================================================================
// Lambda Data Structures
// ============================================================================

#[derive(Debug, Clone)]
struct LambdaFunction {
    function_name: String,
    function_arn: String,
    runtime: String,
    handler: String,
    code_size: i64,
    memory_size: i32,
    timeout: i32,
    last_modified: String,
    description: String,
    state: String,
}

// ============================================================================
// Route53 Data Structures
// ============================================================================

#[derive(Debug, Clone)]
struct Route53HostedZone {
    id: String,
    name: String,
    caller_reference: String,
    resource_record_set_count: i64,
    comment: String,
    is_private: bool,
}

#[derive(Debug, Clone)]
struct Route53Record {
    zone_id: String,
    name: String,
    record_type: String,
    ttl: i64,
    values: String, // JSON array of values
    alias_target: Option<String>,
    weight: Option<i64>,
    set_identifier: Option<String>,
}

// ============================================================================
// AWS FDW Implementation
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
enum AwsService {
    S3,
    Ec2,
    Lambda,
    Route53,
}

#[derive(Debug, Clone, PartialEq)]
enum ObjectType {
    // S3
    S3Buckets,
    S3Objects,
    // EC2
    Ec2Instances,
    // Lambda
    LambdaFunctions,
    // Route53
    Route53HostedZones,
    Route53Records,
}

#[derive(Debug, Default)]
struct AwsFdw {
    // AWS credentials and config
    access_key: String,
    secret_key: String,
    region: String,
    endpoint_url: Option<String>,

    // Current service and object type
    service: Option<AwsService>,
    object_type: Option<ObjectType>,

    // S3 specific options
    bucket: Option<String>,
    prefix: Option<String>,

    // EC2 specific options
    instance_id: Option<String>,

    // Lambda specific options
    function_name: Option<String>,

    // Route53 specific options
    zone_id: Option<String>,

    // Scan state - S3
    buckets: Vec<S3Bucket>,
    objects: Vec<S3Object>,

    // Scan state - EC2
    instances: Vec<Ec2Instance>,

    // Scan state - Lambda
    functions: Vec<LambdaFunction>,

    // Scan state - Route53
    hosted_zones: Vec<Route53HostedZone>,
    records: Vec<Route53Record>,

    // Common scan state
    row_idx: usize,

    // Pagination
    next_token: Option<String>,
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

    // ========================================================================
    // S3 Methods
    // ========================================================================

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

        if let Some(ref token) = self.next_token {
            query_parts.push(format!("continuation-token={}", url_encode(token, true)));
        }

        let query = query_parts.join("&");
        let body = self.make_s3_request("GET", &path, &query)?;

        // Parse truncation status
        self.is_truncated = extract_xml_value(&body, "IsTruncated")
            .map(|v| v == "true")
            .unwrap_or(false);

        // Parse continuation token
        self.next_token = extract_xml_value(&body, "NextContinuationToken");

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

    // ========================================================================
    // EC2 Methods
    // ========================================================================

    fn get_ec2_endpoint(&self) -> String {
        if let Some(ref endpoint) = self.endpoint_url {
            endpoint.clone()
        } else {
            format!("https://ec2.{}.amazonaws.com", self.region)
        }
    }

    fn make_ec2_request(&self, action: &str, extra_params: &[(&str, &str)]) -> Result<String, FdwError> {
        let endpoint = self.get_ec2_endpoint();

        // Build query string
        let mut params: Vec<(String, String)> = vec![
            ("Action".to_string(), action.to_string()),
            ("Version".to_string(), "2016-11-15".to_string()),
        ];

        for (k, v) in extra_params {
            params.push((k.to_string(), v.to_string()));
        }

        // Sort params for signing
        params.sort_by(|a, b| a.0.cmp(&b.0));

        let query = params
            .iter()
            .map(|(k, v)| format!("{}={}", url_encode(k, true), url_encode(v, true)))
            .collect::<Vec<_>>()
            .join("&");

        let url = format!("{}/?{}", endpoint, query);

        let signed = sign_request(
            "GET",
            &url,
            &[],
            &[],
            &self.access_key,
            &self.secret_key,
            &self.region,
            "ec2",
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

    fn describe_instances(&mut self) -> Result<(), FdwError> {
        let mut extra_params: Vec<(&str, &str)> = Vec::new();

        // Filter by instance ID if provided
        if let Some(ref instance_id) = self.instance_id {
            extra_params.push(("InstanceId.1", instance_id.as_str()));
        }

        // Add next token for pagination
        let next_token_string;
        if let Some(ref token) = self.next_token {
            next_token_string = token.clone();
            extra_params.push(("NextToken", &next_token_string));
        }

        let body = self.make_ec2_request("DescribeInstances", &extra_params)?;

        // Parse next token
        self.next_token = extract_xml_value(&body, "nextToken");
        self.is_truncated = self.next_token.is_some();

        // Parse instances from reservationSet/item/instancesSet/item
        for reservation_xml in extract_xml_elements(&body, "item") {
            // Check if this is a reservation (has instancesSet)
            if !reservation_xml.contains("<instancesSet>") {
                continue;
            }

            for instance_xml in extract_xml_elements(&reservation_xml, "item") {
                // Skip if this doesn't look like an instance (must have instanceId)
                let instance_id = match extract_xml_value(&instance_xml, "instanceId") {
                    Some(id) => id,
                    None => continue,
                };

                let instance_type = extract_xml_value(&instance_xml, "instanceType")
                    .unwrap_or_default();

                // Parse instance state
                let state = extract_xml_value(&instance_xml, "instanceState")
                    .and_then(|state_xml| extract_xml_value(&state_xml, "name"))
                    .unwrap_or_default();

                let public_ip = extract_xml_value(&instance_xml, "ipAddress");
                let private_ip = extract_xml_value(&instance_xml, "privateIpAddress");
                let vpc_id = extract_xml_value(&instance_xml, "vpcId");
                let subnet_id = extract_xml_value(&instance_xml, "subnetId");
                let launch_time = extract_xml_value(&instance_xml, "launchTime")
                    .unwrap_or_default();

                // Parse tags into JSON
                let tags = self.parse_ec2_tags(&instance_xml);

                self.instances.push(Ec2Instance {
                    instance_id,
                    instance_type,
                    state,
                    public_ip,
                    private_ip,
                    vpc_id,
                    subnet_id,
                    launch_time,
                    tags,
                });
            }
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.instances.len() as i64);

        Ok(())
    }

    fn parse_ec2_tags(&self, instance_xml: &str) -> String {
        let mut tags_json = String::from("{");
        let mut first = true;

        if let Some(tag_set_start) = instance_xml.find("<tagSet>") {
            if let Some(tag_set_end) = instance_xml[tag_set_start..].find("</tagSet>") {
                let tag_set_xml = &instance_xml[tag_set_start..tag_set_start + tag_set_end + 9];

                for tag_xml in extract_xml_elements(tag_set_xml, "item") {
                    if let (Some(key), Some(value)) = (
                        extract_xml_value(&tag_xml, "key"),
                        extract_xml_value(&tag_xml, "value"),
                    ) {
                        if !first {
                            tags_json.push(',');
                        }
                        first = false;
                        // Escape JSON string values
                        let escaped_key = key.replace('\\', "\\\\").replace('"', "\\\"");
                        let escaped_value = value.replace('\\', "\\\\").replace('"', "\\\"");
                        tags_json.push_str(&format!("\"{}\":\"{}\"", escaped_key, escaped_value));
                    }
                }
            }
        }

        tags_json.push('}');
        tags_json
    }

    // ========================================================================
    // Lambda Methods
    // ========================================================================

    fn get_lambda_endpoint(&self) -> String {
        if let Some(ref endpoint) = self.endpoint_url {
            endpoint.clone()
        } else {
            format!("https://lambda.{}.amazonaws.com", self.region)
        }
    }

    fn make_lambda_request(&self, path: &str, query: &str) -> Result<String, FdwError> {
        let endpoint = self.get_lambda_endpoint();
        let url = if query.is_empty() {
            format!("{}{}", endpoint, path)
        } else {
            format!("{}{}?{}", endpoint, path, query)
        };

        let signed = sign_request(
            "GET",
            &url,
            &[],
            &[],
            &self.access_key,
            &self.secret_key,
            &self.region,
            "lambda",
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

    fn list_functions(&mut self) -> Result<(), FdwError> {
        let path = "/2015-03-31/functions";
        let mut query_parts: Vec<String> = Vec::new();

        if let Some(ref token) = self.next_token {
            query_parts.push(format!("Marker={}", url_encode(token, true)));
        }

        let query = query_parts.join("&");
        let body = self.make_lambda_request(path, &query)?;

        // Parse JSON response
        // Lambda ListFunctions returns JSON like:
        // {"Functions": [...], "NextMarker": "..."}

        // Parse NextMarker for pagination
        self.next_token = extract_json_string(&body, "NextMarker");
        self.is_truncated = self.next_token.is_some();

        // Parse functions array
        if let Some(functions_start) = body.find("\"Functions\"") {
            if let Some(arr_start) = body[functions_start..].find('[') {
                let arr_start_abs = functions_start + arr_start;
                if let Some(arr_end) = find_json_array_end(&body[arr_start_abs..]) {
                    let functions_json = &body[arr_start_abs..arr_start_abs + arr_end + 1];
                    self.parse_lambda_functions(functions_json)?;
                }
            }
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.functions.len() as i64);

        Ok(())
    }

    fn parse_lambda_functions(&mut self, json: &str) -> Result<(), FdwError> {
        // Simple JSON array parsing for function objects
        let mut depth = 0;
        let mut obj_start = None;
        let chars: Vec<char> = json.chars().collect();

        for (i, &c) in chars.iter().enumerate() {
            match c {
                '{' => {
                    if depth == 1 {
                        obj_start = Some(i);
                    }
                    depth += 1;
                }
                '}' => {
                    depth -= 1;
                    if depth == 1 {
                        if let Some(start) = obj_start {
                            let obj_json: String = chars[start..=i].iter().collect();
                            let func = self.parse_single_function(&obj_json);
                            self.functions.push(func);
                        }
                        obj_start = None;
                    }
                }
                '[' if depth == 0 => depth = 1,
                ']' if depth == 1 => break,
                _ => {}
            }
        }

        Ok(())
    }

    fn parse_single_function(&self, json: &str) -> LambdaFunction {
        LambdaFunction {
            function_name: extract_json_string(json, "FunctionName").unwrap_or_default(),
            function_arn: extract_json_string(json, "FunctionArn").unwrap_or_default(),
            runtime: extract_json_string(json, "Runtime").unwrap_or_default(),
            handler: extract_json_string(json, "Handler").unwrap_or_default(),
            code_size: extract_json_number(json, "CodeSize").unwrap_or(0),
            memory_size: extract_json_number(json, "MemorySize").unwrap_or(0) as i32,
            timeout: extract_json_number(json, "Timeout").unwrap_or(0) as i32,
            last_modified: extract_json_string(json, "LastModified").unwrap_or_default(),
            description: extract_json_string(json, "Description").unwrap_or_default(),
            state: extract_json_string(json, "State").unwrap_or_else(|| "Active".to_string()),
        }
    }

    // ========================================================================
    // Route53 Methods
    // ========================================================================

    fn get_route53_endpoint(&self) -> String {
        if let Some(ref endpoint) = self.endpoint_url {
            endpoint.clone()
        } else {
            // Route53 has a global endpoint
            "https://route53.amazonaws.com".to_string()
        }
    }

    fn make_route53_request(&self, path: &str) -> Result<String, FdwError> {
        let endpoint = self.get_route53_endpoint();
        let url = format!("{}{}", endpoint, path);

        let signed = sign_request(
            "GET",
            &url,
            &[],
            &[],
            &self.access_key,
            &self.secret_key,
            &self.region,
            "route53",
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

    fn list_hosted_zones(&mut self) -> Result<(), FdwError> {
        let mut path = "/2013-04-01/hostedzone".to_string();

        if let Some(ref token) = self.next_token {
            path = format!("{}?marker={}", path, url_encode(token, true));
        }

        let body = self.make_route53_request(&path)?;

        // Parse pagination
        self.is_truncated = extract_xml_value(&body, "IsTruncated")
            .map(|v| v == "true")
            .unwrap_or(false);
        self.next_token = extract_xml_value(&body, "NextMarker");

        // Parse hosted zones
        for zone_xml in extract_xml_elements(&body, "HostedZone") {
            let id = extract_xml_value(&zone_xml, "Id")
                .unwrap_or_default()
                .replace("/hostedzone/", "");
            let name = extract_xml_value(&zone_xml, "Name").unwrap_or_default();
            let caller_reference = extract_xml_value(&zone_xml, "CallerReference").unwrap_or_default();
            let resource_record_set_count = extract_xml_value(&zone_xml, "ResourceRecordSetCount")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);

            // Parse Config for comment and private zone
            let comment = extract_xml_value(&zone_xml, "Comment").unwrap_or_default();
            let is_private = extract_xml_value(&zone_xml, "PrivateZone")
                .map(|v| v == "true")
                .unwrap_or(false);

            self.hosted_zones.push(Route53HostedZone {
                id,
                name,
                caller_reference,
                resource_record_set_count,
                comment,
                is_private,
            });
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.hosted_zones.len() as i64);

        Ok(())
    }

    fn list_resource_record_sets(&mut self) -> Result<(), FdwError> {
        let zone_id = self.zone_id.as_ref().ok_or(
            "Zone ID is required. Use WHERE zone_id = 'ZONE_ID' to query records."
        )?;

        let mut path = format!("/2013-04-01/hostedzone/{}/rrset", zone_id);

        if let Some(ref token) = self.next_token {
            path = format!("{}?startrecordname={}", path, url_encode(token, true));
        }

        let body = self.make_route53_request(&path)?;

        // Parse pagination
        self.is_truncated = extract_xml_value(&body, "IsTruncated")
            .map(|v| v == "true")
            .unwrap_or(false);
        self.next_token = extract_xml_value(&body, "NextRecordName");

        // Parse resource record sets
        let zone_id_clone = zone_id.clone();
        for rrset_xml in extract_xml_elements(&body, "ResourceRecordSet") {
            let name = extract_xml_value(&rrset_xml, "Name").unwrap_or_default();
            let record_type = extract_xml_value(&rrset_xml, "Type").unwrap_or_default();
            let ttl = extract_xml_value(&rrset_xml, "TTL")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);

            // Parse resource records into JSON array
            let values = self.parse_resource_records(&rrset_xml);

            // Parse alias target if present
            let alias_target = if rrset_xml.contains("<AliasTarget>") {
                let dns_name = extract_xml_value(&rrset_xml, "DNSName");
                let hosted_zone_id = extract_xml_value(&rrset_xml, "HostedZoneId");
                match (dns_name, hosted_zone_id) {
                    (Some(dns), Some(hz)) => Some(format!("{{\"DNSName\":\"{}\",\"HostedZoneId\":\"{}\"}}", dns, hz)),
                    _ => None,
                }
            } else {
                None
            };

            let weight = extract_xml_value(&rrset_xml, "Weight")
                .and_then(|s| s.parse().ok());
            let set_identifier = extract_xml_value(&rrset_xml, "SetIdentifier");

            self.records.push(Route53Record {
                zone_id: zone_id_clone.clone(),
                name,
                record_type,
                ttl,
                values,
                alias_target,
                weight,
                set_identifier,
            });
        }

        stats::inc_stats(FDW_NAME, stats::Metric::RowsIn, self.records.len() as i64);

        Ok(())
    }

    fn parse_resource_records(&self, rrset_xml: &str) -> String {
        let mut values = Vec::new();

        for rr_xml in extract_xml_elements(rrset_xml, "ResourceRecord") {
            if let Some(value) = extract_xml_value(&rr_xml, "Value") {
                // Escape JSON string
                let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
                values.push(format!("\"{}\"", escaped));
            }
        }

        format!("[{}]", values.join(","))
    }

    // ========================================================================
    // Common Methods
    // ========================================================================

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

    fn parse_lambda_timestamp(ts: &str) -> Result<i64, FdwError> {
        // Lambda uses format: 2024-01-15T10:30:00.000+0000
        // We'll parse the main part and ignore timezone (treat as UTC)
        if ts.is_empty() {
            return Ok(0);
        }

        // Remove timezone suffix (e.g., +0000)
        let ts = if let Some(plus_pos) = ts.rfind('+') {
            &ts[..plus_pos]
        } else if let Some(minus_pos) = ts.rfind('-') {
            // Check if this is actually in the date part (not timezone)
            if minus_pos > 10 {
                &ts[..minus_pos]
            } else {
                ts
            }
        } else {
            ts
        };

        // Now parse like ISO8601
        Self::parse_iso8601_timestamp(ts)
    }

    fn reset_scan_state(&mut self) {
        self.buckets.clear();
        self.objects.clear();
        self.instances.clear();
        self.functions.clear();
        self.hosted_zones.clear();
        self.records.clear();
        self.row_idx = 0;
        self.next_token = None;
        self.is_truncated = false;
    }

    fn fetch_data(&mut self) -> Result<(), FdwError> {
        match self.object_type {
            Some(ObjectType::S3Buckets) => self.list_buckets(),
            Some(ObjectType::S3Objects) => self.list_objects(),
            Some(ObjectType::Ec2Instances) => self.describe_instances(),
            Some(ObjectType::LambdaFunctions) => self.list_functions(),
            Some(ObjectType::Route53HostedZones) => self.list_hosted_zones(),
            Some(ObjectType::Route53Records) => self.list_resource_record_sets(),
            None => Err("object type not set".to_string()),
        }
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

        // Reset filters
        this.bucket = None;
        this.prefix = None;
        this.instance_id = None;
        this.function_name = None;
        this.zone_id = None;

        // Parse service and object type
        match service.as_str() {
            "s3" => {
                this.service = Some(AwsService::S3);
                let object = opts.require("object")?;
                this.object_type = Some(match object.as_str() {
                    "buckets" => ObjectType::S3Buckets,
                    "objects" => ObjectType::S3Objects,
                    _ => return Err(format!("Unknown S3 object type: {}. Use 'buckets' or 'objects'.", object)),
                });
            }
            "ec2" => {
                this.service = Some(AwsService::Ec2);
                let object = opts.require("object")?;
                this.object_type = Some(match object.as_str() {
                    "instances" => ObjectType::Ec2Instances,
                    _ => return Err(format!("Unknown EC2 object type: {}. Use 'instances'.", object)),
                });
            }
            "lambda" => {
                this.service = Some(AwsService::Lambda);
                let object = opts.require("object")?;
                this.object_type = Some(match object.as_str() {
                    "functions" => ObjectType::LambdaFunctions,
                    _ => return Err(format!("Unknown Lambda object type: {}. Use 'functions'.", object)),
                });
            }
            "route53" => {
                this.service = Some(AwsService::Route53);
                let object = opts.require("object")?;
                this.object_type = Some(match object.as_str() {
                    "hosted_zones" => ObjectType::Route53HostedZones,
                    "records" => ObjectType::Route53Records,
                    _ => return Err(format!("Unknown Route53 object type: {}. Use 'hosted_zones' or 'records'.", object)),
                });
            }
            _ => return Err(format!("Unsupported service: {}. Use 's3', 'ec2', 'lambda', or 'route53'.", service)),
        }

        // Extract filters from WHERE clause quals
        for qual in ctx.get_quals() {
            let field = qual.field().to_lowercase();
            let value = match qual.value() {
                Value::Cell(Cell::String(s)) => s,
                _ => continue,
            };

            match field.as_str() {
                // S3 filters
                "bucket" => this.bucket = Some(value),
                "prefix" => this.prefix = Some(value),
                // EC2 filters
                "instance_id" => this.instance_id = Some(value),
                // Lambda filters
                "function_name" => this.function_name = Some(value),
                // Route53 filters
                "zone_id" => this.zone_id = Some(value),
                _ => {}
            }
        }

        // Reset scan state and fetch initial data
        this.reset_scan_state();
        this.fetch_data()?;

        Ok(())
    }

    fn iter_scan(ctx: &Context, row: &Row) -> Result<Option<u32>, FdwError> {
        let this = Self::this_mut();

        match this.object_type {
            Some(ObjectType::S3Buckets) => {
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
            Some(ObjectType::S3Objects) => {
                // Check if we need to fetch more objects
                if this.row_idx >= this.objects.len() {
                    if this.is_truncated && this.next_token.is_some() {
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
            Some(ObjectType::Ec2Instances) => {
                // Check if we need to fetch more instances
                if this.row_idx >= this.instances.len() {
                    if this.is_truncated && this.next_token.is_some() {
                        this.describe_instances()?;
                    } else {
                        return Ok(None);
                    }
                }

                if this.row_idx >= this.instances.len() {
                    return Ok(None);
                }

                let instance = &this.instances[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "instance_id" => Some(Cell::String(instance.instance_id.clone())),
                        "instance_type" => Some(Cell::String(instance.instance_type.clone())),
                        "state" => Some(Cell::String(instance.state.clone())),
                        "public_ip" => instance.public_ip.clone().map(Cell::String),
                        "private_ip" => instance.private_ip.clone().map(Cell::String),
                        "vpc_id" => instance.vpc_id.clone().map(Cell::String),
                        "subnet_id" => instance.subnet_id.clone().map(Cell::String),
                        "launch_time" => {
                            let ts = Self::parse_iso8601_timestamp(&instance.launch_time)?;
                            Some(Cell::Timestamp(ts))
                        }
                        "tags" => Some(Cell::Json(instance.tags.clone())),
                        _ => None,
                    };
                    row.push(cell.as_ref());
                }

                this.row_idx += 1;
                Ok(Some(0))
            }
            Some(ObjectType::LambdaFunctions) => {
                // Check if we need to fetch more functions
                if this.row_idx >= this.functions.len() {
                    if this.is_truncated && this.next_token.is_some() {
                        this.list_functions()?;
                    } else {
                        return Ok(None);
                    }
                }

                if this.row_idx >= this.functions.len() {
                    return Ok(None);
                }

                let func = &this.functions[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "function_name" => Some(Cell::String(func.function_name.clone())),
                        "function_arn" => Some(Cell::String(func.function_arn.clone())),
                        "runtime" => Some(Cell::String(func.runtime.clone())),
                        "handler" => Some(Cell::String(func.handler.clone())),
                        "code_size" => Some(Cell::I64(func.code_size)),
                        "memory_size" => Some(Cell::I32(func.memory_size)),
                        "timeout" => Some(Cell::I32(func.timeout)),
                        "last_modified" => {
                            // Lambda uses a different timestamp format: 2024-01-15T10:30:00.000+0000
                            let ts = Self::parse_lambda_timestamp(&func.last_modified)?;
                            Some(Cell::Timestamp(ts))
                        }
                        "description" => Some(Cell::String(func.description.clone())),
                        "state" => Some(Cell::String(func.state.clone())),
                        _ => None,
                    };
                    row.push(cell.as_ref());
                }

                this.row_idx += 1;
                Ok(Some(0))
            }
            Some(ObjectType::Route53HostedZones) => {
                // Check if we need to fetch more zones
                if this.row_idx >= this.hosted_zones.len() {
                    if this.is_truncated && this.next_token.is_some() {
                        this.list_hosted_zones()?;
                    } else {
                        return Ok(None);
                    }
                }

                if this.row_idx >= this.hosted_zones.len() {
                    return Ok(None);
                }

                let zone = &this.hosted_zones[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "id" => Some(Cell::String(zone.id.clone())),
                        "name" => Some(Cell::String(zone.name.clone())),
                        "caller_reference" => Some(Cell::String(zone.caller_reference.clone())),
                        "resource_record_set_count" => Some(Cell::I64(zone.resource_record_set_count)),
                        "comment" => Some(Cell::String(zone.comment.clone())),
                        "is_private" => Some(Cell::Bool(zone.is_private)),
                        _ => None,
                    };
                    row.push(cell.as_ref());
                }

                this.row_idx += 1;
                Ok(Some(0))
            }
            Some(ObjectType::Route53Records) => {
                // Check if we need to fetch more records
                if this.row_idx >= this.records.len() {
                    if this.is_truncated && this.next_token.is_some() {
                        this.list_resource_record_sets()?;
                    } else {
                        return Ok(None);
                    }
                }

                if this.row_idx >= this.records.len() {
                    return Ok(None);
                }

                let record = &this.records[this.row_idx];

                for col in ctx.get_columns() {
                    let cell = match col.name().as_str() {
                        "zone_id" => Some(Cell::String(record.zone_id.clone())),
                        "name" => Some(Cell::String(record.name.clone())),
                        "type" => Some(Cell::String(record.record_type.clone())),
                        "ttl" => Some(Cell::I64(record.ttl)),
                        "values" => Some(Cell::Json(record.values.clone())),
                        "alias_target" => record.alias_target.clone().map(Cell::Json),
                        "weight" => record.weight.map(Cell::I64),
                        "set_identifier" => record.set_identifier.clone().map(Cell::String),
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
        this.reset_scan_state();
        this.fetch_data()
    }

    fn end_scan(_ctx: &Context) -> FdwResult {
        let this = Self::this_mut();
        this.reset_scan_state();
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
        let s3_tables: Vec<(&str, &str)> = vec![
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

        // Define available tables for EC2
        let ec2_tables: Vec<(&str, &str)> = vec![
            ("instances", r#"create foreign table if not exists ec2_instances (
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
server {} options (
    service 'ec2',
    object 'instances'
)"#),
        ];

        // Define available tables for Lambda
        let lambda_tables: Vec<(&str, &str)> = vec![
            ("functions", r#"create foreign table if not exists lambda_functions (
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
server {} options (
    service 'lambda',
    object 'functions'
)"#),
        ];

        // Define available tables for Route53
        let route53_tables: Vec<(&str, &str)> = vec![
            ("hosted_zones", r#"create foreign table if not exists route53_hosted_zones (
    id text,
    name text,
    caller_reference text,
    resource_record_set_count bigint,
    comment text,
    is_private boolean
)
server {} options (
    service 'route53',
    object 'hosted_zones'
)"#),
            ("records", r#"create foreign table if not exists route53_records (
    zone_id text,
    name text,
    type text,
    ttl bigint,
    values jsonb,
    alias_target jsonb,
    weight bigint,
    set_identifier text
)
server {} options (
    service 'route53',
    object 'records'
)"#),
        ];

        // Determine which tables to create based on remote_schema
        let available_tables: Vec<(&str, &str)> = match stmt.remote_schema.as_str() {
            "s3" => s3_tables,
            "ec2" => ec2_tables,
            "lambda" => lambda_tables,
            "route53" => route53_tables,
            "all" => {
                let mut all = s3_tables;
                all.extend(ec2_tables);
                all.extend(lambda_tables);
                all.extend(route53_tables);
                all
            }
            _ => {
                return Err(format!(
                    "Unknown schema '{}'. Use: 's3', 'ec2', 'lambda', 'route53', or 'all'",
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
