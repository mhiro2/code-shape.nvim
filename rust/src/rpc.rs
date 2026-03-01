use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, value::RawValue};
use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::fd::AsRawFd;

#[derive(Debug, Deserialize)]
struct RawRequest {
    jsonrpc: String,
    id: Option<Value>,
    method: String,
    #[serde(default = "default_raw_params")]
    params: Box<RawValue>,
}

#[derive(Debug)]
pub struct Request {
    pub jsonrpc: String,
    pub id: Option<Value>,
    pub method: String,
    pub params: Value,
    pub params_bytes: usize,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Debug, Serialize)]
#[allow(dead_code)]
pub struct Notification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

// Standard JSON-RPC error codes
#[allow(dead_code)]
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

impl Response {
    pub fn success(id: Option<Value>, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Option<Value>, code: i32, message: String) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(RpcError {
                code,
                message,
                data: None,
            }),
        }
    }
}

#[allow(dead_code)]
impl Notification {
    pub fn new(method: &str, params: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            method: method.to_string(),
            params,
        }
    }
}

/// Reads JSON-RPC messages from stdin using newline-delimited JSON.
pub struct Transport {
    reader: BufReader<io::Stdin>,
}

type WaitForReadable = fn() -> io::Result<()>;

#[cfg(unix)]
fn wait_for_stdin_readable() -> io::Result<()> {
    let mut poll_fd = libc::pollfd {
        fd: io::stdin().as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };

    loop {
        let ready = unsafe { libc::poll(&mut poll_fd, 1, -1) };
        if ready > 0 {
            return Ok(());
        }
        if ready == 0 {
            continue;
        }

        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return Err(err);
    }
}

#[cfg(not(unix))]
fn wait_for_stdin_readable() -> io::Result<()> {
    Ok(())
}

fn parse_message_line(line: &str) -> Result<Option<Request>> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let request: RawRequest =
        serde_json::from_str(trimmed).context("failed to parse JSON-RPC request")?;
    let params_raw = request.params.get();
    let params = serde_json::from_str(params_raw).context("failed to parse request params")?;
    Ok(Some(Request {
        jsonrpc: request.jsonrpc,
        id: request.id,
        method: request.method,
        params,
        params_bytes: params_raw.len(),
    }))
}

fn read_message_from_reader_with_wait<R: BufRead>(
    reader: &mut R,
    wait_for_readable: WaitForReadable,
) -> Result<Option<Request>> {
    loop {
        let mut line = String::new();
        let bytes_read = match reader.read_line(&mut line) {
            Ok(bytes_read) => bytes_read,
            Err(err) => match err.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::BrokenPipe => return Ok(None),
                io::ErrorKind::WouldBlock => {
                    wait_for_readable().context("failed to wait for stdin readiness")?;
                    continue;
                }
                _ => return Err(err).context("failed to read from stdin"),
            },
        };

        if bytes_read == 0 {
            return Ok(None); // EOF
        }

        if let Some(request) = parse_message_line(&line)? {
            return Ok(Some(request));
        }
    }
}

fn read_message_from_reader<R: BufRead>(reader: &mut R) -> Result<Option<Request>> {
    read_message_from_reader_with_wait(reader, wait_for_stdin_readable)
}

impl Transport {
    pub fn new() -> Self {
        Self {
            reader: BufReader::new(io::stdin()),
        }
    }

    pub fn read_message(&mut self) -> Result<Option<Request>> {
        read_message_from_reader(&mut self.reader)
    }

    pub fn send_response(&self, response: &Response) -> Result<()> {
        let json = serde_json::to_string(response)?;
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        writeln!(handle, "{}", json)?;
        handle.flush()?;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn send_notification(&self, notification: &Notification) -> Result<()> {
        let json = serde_json::to_string(notification)?;
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        writeln!(handle, "{}", json)?;
        handle.flush()?;
        Ok(())
    }
}

impl Default for Transport {
    fn default() -> Self {
        Self::new()
    }
}

fn default_raw_params() -> Box<RawValue> {
    // SAFETY: "null" is a valid static JSON value
    RawValue::from_string("null".to_string()).expect("static null must be valid json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Cursor, Read};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct WouldBlockOnceReader {
        inner: Cursor<Vec<u8>>,
        should_block: bool,
    }

    impl WouldBlockOnceReader {
        fn new(input: &[u8]) -> Self {
            Self {
                inner: Cursor::new(input.to_vec()),
                should_block: true,
            }
        }
    }

    impl Read for WouldBlockOnceReader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.inner.read(buf)
        }
    }

    impl BufRead for WouldBlockOnceReader {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            if self.should_block {
                self.should_block = false;
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "would block once",
                ));
            }
            self.inner.fill_buf()
        }

        fn consume(&mut self, amt: usize) {
            self.inner.consume(amt);
        }
    }

    static WAIT_CALLS: AtomicUsize = AtomicUsize::new(0);

    fn fake_wait_for_readable() -> io::Result<()> {
        WAIT_CALLS.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    #[test]
    fn parse_message_line_uses_raw_params_size() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"index/upsertSymbols","params":{"uri":"file:///a.lua","symbols":[{"name":"fn"}]}}"#;
        let request = parse_message_line(line)
            .expect("request must parse")
            .expect("request must not be empty");

        assert_eq!(request.method, "index/upsertSymbols");
        assert_eq!(
            request.params,
            json!({
                "uri": "file:///a.lua",
                "symbols": [{"name": "fn"}]
            })
        );
        assert_eq!(
            request.params_bytes,
            r#"{"uri":"file:///a.lua","symbols":[{"name":"fn"}]}"#.len()
        );
    }

    #[test]
    fn parse_message_line_defaults_missing_params_to_null() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"index/stats"}"#;
        let request = parse_message_line(line)
            .expect("request must parse")
            .expect("request must not be empty");

        assert_eq!(request.params, Value::Null);
        assert_eq!(request.params_bytes, 4);
    }

    #[test]
    fn read_message_from_reader_skips_blank_lines() {
        let mut reader =
            Cursor::new(b"\n\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"index/stats\"}\n");
        let request = read_message_from_reader(&mut reader)
            .expect("read must succeed")
            .expect("request must exist");
        assert_eq!(request.method, "index/stats");
    }

    #[test]
    fn read_message_from_reader_waits_on_would_block() {
        WAIT_CALLS.store(0, Ordering::SeqCst);
        let mut reader = WouldBlockOnceReader::new(
            b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"index/stats\"}\n",
        );

        let request = read_message_from_reader_with_wait(&mut reader, fake_wait_for_readable)
            .expect("read must succeed")
            .expect("request must exist");

        assert_eq!(request.method, "index/stats");
        assert_eq!(WAIT_CALLS.load(Ordering::SeqCst), 1);
    }
}
