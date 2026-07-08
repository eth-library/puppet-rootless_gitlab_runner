# @summary A strict POSIX-portable Linux username.
#
# The runner user is interpolated raw into shell execs (the subuid/subgid echo
# in `user.pp`, the rootless preflight `awk` in `rootless_docker.pp`) and into
# systemd directives. Constraining it to the shadow-utils `NAME_REGEX` shape —
# a lowercase or underscore start, then lowercase letters, digits, underscore or
# hyphen, up to 32 characters — excludes shell-hostile characters (quotes,
# spaces, `$`, `;`, newlines) by construction, so those interpolations cannot be
# broken out of. `$` (the Samba machine-account suffix) is deliberately excluded
# as shell-hostile.
type Rootless_gitlab_runner::Username = Pattern[/\A[a-z_][a-z0-9_-]{0,31}\z/]
