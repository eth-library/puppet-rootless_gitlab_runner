# @summary Escape a string for embedding inside a TOML basic (double-quoted) string.
#
# Every field the runner config interpolates comes from review-gated Hiera data,
# but a stray double-quote, backslash or newline would otherwise produce invalid
# TOML — or, with a crafted value, inject an unintended key (a newline in a
# `comment` could open `privileged = true`). Escaping every interpolated field
# closes that gap regardless of the data's provenance, per the TOML basic-string
# rules (https://toml.io/en/v1.0.0#string): backslash and double-quote are
# backslash-escaped, and the control characters that must not appear literally
# (newline, carriage return, tab) become their `\n` / `\r` / `\t` escapes.
#
# Backslash is escaped first so the backslashes introduced by the later
# substitutions are not doubled again.
#
# @param value the raw string to escape
# @return the escaped string, safe to place between double quotes in TOML
function rootless_gitlab_runner::toml_escape(String $value) >> String {
  $value
    .regsubst('\\\\', '\\\\\\\\', 'G')
    .regsubst('"', '\\"', 'G')
    .regsubst("\n", '\\n', 'G')
    .regsubst("\r", '\\r', 'G')
    .regsubst("\t", '\\t', 'G')
}
