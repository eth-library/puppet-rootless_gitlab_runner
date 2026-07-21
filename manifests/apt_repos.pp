# @summary Adds the apt repositories the `packages` list installs from.
# @api private
class rootless_gitlab_runner::apt_repos {
  assert_private()

  if $rootless_gitlab_runner::manage_apt_repos {
    include apt

    # Fetch each repo's rolling gpgkey endpoint into /etc/apt/keyrings via a
    # content-guarded exec, not a File resource with an http source: Puppet
    # silently ignores `checksum` for http(s) File sources and falls back to
    # comparing the Last-Modified response header against the local mtime, so
    # a key endpoint that serves no stable Last-Modified (GitLab's) re-fetches
    # and rewrites the keyring on every apply, refreshing the apt index each
    # time. The guard below downloads the endpoint's current key to a staging
    # file and content-compares it against the installed keyring; the command
    # replaces the keyring, and refreshes the apt index, only on a real
    # content change. An unchanged key is a true no-op while a genuine key
    # rotation is still picked up (the rolling endpoints are deliberate; never
    # pin a key id).
    #
    # apt-helper ships with apt itself (no extra package needed on a fresh
    # host) and downloads through apt's own acquire methods, honoring apt
    # proxy configuration. Guard contract: exit 0 or 1, never 127 — `test -x`
    # the packaged helper first, and normalize the non-0/1 failure codes
    # (apt-helper's 100, cmp's 2 on a missing keyring) to 1. The staged
    # download in the guard runs on every apply, also under --noop; it writes
    # only the staging file, never the keyring.
    $docker_keyring        = '/etc/apt/keyrings/docker.asc'
    $gitlab_runner_keyring = '/etc/apt/keyrings/gitlab-runner.asc'
    $helper                = '/usr/lib/apt/apt-helper'
    $staging_dir           = '/var/cache/rootless_gitlab_runner'

    # Staged key downloads land here; regenerated on every apply, safe to
    # delete.
    file { $staging_dir:
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    $apt_keyrings = {
      'docker'        => {
        'keyring' => $docker_keyring,
        'source'  => $rootless_gitlab_runner::docker_repo_key_source,
      },
      'gitlab-runner' => {
        'keyring' => $gitlab_runner_keyring,
        'source'  => $rootless_gitlab_runner::gitlab_runner_repo_key_source,
      },
    }

    $apt_keyrings.each |$name, $key| {
      $staging = "${staging_dir}/${name}.asc"

      # Presence and permissions only — content is owned by the exec below (a
      # content-managing File with an http source would reintroduce the mtime
      # churn this replaces). Ordered first so the parent keyrings directory
      # (autorequired by path) exists before the exec installs into it.
      file { $key['keyring']:
        ensure => file,
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
      }

      $fetch   = "${helper} download-file '${key['source']}' '${staging}'"
      $compare = "cmp -s '${staging}' '${key['keyring']}'"

      exec { "rootless_gitlab_runner ${name} keyring refresh":
        command  => "${fetch} && install -m 0644 '${staging}' '${key['keyring']}'",
        unless   => "{ test -x ${helper} && ${fetch} && ${compare} ; } >/dev/null 2>&1 || exit 1",
        path     => ['/usr/bin', '/bin'],
        provider => 'shell',
        require  => [File[$staging_dir], File[$key['keyring']]],
        notify   => Exec['apt_update'],
      }
    }

    # Repo definitions verified against the official install docs
    # (docs.docker.com/engine/install/ubuntu, docs.gitlab.com/runner/install/
    # linux-repository): suite = OS codename (apt::source default), Docker
    # component "stable", GitLab Runner "main". `keyring` points signed-by at
    # the managed keyring above; requiring the refresh exec makes the fetched
    # key precede the source it signs.
    apt::source { 'docker':
      location => $rootless_gitlab_runner::docker_repo_location,
      repos    => 'stable',
      keyring  => $docker_keyring,
      require  => Exec['rootless_gitlab_runner docker keyring refresh'],
    }

    apt::source { 'gitlab-runner':
      location => $rootless_gitlab_runner::gitlab_runner_repo_location,
      repos    => 'main',
      keyring  => $gitlab_runner_keyring,
      require  => Exec['rootless_gitlab_runner gitlab-runner keyring refresh'],
    }

    # The sources and the keyring refreshes notify Exec['apt_update']; this
    # ordering makes the refreshed index precede any package install on a
    # fresh host.
    Class['apt::update'] -> Class['rootless_gitlab_runner::packages']
  }
}
