# Standalone entry point: apply the rootless GitLab Runner configuration.
# Class parameters are resolved from Hiera (see hiera.yaml).
node default {
  include rootless_gitlab_runner
}
