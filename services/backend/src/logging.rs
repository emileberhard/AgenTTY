use std::fmt::Display;

pub fn token_tail(value: &str) -> &str {
    let start = value
        .char_indices()
        .rev()
        .nth(7)
        .map_or(0, |(index, _)| index);
    &value[start..]
}

pub fn log_value(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
        .chars()
        .take(160)
        .collect()
}

pub fn option_display<T: Display>(value: Option<T>) -> String {
    value
        .map(|value| value.to_string())
        .unwrap_or_else(|| "none".to_owned())
}

#[cfg(test)]
mod tests {
    #[test]
    fn token_diagnostics_never_split_untrusted_utf8() {
        assert_eq!(super::token_tail("aåååååååå"), "åååååååå");
        assert_eq!(super::token_tail("short"), "short");
    }
}
