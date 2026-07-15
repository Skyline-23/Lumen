use std::borrow::Cow;
use std::io::{self, Read, Write};

use percent_encoding::percent_decode_str;

use crate::{ControlMethod, ControlRequest, ControlResponse};

const MAXIMUM_HEADER_BYTES: usize = 16 * 1024;
const MAXIMUM_BODY_BYTES: usize = 32 * 1024;
const MAXIMUM_HEADERS: usize = 64;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum HttpReadError {
    Io(String),
    InvalidRequest(&'static str),
}

struct ParsedHead {
    method: ControlMethod,
    target: String,
    headers: Vec<(String, String)>,
    content_length: usize,
}

impl From<io::Error> for HttpReadError {
    fn from(error: io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

pub(super) fn read_request(stream: &mut impl Read) -> Result<ControlRequest, HttpReadError> {
    let mut bytes = Vec::new();
    let header_end = loop {
        if let Some(offset) = find_bytes(&bytes, b"\r\n\r\n") {
            break offset + 4;
        }
        if bytes.len() >= MAXIMUM_HEADER_BYTES {
            return Err(HttpReadError::InvalidRequest(
                "request headers are too large",
            ));
        }
        let mut chunk = [0_u8; 2_048];
        let count = stream.read(&mut chunk)?;
        if count == 0 {
            return Err(HttpReadError::InvalidRequest(
                "request headers are incomplete",
            ));
        }
        bytes.extend_from_slice(&chunk[..count]);
        if bytes.len() > MAXIMUM_HEADER_BYTES + MAXIMUM_BODY_BYTES {
            return Err(HttpReadError::InvalidRequest("request is too large"));
        }
    };

    let parsed = parse_head(&bytes[..header_end])?;
    let required_length = header_end
        .checked_add(parsed.content_length)
        .ok_or(HttpReadError::InvalidRequest("request length overflowed"))?;
    while bytes.len() < required_length {
        let mut chunk = [0_u8; 2_048];
        let remaining = required_length - bytes.len();
        let read_length = remaining.min(chunk.len());
        let count = stream.read(&mut chunk[..read_length])?;
        if count == 0 {
            return Err(HttpReadError::InvalidRequest("request body is incomplete"));
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    if bytes.len() != required_length {
        return Err(HttpReadError::InvalidRequest(
            "pipelined requests are unsupported",
        ));
    }

    let (path, query) = parse_target(&parsed.target)?;
    Ok(ControlRequest {
        method: parsed.method,
        path,
        headers: parsed.headers,
        query,
        body: bytes[header_end..required_length].to_vec(),
    })
}

fn parse_head(bytes: &[u8]) -> Result<ParsedHead, HttpReadError> {
    let mut raw_headers = [httparse::EMPTY_HEADER; MAXIMUM_HEADERS];
    let mut request = httparse::Request::new(&mut raw_headers);
    let status = request
        .parse(bytes)
        .map_err(|_| HttpReadError::InvalidRequest("request headers are malformed"))?;
    let consumed = match status {
        httparse::Status::Complete(consumed) => consumed,
        httparse::Status::Partial => {
            return Err(HttpReadError::InvalidRequest(
                "request headers are incomplete",
            ));
        }
    };
    if consumed != bytes.len() || request.version != Some(1) {
        return Err(HttpReadError::InvalidRequest("request line is malformed"));
    }
    let method = match request.method {
        Some("GET") => ControlMethod::Get,
        Some("PATCH") => ControlMethod::Patch,
        Some("POST") => ControlMethod::Post,
        _ => {
            return Err(HttpReadError::InvalidRequest(
                "request method is unsupported",
            ))
        }
    };
    let target = request
        .path
        .ok_or(HttpReadError::InvalidRequest("request target is missing"))?
        .to_owned();

    let mut headers = Vec::with_capacity(request.headers.len());
    let mut content_length = None;
    for header in request.headers {
        let value = std::str::from_utf8(header.value)
            .map_err(|_| HttpReadError::InvalidRequest("request header value is invalid"))?
            .trim();
        if header.name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return Err(HttpReadError::InvalidRequest(
                    "content length must be unique",
                ));
            }
            content_length = Some(
                value
                    .parse::<usize>()
                    .ok()
                    .filter(|length| *length <= MAXIMUM_BODY_BYTES)
                    .ok_or(HttpReadError::InvalidRequest("content length is invalid"))?,
            );
        }
        if header.name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(HttpReadError::InvalidRequest(
                "transfer encoding is unsupported",
            ));
        }
        if value
            .bytes()
            .any(|byte| byte != b'\t' && !(b' '..=b'~').contains(&byte))
        {
            return Err(HttpReadError::InvalidRequest(
                "request header value is invalid",
            ));
        }
        headers.push((header.name.to_owned(), value.to_owned()));
    }
    Ok(ParsedHead {
        method,
        target,
        headers,
        content_length: content_length.unwrap_or_default(),
    })
}

pub(super) fn write_response(
    stream: &mut impl Write,
    response: &ControlResponse,
) -> io::Result<()> {
    let reason = match response.status_code {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Response",
    };
    write!(
        stream,
        "HTTP/1.1 {} {reason}\r\nContent-Type: {}\r\nCache-Control: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status_code,
        response.content_type,
        response.cache_control,
        response.body.len()
    )?;
    stream.write_all(&response.body)?;
    stream.flush()
}

pub(super) fn bad_request(message: &'static str) -> ControlResponse {
    ControlResponse {
        status_code: 400,
        body: serde_json::to_vec(&serde_json::json!({
            "error": {
                "code": "invalid-request",
                "message": message,
                "retryable": false
            }
        }))
        .unwrap_or_else(|_| b"{}".to_vec()),
        content_type: "application/json",
        cache_control: "no-store",
    }
}

pub(super) fn internal_error() -> ControlResponse {
    ControlResponse {
        status_code: 500,
        body: br#"{"error":{"code":"storage-error","message":"control router is unavailable","retryable":true}}"#
            .to_vec(),
        content_type: "application/json",
        cache_control: "no-store",
    }
}

fn parse_target(target: &str) -> Result<(String, Vec<(String, String)>), HttpReadError> {
    if !target.starts_with('/') || target.contains('#') {
        return Err(HttpReadError::InvalidRequest("request target is invalid"));
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = percent_decode(path, false)?;
    let query = if query.is_empty() {
        Vec::new()
    } else {
        query
            .split('&')
            .map(|item| {
                let (name, value) = item.split_once('=').unwrap_or((item, ""));
                Ok((percent_decode(name, true)?, percent_decode(value, true)?))
            })
            .collect::<Result<Vec<_>, HttpReadError>>()?
    };
    Ok((path, query))
}

fn percent_decode(value: &str, plus_as_space: bool) -> Result<String, HttpReadError> {
    validate_percent_escapes(value)?;
    let normalized = if plus_as_space && value.contains('+') {
        Cow::Owned(value.replace('+', " "))
    } else {
        Cow::Borrowed(value)
    };
    percent_decode_str(&normalized)
        .decode_utf8()
        .map(Cow::into_owned)
        .map_err(|_| HttpReadError::InvalidRequest("request escaping is not valid UTF-8"))
}

fn validate_percent_escapes(value: &str) -> Result<(), HttpReadError> {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return Err(HttpReadError::InvalidRequest("request escaping is invalid"));
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    Ok(())
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|value| value == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_one_bounded_http_request_into_the_typed_router_shape() {
        let raw = b"PATCH /api/v1/settings?afterRevision=4%32 HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}";
        let request = read_request(&mut raw.as_slice()).unwrap();
        assert_eq!(request.method, ControlMethod::Patch);
        assert_eq!(request.path, "/api/v1/settings");
        assert_eq!(request.query, [("afterRevision".into(), "42".into())]);
        assert_eq!(request.body, b"{}");
    }

    #[test]
    fn rejects_duplicate_lengths_invalid_escapes_and_pipelining() {
        for mut raw in [
            b"POST /api HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".as_slice(),
            b"GET /api/%ZZ HTTP/1.1\r\n\r\n",
            b"GET /api HTTP/1.1\r\n\r\ntrailing",
            b"POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        ] {
            assert!(matches!(
                read_request(&mut raw),
                Err(HttpReadError::InvalidRequest(_))
            ));
        }
    }

    #[test]
    fn writes_complete_close_delimited_json_response() {
        let mut output = Vec::new();
        write_response(&mut output, &bad_request("bad input")).unwrap();
        let response = String::from_utf8(output).unwrap();
        assert!(response.starts_with("HTTP/1.1 400 Bad Request\r\n"));
        assert!(response.contains("Cache-Control: no-store\r\n"));
        assert!(response.ends_with("}"));
    }
}
