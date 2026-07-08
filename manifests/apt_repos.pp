# @summary Adds the apt repositories the `packages` list installs from.
# @api private
class rootless_gitlab_runner::apt_repos {
  assert_private()

  if $rootless_gitlab_runner::manage_apt_repos {
    include apt

    # Fetch each repo's rolling gpgkey endpoint into /etc/apt/keyrings ourselves
    # rather than via the apt::source `key` hash. The `key` hash (apt::keyring)
    # emits a bare file with an http source and no checksum, so Puppet compares
    # it by mtime and re-fetches + re-notifies apt_update every run — churn and
    # a slow, non-idempotent apply. checksum => sha256 makes an unchanged key a
    # no-op while a genuine key rotation still rewrites the file and refreshes
    # the index (the rolling endpoint, per the Bug 1 fix, is preserved).
    $docker_keyring        = '/etc/apt/keyrings/docker.asc'
    $gitlab_runner_keyring = '/etc/apt/keyrings/gitlab-runner.asc'

    file { $docker_keyring:
      ensure   => file,
      owner    => 'root',
      group    => 'root',
      mode     => '0644',
      source   => $rootless_gitlab_runner::docker_repo_key_source,
      checksum => 'sha256',
    }

    file { $gitlab_runner_keyring:
      ensure   => file,
      owner    => 'root',
      group    => 'root',
      mode     => '0644',
      source   => $rootless_gitlab_runner::gitlab_runner_repo_key_source,
      checksum => 'sha256',
    }

    # Repo definitions verified against the official install docs
    # (docs.docker.com/engine/install/ubuntu, docs.gitlab.com/runner/install/
    # linux-repository): suite = OS codename (apt::source default), Docker
    # component "stable", GitLab Runner "main". `keyring` points signed-by at
    # the managed keyring above (mutually exclusive with the `key` hash).
    apt::source { 'docker':
      location => $rootless_gitlab_runner::docker_repo_location,
      repos    => 'stable',
      keyring  => $docker_keyring,
      require  => File[$docker_keyring],
    }

    apt::source { 'gitlab-runner':
      location => $rootless_gitlab_runner::gitlab_runner_repo_location,
      repos    => 'main',
      keyring  => $gitlab_runner_keyring,
      require  => File[$gitlab_runner_keyring],
    }

    # The sources notify Exec['apt_update'] (apt module default); this makes
    # the refreshed index precede any package install on a fresh host.
    Class['apt::update'] -> Class['rootless_gitlab_runner::packages']
  }
}
