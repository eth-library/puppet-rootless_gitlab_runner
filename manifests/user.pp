# @summary Owns the runner group, user, home and subordinate ID ranges.
# @api private
class rootless_gitlab_runner::user {
  assert_private()

  if $rootless_gitlab_runner::manage_runner_user {
    $runner_user = $rootless_gitlab_runner::runner_user
    $subid_entry = "${runner_user}:${rootless_gitlab_runner::subid_start}:${rootless_gitlab_runner::subid_count}"

    group { $runner_user:
      ensure => present,
      system => true,
    }

    # Home internals (.ssh, .config, ...) are never managed; managehome only
    # creates the directory on first apply.
    user { $runner_user:
      ensure     => present,
      system     => true,
      uid        => $rootless_gitlab_runner::runner_uid,
      gid        => $runner_user,
      home       => $rootless_gitlab_runner::runner_home,
      managehome => true,
      shell      => '/bin/bash',
      require    => Group[$runner_user],
    }

    # Rootless docker needs >= 65536 subordinate IDs; `useradd --system` does
    # not allocate any, and jammy's shadow predates `usermod --add-subuids`,
    # so the entries are appended guarded. An existing entry for the user is
    # left alone (no drift war over externally chosen ranges).
    ['subuid', 'subgid'].each |$f| {
      exec { "rootless_gitlab_runner ${f} entry":
        command  => "echo '${subid_entry}' >> /etc/${f}",
        unless   => "grep -q '^${runner_user}:' /etc/${f}",
        path     => ['/usr/bin', '/bin'],
        provider => 'shell',
        require  => User[$runner_user],
      }
    }
  }
}
