use std::collections::BTreeMap;

use lumen_engine::settings::CommandInvocation;

pub(super) fn environment_block(
    environment: &BTreeMap<String, String>,
) -> Result<Vec<u16>, String> {
    let mut entries = BTreeMap::new();
    for (key, value) in environment {
        entries.insert(key.to_lowercase(), (key, value));
    }
    let mut block = Vec::new();
    for (_, (key, value)) in entries {
        if key.is_empty() || key.contains(['=', '\0']) || value.contains('\0') {
            return Err("Windows process environment contains an invalid entry".to_owned());
        }
        block.extend(key.encode_utf16());
        block.push('=' as u16);
        block.extend(value.encode_utf16());
        block.push(0);
    }
    block.push(0);
    if block.len() == 1 {
        block.push(0);
    }
    Ok(block)
}

pub(super) fn invocation_command_line(invocation: &CommandInvocation) -> Result<Vec<u16>, String> {
    if invocation.program.is_empty() {
        return Err("Structured Windows process program is empty".to_owned());
    }
    let mut encoded = String::new();
    quote_argument(&invocation.program, &mut encoded);
    for argument in &invocation.arguments {
        encoded.push(' ');
        quote_argument(argument, &mut encoded);
    }
    command_line(&encoded)
}

fn quote_argument(value: &str, output: &mut String) {
    let needs_quotes = value.is_empty()
        || value
            .chars()
            .any(|value| value.is_whitespace() || value == '"');
    if !needs_quotes {
        output.push_str(value);
        return;
    }
    output.push('"');
    let mut backslashes = 0;
    for value in value.chars() {
        if value == '\\' {
            backslashes += 1;
            continue;
        }
        if value == '"' {
            output.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
        } else {
            output.extend(std::iter::repeat_n('\\', backslashes));
        }
        backslashes = 0;
        output.push(value);
    }
    output.extend(std::iter::repeat_n('\\', backslashes * 2));
    output.push('"');
}

pub(super) fn command_line(value: &str) -> Result<Vec<u16>, String> {
    if value.is_empty() {
        return Err("Windows process command is empty".to_owned());
    }
    wide(value)
}

#[cfg(windows)]
pub(super) fn optional_wide(value: &str) -> Result<Option<Vec<u16>>, String> {
    if value.is_empty() {
        Ok(None)
    } else {
        wide(value).map(Some)
    }
}

pub(super) fn wide(value: &str) -> Result<Vec<u16>, String> {
    if value.contains('\0') {
        return Err("Windows process value contains an interior NUL".to_owned());
    }
    Ok(value.encode_utf16().chain(std::iter::once(0)).collect())
}
