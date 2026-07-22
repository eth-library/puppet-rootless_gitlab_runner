# @summary An apt source's location and signing-key endpoint.
#
# `location` and `key_source` are verbatim `apt::source` parameter names: the
# repository URL (suite = OS codename) and the URL of its armored signing key,
# stored as an apt keyring. Both the Docker and GitLab Runner sources under
# `packages.sources` share this shape, pointing at a vendor repository or a
# mirror.
type Rootless_gitlab_runner::Apt_source = Struct[{
  location   => Stdlib::HTTPUrl,
  key_source => Stdlib::HTTPUrl,
}]
