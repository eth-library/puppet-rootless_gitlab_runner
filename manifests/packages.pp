# @summary Installs the packages listed under `packages.install`.
# @api private
class rootless_gitlab_runner::packages {
  assert_private()

  # The package list is data: which packages (and whether any) is per-host
  # Hiera. The apt sources they come from can be managed behind
  # packages.sources.manage (apt_repos.pp); with the toggle off, source setup
  # is an external prerequisite (central configuration management, e.g.
  # Foreman/Katello). Install only: the module never removes packages absent
  # from the list and never pins or upgrades.
  unless empty($rootless_gitlab_runner::packages['install']) {
    package { $rootless_gitlab_runner::packages['install']:
      ensure => installed,
    }
  }
}
