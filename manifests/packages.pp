# @summary Installs the packages listed in the `packages` parameter.
# @api private
class rootless_gitlab_runner::packages {
  assert_private()

  # The package list is data: which packages (and whether any) is per-host
  # Hiera. The apt repositories they come from can be managed behind
  # manage_apt_repos (apt_repos.pp); with the toggle off, repo setup is an
  # external prerequisite (central config management, e.g. Foreman/Katello).
  unless empty($rootless_gitlab_runner::packages) {
    package { $rootless_gitlab_runner::packages:
      ensure => installed,
    }
  }
}
