require 'spec_helper'
require 'yaml'

# puppetlabs-apt compiles only on Debian-family facts; the suite otherwise runs
# factless, so the apt-enabled and example contexts pin the single supported
# OS's facts. Derived from metadata.json via rspec-puppet-facts / facterdb (one
# fact source, not a hand-maintained hash), so the fact set follows metadata.
UBUNTU_FACTS = on_supported_os.values.first.freeze

describe 'rootless_gitlab_runner' do
  # config.toml content is Sensitive (it carries tokens); unwrap it for byte
  # and pattern assertions.
  def rendered_config
    content = catalogue.resource('File', '/etc/gitlab-runner/config.toml')[:content]
    content.respond_to?(:unwrap) ? content.unwrap : content
  end

  # The rendered content of any managed File resource (unwrapped if Sensitive).
  def rendered_file(path)
    content = catalogue.resource('File', path)[:content]
    content.respond_to?(:unwrap) ? content.unwrap : content
  end

  # Load and parse a YAML file from examples/.
  def example_yaml(*path)
    YAML.safe_load(File.read(File.expand_path(File.join(__dir__, '..', '..', 'examples', *path))))
  end

  # The example common + node data as class params (module prefix stripped).
  def example_data_params
    prefix = 'rootless_gitlab_runner::'
    [example_yaml('data', 'common.yaml'), example_yaml('data', 'nodes', 'host.example.yaml')]
      .reduce(:merge)
      .select { |k, _| k.start_with?(prefix) }
      .transform_keys { |k| k.delete_prefix(prefix) }
  end

  context 'with defaults' do
    it { is_expected.to compile.with_all_deps }

    %w[subuid subgid].each do |f|
      it "writes no #{f} entry with rootless docker unmanaged" do
        is_expected.not_to contain_exec("rootless_gitlab_runner #{f} entry")
      end
    end

    it 'chains the classes so a one-shot fresh apply converges in order' do
      is_expected.to contain_class('rootless_gitlab_runner::apt_repos').that_comes_before('Class[rootless_gitlab_runner::packages]')
      is_expected.to contain_class('rootless_gitlab_runner::packages').that_comes_before('Class[rootless_gitlab_runner::user]')
      is_expected.to contain_class('rootless_gitlab_runner::user').that_comes_before('Class[rootless_gitlab_runner::rootless_docker]')
      is_expected.to contain_class('rootless_gitlab_runner::rootless_docker').that_comes_before('Class[rootless_gitlab_runner::config]')
      is_expected.to contain_class('rootless_gitlab_runner::config').that_comes_before('Class[rootless_gitlab_runner::service]')
      is_expected.to contain_class('rootless_gitlab_runner::service').that_comes_before('Class[rootless_gitlab_runner::self_update]')
    end

    it 'owns the full user systemd parent chain so the first apply can place the drop-in' do
      [
        '/home/gitlab-runner/.config',
        '/home/gitlab-runner/.config/systemd',
        '/home/gitlab-runner/.config/systemd/user',
        '/home/gitlab-runner/.config/systemd/user/docker.service.d',
      ].each do |dir|
        is_expected.to contain_file(dir).with_ensure('directory')
      end
      is_expected.to contain_file('/home/gitlab-runner/.config/systemd/user/docker.service.d/no-detach-netns.conf')
        .that_requires('File[/home/gitlab-runner/.config/systemd/user/docker.service.d]')
    end

    it 'manages the runner config, root-owned mode 0600 semantics' do
      is_expected.to contain_file('/etc/gitlab-runner/config.toml').with(
        'ensure' => 'file',
        'owner'  => 'gitlab-runner',
        'group'  => 'gitlab-runner',
        'mode'   => '0600',
      )
    end

    it 'always pins DETACH_NETNS=false via the no-detach-netns drop-in' do
      is_expected.to contain_file(
        '/home/gitlab-runner/.config/systemd/user/docker.service.d/no-detach-netns.conf',
      ).with('ensure' => 'file', 'mode' => '0644')
    end

    it 'manages the secret-store directory 0700' do
      is_expected.to contain_file('/etc/gitlab-runner-infra').with(
        'ensure' => 'directory',
        'owner'  => 'root',
        'mode'   => '0700',
      )
    end

    it 'manages nothing toggled off' do
      is_expected.not_to contain_user('gitlab-runner')
      is_expected.not_to contain_service('gitlab-runner')
      is_expected.not_to contain_exec('rootless_gitlab_runner preflight')
      # The host's own Docker/containerd services are untouched without the rootless bring-up.
      is_expected.not_to contain_service('docker.service')
      is_expected.not_to contain_service('docker.socket')
      is_expected.not_to contain_service('containerd.service')
      is_expected.not_to contain_file('/etc/systemd/system/gitlab-runner-apply.timer')
      # No user-scoped docker restart where the module does not own the daemon.
      is_expected.not_to contain_exec('rootless_gitlab_runner docker daemon-reload (no-detach-netns)')
    end

    it 'installs no packages for an empty list' do
      is_expected.not_to contain_package('docker-ce')
    end

    it 'adds no apt sources' do
      is_expected.not_to contain_apt__source('docker')
      is_expected.not_to contain_apt__source('gitlab-runner')
    end
  end

  context 'with manage_apt_repos' do
    # puppetlabs-apt compiles only on Debian-family facts; the suite otherwise
    # runs factless, so this context pins the supported OS fact set (reused).
    let(:facts) { UBUNTU_FACTS }
    let(:params) { { 'manage_apt_repos' => true } }

    it { is_expected.to compile.with_all_deps }

    it 'adds the docker apt source pointing signed-by at the managed keyring' do
      is_expected.to contain_apt__source('docker').with(
        'location' => 'https://download.docker.com/linux/ubuntu',
        'repos'    => 'stable',
        'keyring'  => '/etc/apt/keyrings/docker.asc',
      )
    end

    it 'adds the gitlab-runner apt source pointing signed-by at the managed keyring' do
      is_expected.to contain_apt__source('gitlab-runner').with(
        'location' => 'https://packages.gitlab.com/runner/gitlab-runner/ubuntu',
        'repos'    => 'main',
        'keyring'  => '/etc/apt/keyrings/gitlab-runner.asc',
      )
    end

    # The command and guard strings are pinned end to end (anchored): dropping
    # the install step, the guard's staged fetch, or the exit-code
    # normalization must fail here, not survive behind a fragment match.
    it 'refreshes each keyring content-guarded: staged download, compare, replace + index refresh only on change' do
      is_expected.to contain_exec('rootless_gitlab_runner docker keyring refresh')
        .with_command(%r{\A/usr/lib/apt/apt-helper download-file 'https://download\.docker\.com/linux/ubuntu/gpg' '/var/cache/rootless_gitlab_runner/docker\.asc' && install -m 0644 '/var/cache/rootless_gitlab_runner/docker\.asc' '/etc/apt/keyrings/docker\.asc'\z})
        .with_unless(%r{\A\{ test -x /usr/lib/apt/apt-helper && /usr/lib/apt/apt-helper download-file 'https://download\.docker\.com/linux/ubuntu/gpg' '/var/cache/rootless_gitlab_runner/docker\.asc' && cmp -s '/var/cache/rootless_gitlab_runner/docker\.asc' '/etc/apt/keyrings/docker\.asc' ; \} >/dev/null 2>&1 \|\| exit 1\z})
        .that_notifies('Exec[apt_update]')
      is_expected.to contain_exec('rootless_gitlab_runner gitlab-runner keyring refresh')
        .with_command(%r{\A/usr/lib/apt/apt-helper download-file 'https://packages\.gitlab\.com/runner/gitlab-runner/gpgkey' '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' && install -m 0644 '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' '/etc/apt/keyrings/gitlab-runner\.asc'\z})
        .with_unless(%r{\A\{ test -x /usr/lib/apt/apt-helper && /usr/lib/apt/apt-helper download-file 'https://packages\.gitlab\.com/runner/gitlab-runner/gpgkey' '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' && cmp -s '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' '/etc/apt/keyrings/gitlab-runner\.asc' ; \} >/dev/null 2>&1 \|\| exit 1\z})
        .that_notifies('Exec[apt_update]')
    end

    # First-apply ordering must be declared, not incidental: the staging dir
    # and keyring file precede the refresh; the refresh precedes the source it
    # signs (a source applied before its key breaks apt-get update on a fresh
    # host).
    it 'orders the refresh after its files and before its apt source' do
      is_expected.to contain_exec('rootless_gitlab_runner docker keyring refresh')
        .that_requires('File[/var/cache/rootless_gitlab_runner]')
        .that_requires('File[/etc/apt/keyrings/docker.asc]')
      is_expected.to contain_apt__source('docker')
        .that_requires('Exec[rootless_gitlab_runner docker keyring refresh]')
      is_expected.to contain_exec('rootless_gitlab_runner gitlab-runner keyring refresh')
        .that_requires('File[/var/cache/rootless_gitlab_runner]')
        .that_requires('File[/etc/apt/keyrings/gitlab-runner.asc]')
      is_expected.to contain_apt__source('gitlab-runner')
        .that_requires('Exec[rootless_gitlab_runner gitlab-runner keyring refresh]')
    end

    # Honest limit: a compiled catalog cannot show whether the applied state
    # churns. The previous implementation passed a catalog test asserting
    # `checksum => sha256` while every real apply rewrote the keyring, because
    # Puppet ignores `checksum` for http(s) File sources at runtime. What this
    # test can pin is the resource shape that caused the churn: the keyring
    # File must carry no http source. Runtime idempotency (second apply
    # against an unchanged key reports zero changes) is asserted on the
    # greenfield host.
    it 'manages keyring presence and permissions without an http source (the mtime-churning fetch path)' do
      is_expected.to contain_file('/etc/apt/keyrings/docker.asc')
        .with('ensure' => 'file', 'mode' => '0644')
        .without_source
        .without_checksum
      is_expected.to contain_file('/etc/apt/keyrings/gitlab-runner.asc')
        .with('ensure' => 'file', 'mode' => '0644')
        .without_source
        .without_checksum
    end

    context 'with custom repo locations and key sources' do
      let(:params) do
        super().merge(
          'docker_repo_location'          => 'https://mirror.example.org/docker/ubuntu',
          'docker_repo_key_source'        => 'https://mirror.example.org/docker/gpg',
          'gitlab_runner_repo_location'   => 'https://mirror.example.org/runner/ubuntu',
          'gitlab_runner_repo_key_source' => 'https://mirror.example.org/runner/gpgkey',
        )
      end

      it 'threads the overrides into the sources and keyring refreshes' do
        is_expected.to contain_apt__source('docker').with_location('https://mirror.example.org/docker/ubuntu')
        is_expected.to contain_apt__source('gitlab-runner').with_location('https://mirror.example.org/runner/ubuntu')
        is_expected.to contain_exec('rootless_gitlab_runner docker keyring refresh')
          .with_command(%r{download-file 'https://mirror\.example\.org/docker/gpg' '/var/cache/rootless_gitlab_runner/docker\.asc' && install -m 0644})
          .with_unless(%r{download-file 'https://mirror\.example\.org/docker/gpg' '/var/cache/rootless_gitlab_runner/docker\.asc' && cmp -s '/var/cache/rootless_gitlab_runner/docker\.asc' '/etc/apt/keyrings/docker\.asc'})
        is_expected.to contain_exec('rootless_gitlab_runner gitlab-runner keyring refresh')
          .with_command(%r{download-file 'https://mirror\.example\.org/runner/gpgkey' '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' && install -m 0644})
          .with_unless(%r{download-file 'https://mirror\.example\.org/runner/gpgkey' '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' && cmp -s '/var/cache/rootless_gitlab_runner/gitlab-runner\.asc' '/etc/apt/keyrings/gitlab-runner\.asc'})
      end
    end
  end

  # Drift gates: the committed examples must keep compiling against the real
  # parameter surface — a renamed or removed parameter fails here, not in a
  # consumer's first apply.
  context 'examples/data stays compilable' do
    let(:facts) { UBUNTU_FACTS }
    let(:params) { example_data_params }

    it { is_expected.to compile.with_all_deps }
  end

  context 'examples/data with examples/secrets.example.yaml resolves tokens' do
    let(:facts) { UBUNTU_FACTS }
    let(:params) do
      tokens = example_yaml('secrets.example.yaml')['rootless_gitlab_runner::tokens']
      example_data_params.merge('tokens' => sensitive(tokens))
    end

    it { is_expected.to compile.with_all_deps }

    it 'renders the referenced runner token into the config' do
      expect(rendered_config).to match(%r{glrt-REPLACE-WITH-RUNNER-TOKEN})
    end
  end

  context 'with packages listed' do
    let(:params) { { 'packages' => %w[uidmap dbus-user-session] } }

    it { is_expected.to contain_package('uidmap').with_ensure('installed') }
    it { is_expected.to contain_package('dbus-user-session').with_ensure('installed') }
  end

  context 'without runner_uid' do
    %w[manage_runner_user manage_rootless_docker manage_standalone_self_update].each do |toggle|
      context "with #{toggle} enabled" do
        let(:params) { { toggle => true } }

        it { is_expected.to compile.and_raise_error(%r{runner_uid must be set}) }
      end
    end

    context 'with a socket_mount runner' do
      let(:params) do
        { 'runners' => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                          'image' => 'i', 'socket_mount' => true }] }
      end

      it { is_expected.to compile.and_raise_error(%r{set runner_uid or docker_socket_path}) }
    end

    context 'with a privilege-dropped service and no derivable DOCKER_HOST' do
      let(:params) { { 'manage_runner_service' => true } }

      it { is_expected.to compile.and_raise_error(%r{needs DOCKER_HOST}) }
    end

    context 'with a secret store present and an unresolvable token_key' do
      let(:params) do
        { 'tokens'  => sensitive({ 'runner_a' => 'glrt-x' }),
          'runners' => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                          'image' => 'i', 'token_key' => 'runner_b' }] }
      end

      it { is_expected.to compile.and_raise_error(%r{token_key 'runner_b' of runner 'r' not found}) }
    end

    context 'with a secret store present and a runner missing its token_key' do
      let(:params) do
        { 'tokens'  => sensitive({ 'runner_a' => 'glrt-x' }),
          'runners' => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                          'image' => 'i' }] }
      end

      it { is_expected.to compile.and_raise_error(%r{runner 'r' has no token_key but the secret store is populated}) }
    end

    context 'with an unrecognised runner key' do
      let(:params) do
        { 'runners' => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                          'image' => 'i', 'privledged' => true }] }
      end

      it { is_expected.to compile.and_raise_error(%r{runner 'r' has unrecognised key\(s\) privledged}) }
    end
  end

  context 'with manage_runner_user' do
    let(:params) { { 'manage_runner_user' => true, 'runner_uid' => 4242 } }

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_group('gitlab-runner').with('ensure' => 'present', 'system' => true) }

    it 'owns the user with the declared uid and home' do
      is_expected.to contain_user('gitlab-runner').with(
        'ensure'     => 'present',
        'system'     => true,
        'uid'        => 4242,
        'home'       => '/home/gitlab-runner',
        'managehome' => true,
      )
    end

    %w[subuid subgid].each do |f|
      it "writes no #{f} entry (subids belong to manage_rootless_docker)" do
        is_expected.not_to contain_exec("rootless_gitlab_runner #{f} entry")
      end
    end
  end

  context 'with manage_rootless_docker' do
    let(:params) { { 'manage_rootless_docker' => true, 'runner_uid' => 4242 } }

    it { is_expected.to compile.with_all_deps }

    it 'enables lingering, guarded by the logind flag file' do
      is_expected.to contain_exec('rootless_gitlab_runner enable-linger').with(
        'command' => 'loginctl enable-linger gitlab-runner',
        'unless'  => 'test -e /var/lib/systemd/linger/gitlab-runner',
      )
    end

    # manage_runner_user stays off here, so this is the externally-owned-user
    # shape: the module provisions subids without owning the account.
    { 'subuid' => '--add-subuids', 'subgid' => '--add-subgids' }.each do |f, flag|
      it "provisions the #{f} range for the (possibly external) runner user, guarded by an existing entry" do
        is_expected.to contain_exec("rootless_gitlab_runner #{f} entry").with(
          'command' => "usermod #{flag} 231072-296607 gitlab-runner",
          'unless'  => "grep -q '^gitlab-runner:' /etc/#{f}",
        )
      end
    end

    it 'orders subid provisioning before the preflight that asserts it' do
      %w[subuid subgid].each do |f|
        is_expected.to contain_exec("rootless_gitlab_runner #{f} entry")
          .that_comes_before('Exec[rootless_gitlab_runner preflight]')
      end
    end

    it 'fails loud in the preflight: success in unless, exit 1 in command' do
      is_expected.to contain_exec('rootless_gitlab_runner preflight')
        .with_command(%r{exit 1})
        .with_unless(%r{test -x /usr/bin/newuidmap})
        .with_unless(%r{/etc/subuid})
        .with_unless(%r{/etc/subgid})
        .with_unless(%r{/var/lib/systemd/linger/gitlab-runner})
        .with_unless(%r{cgroup\.controllers})
    end

    it 'does not manage cgroup-v2 delegation' do
      is_expected.not_to contain_file('/etc/systemd/system/user@.service.d/delegate.conf')
      is_expected.not_to contain_file('/etc/systemd/system/user@.service.d')
    end

    it 'stops and masks the rootful system Docker daemon and the idle root containerd' do
      is_expected.to contain_service('docker.service').with('ensure' => 'stopped', 'enable' => 'mask')
      is_expected.to contain_service('docker.socket').with('ensure' => 'stopped', 'enable' => 'mask')
      is_expected.to contain_service('containerd.service').with('ensure' => 'stopped', 'enable' => 'mask')
    end

    it 'runs the install guarded on installed state (the user unit), not the prereq-only check' do
      is_expected.to contain_exec('rootless_gitlab_runner setuptool install').with(
        'command'     => '/usr/bin/dockerd-rootless-setuptool.sh install && test -f /home/gitlab-runner/.config/systemd/user/docker.service',
        'creates'     => '/home/gitlab-runner/.config/systemd/user/docker.service',
        'user'        => 'gitlab-runner',
        'provider'    => 'shell',
        'environment' => [
          'HOME=/home/gitlab-runner',
          'USER=gitlab-runner',
          'XDG_RUNTIME_DIR=/run/user/4242',
          'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/4242/bus',
        ],
      )
    end

    it 'fails loud when the setuptool exits 0 without creating the user unit' do
      is_expected.to contain_exec('rootless_gitlab_runner setuptool install')
        .with_command(%r{&& test -f /home/gitlab-runner/\.config/systemd/user/docker\.service$})
    end

    it 'starts and awaits the runner user session before the setuptool bring-up' do
      is_expected.to contain_exec('rootless_gitlab_runner await user session')
        .with_command(%r{^systemctl start user@4242\.service})
        .with_command(%r{until test -S /run/user/4242/bus})
        .with_unless('test -S /run/user/4242/bus')
        .with_provider('shell')
    end

    it 'orders linger -> preflight -> await session -> setuptool' do
      is_expected.to contain_exec('rootless_gitlab_runner preflight')
        .that_requires('Exec[rootless_gitlab_runner enable-linger]')
      is_expected.to contain_exec('rootless_gitlab_runner await user session')
        .that_requires('Exec[rootless_gitlab_runner preflight]')
      is_expected.to contain_exec('rootless_gitlab_runner setuptool install')
        .that_requires('Exec[rootless_gitlab_runner await user session]')
    end

    it 'makes the drop-in effective: reloads + restarts docker as the runner user on drop-in change' do
      is_expected.to contain_exec('rootless_gitlab_runner docker daemon-reload (no-detach-netns)').with(
        'command'     => 'systemctl --user daemon-reload && systemctl --user try-restart docker',
        'user'        => 'gitlab-runner',
        'refreshonly' => true,
        'environment' => [
          'HOME=/home/gitlab-runner',
          'USER=gitlab-runner',
          'XDG_RUNTIME_DIR=/run/user/4242',
          'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/4242/bus',
        ],
      ).that_subscribes_to('File[/home/gitlab-runner/.config/systemd/user/docker.service.d/no-detach-netns.conf]')
    end
  end

  context 'with manage_rootless_docker and manage_runner_user and a custom subid range' do
    let(:params) do
      { 'manage_rootless_docker' => true, 'manage_runner_user' => true,
        'runner_uid' => 4242, 'subid_start' => 300_000, 'subid_count' => 131_072 }
    end

    it { is_expected.to compile.with_all_deps }

    it 'renders the inclusive usermod range from subid_start/subid_count' do
      is_expected.to contain_exec('rootless_gitlab_runner subuid entry')
        .with_command('usermod --add-subuids 300000-431071 gitlab-runner')
      is_expected.to contain_exec('rootless_gitlab_runner subgid entry')
        .with_command('usermod --add-subgids 300000-431071 gitlab-runner')
    end
  end

  # Puppet turns exit 127 from an exec guard (`unless`/`onlyif`) into a raised
  # "Could not evaluate" error rather than a false condition, and dash — the
  # /bin/sh behind the shell provider on Ubuntu — exits 127 from a PATH probe
  # (`command -v`, `which`, `type`) on a missing binary, unlike bash's 1.
  # Guards must test host state (`test`, `grep`) and exit 0/1 only.
  context 'exec guard hygiene (all toggles on)' do
    # Facts pinned so manage_apt_repos (puppetlabs-apt needs Debian-family
    # facts) can join the sweep and its keyring-refresh guards are covered.
    let(:facts) { UBUNTU_FACTS }
    let(:params) do
      {
        'manage_runner_user'            => true,
        'manage_rootless_docker'        => true,
        'manage_runner_service'         => true,
        'manage_standalone_self_update' => true,
        'manage_apt_repos'              => true,
        'runner_uid'                    => 4242,
      }
    end

    it 'no exec guard probes the PATH' do
      execs = catalogue.resources.select { |r| r.type == 'Exec' }
      expect(execs).not_to be_empty
      execs.each do |ex|
        [ex[:unless], ex[:onlyif]].flatten.compact.each do |guard|
          expect(guard).not_to match(%r{\bcommand -v\b|\bwhich\b|\btype\b}),
                               "PATH probe in a guard of Exec[#{ex.title}]: #{guard}"
        end
      end
    end
  end

  context 'with manage_runner_service' do
    let(:params) { { 'manage_runner_service' => true, 'runner_uid' => 4242 } }

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_service('gitlab-runner').with('ensure' => 'running', 'enable' => true) }

    it 'owns /etc/gitlab-runner group-writable so the privilege-dropped manager can read config and write .runner_system_id' do
      is_expected.to contain_file('/etc/gitlab-runner').with(
        'ensure' => 'directory',
        'owner'  => 'root',
        'group'  => 'gitlab-runner',
        'mode'   => '0770',
      )
    end

    it 'owns .runner_system_id as the service user so the dropped manager can read the root-created file' do
      is_expected.to contain_file('/etc/gitlab-runner/.runner_system_id').with(
        'ensure' => 'file',
        'owner'  => 'gitlab-runner',
        'group'  => 'gitlab-runner',
        'mode'   => '0600',
      )
    end

    it 'restarts only on unit-file changes, never on a config change (no job-killing restart)' do
      is_expected.to contain_service('gitlab-runner')
        .with('subscribe' => ['Exec[rootless_gitlab_runner daemon-reload]'])
        .that_subscribes_to('Exec[rootless_gitlab_runner daemon-reload]')
    end

    it 'renders the privilege-drop drop-in with an ExecStart reset without --user' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^User=gitlab-runner$})
        .with_content(%r{^ExecStart=$})
        .with_content(%r{^ExecStart=/usr/bin/gitlab-runner run --working-directory /home/gitlab-runner --config /etc/gitlab-runner/config\.toml --service gitlab-runner$})
        .with_content(%r{^Environment=DOCKER_HOST=unix:///run/user/4242/docker\.sock$})
    end

    it 'defaults to a graceful-shutdown KillSignal=SIGQUIT and no TimeoutStopSec' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^KillSignal=SIGQUIT$})
        .without_content(%r{^TimeoutStopSec=})
    end

    context 'with a custom kill signal and stop timeout' do
      let(:params) { super().merge('service_kill_signal' => 'SIGTERM', 'service_timeout_stop_sec' => 7200) }

      it 'renders the configured KillSignal and TimeoutStopSec' do
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
          .with_content(%r{^KillSignal=SIGTERM$})
          .with_content(%r{^TimeoutStopSec=7200$})
      end
    end

    context 'with service_user root' do
      let(:params) { super().merge('service_user' => 'root') }

      it 'keeps the packaged posture: no User=, no ExecStart reset' do
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
          .without_content(%r{^User=})
          .without_content(%r{^ExecStart=})
      end

      it 'still applies the graceful-shutdown KillSignal (independent of privilege drop)' do
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
          .with_content(%r{^KillSignal=SIGQUIT$})
      end
    end
  end

  context 'with manage_standalone_self_update' do
    let(:params) { { 'manage_standalone_self_update' => true, 'runner_uid' => 4242 } }

    it { is_expected.to compile.with_all_deps }

    it 'ships the apply script with isolated state and the r10k tick' do
      is_expected.to contain_file('/usr/local/sbin/rootless-gitlab-runner-apply')
        .with_mode('0755')
        .with_content(%r{r10k puppetfile install})
        .with_content(%r{--confdir "/etc/gitlab-runner-infra/puppet"})
        .with_content(%r{--vardir "/var/lib/grunner-puppet"})
        .with_content(%r{--detailed-exitcodes})
        .with_content(%r{"/opt/gitlab-runner-infra/puppet/manifests/site\.pp"})
    end

    it 'renders the apply service: HOME=/root, PATH to the AIO bindir, timeout, verify-commit, exit 2 = success' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
        .with_content(%r{^Environment=HOME=/root$})
        .with_content(%r{^Environment="PATH=/opt/puppetlabs/bin:/usr/bin:/bin"$})
        .with_content(%r{^TimeoutStartSec=15min$})
        .with_content(%r{verify-commit origin/main$})
        .with_content(%r{^SuccessExitStatus=2$})
    end

    it 'asserts (not silently skips) the managed script exists on both units' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
        .with_content(%r{^AssertPathExists=/usr/local/sbin/rootless-gitlab-runner-apply$})
        .without_content(%r{ConditionPathExists})
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-healthcheck.service')
        .with_content(%r{^AssertPathExists=/usr/local/sbin/rootless-gitlab-runner-healthcheck$})
        .without_content(%r{ConditionPathExists})
    end

    it 'renders the apply timer with the configured interval and no no-op Persistent=' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.timer')
        .with_content(%r{^OnUnitActiveSec=5min$})
    end

    it 'drops the no-op Persistent= from both timers (no effect with OnUnitActiveSec=)' do
      ['gitlab-runner-apply.timer', 'gitlab-runner-healthcheck.timer'].each do |t|
        is_expected.to contain_file("/etc/systemd/system/#{t}").without_content(%r{Persistent})
      end
    end

    it 'renders no OnFailure hook by default' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
        .without_content(%r{OnFailure})
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-healthcheck.service')
        .without_content(%r{OnFailure})
    end

    context 'with an on_failure_unit alerting hook' do
      let(:params) { super().merge('on_failure_unit' => 'notify-failure@%n.service') }

      it 'renders OnFailure= on both the apply and healthcheck services' do
        ['gitlab-runner-apply.service', 'gitlab-runner-healthcheck.service'].each do |u|
          is_expected.to contain_file("/etc/systemd/system/#{u}")
            .with_content(%r{^OnFailure=notify-failure@%n\.service$})
        end
      end
    end

    it 'renders the healthcheck with daemon probe, apply-timer and SHA-staleness assertions' do
      is_expected.to contain_file('/usr/local/sbin/rootless-gitlab-runner-healthcheck')
        .with_mode('0755')
        .with_content(%r{docker info})
        .with_content(%r{runuser -u 'gitlab-runner'})
        .with_content(%r{XDG_RUNTIME_DIR=/run/user/4242})
        .with_content(%r{is-enabled --quiet gitlab-runner-apply\.timer})
        .with_content(%r{is-active --quiet gitlab-runner-apply\.timer})
        .with_content(%r{ls-remote origin 'refs/heads/main'})
        .with_content(%r{checkout is stale})
    end

    %w[gitlab-runner-apply.timer gitlab-runner-healthcheck.timer].each do |t|
      it "runs and enables #{t}, subscribed to its unit files" do
        is_expected.to contain_service(t).with('ensure' => 'running', 'enable' => true)
          .that_subscribes_to("File[/etc/systemd/system/#{t}]")
      end
    end
  end

  context 'private classes' do
    describe 'direct inclusion is refused' do
      let(:pre_condition) { 'include rootless_gitlab_runner::config' }

      it { is_expected.to compile.and_raise_error(%r{is private}) }
    end
  end

  context 'with runner_defaults' do
    let(:params) do
      {
        'runner_defaults' => { 'url' => 'https://gitlab.example.org/', 'executor' => 'docker',
                               'image' => 'ubuntu:22.04' },
        'runners'         => [
          { 'name' => 'a' },
          { 'name' => 'b', 'image' => 'alpine:3.20' },
        ],
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'merges the defaults under every runner entry' do
      expect(rendered_config).to match(%r{name = "a"\n  url = "https://gitlab\.example\.org/"})
      expect(rendered_config).to match(%r{name = "b"\n  url = "https://gitlab\.example\.org/"})
      expect(rendered_config).to match(%r{image = "ubuntu:22\.04"})
    end

    it 'lets keys set on the entry win over the defaults' do
      expect(rendered_config).to match(%r{image = "alpine:3\.20"})
      expect(rendered_config).not_to match(%r{name = "b".*image = "ubuntu:22\.04"}m)
    end

    it 'renders no cache tables when a runner sets none' do
      expect(rendered_config).not_to match(%r{\[runners\.cache\]})
    end
  end

  context 'golden file: full two-runner config' do
    let(:params) do
      {
        'runner_uid' => 4242,
        'tokens'     => sensitive({ 'runner_a' => 'glrt-GOLDEN-TOKEN-A',
                                    'runner_b' => 'glrt-GOLDEN-TOKEN-B' }),
        # url + executor deliberately live in runner_defaults: the golden file
        # must render byte-identical, proving the merge changes nothing.
        'runner_defaults' => { 'url' => 'https://gitlab.example.org/', 'executor' => 'docker' },
        # Every documented runner key set to a non-default value across the two
        # runners, so a mutation to any exercised template line (e.g. hard-wiring
        # privileged to false) breaks the byte-exact render.
        'runners'    => [
          {
            'name'                         => 'socket-runner',
            'id'                           => 42,
            'token_key'                    => 'runner_a',
            'image'                        => 'ubuntu:22.04',
            'socket_mount'                 => true,
            'privileged'                   => true,
            'disable_entrypoint_overwrite' => true,
            'oom_kill_disable'             => true,
            'disable_cache'                => true,
            'shm_size'                     => 300_000_000,
            'network_mtu'                  => 1400,
            'helper_image'                 => 'gitlab/gitlab-runner-helper:x86_64-v16.11.0',
            'volumes'                      => ['/cache'],
            'environment'                  => ['BUILDX_NO_DEFAULT_ATTESTATIONS=1'],
            'comment'                      => 'Example socket runner',
            'security_opt'                 => ['seccomp=unconfined'],
            'allowed_images'               => ['ruby:*', 'python:*'],
            'allowed_pull_policies'        => ['always', 'if-not-present'],
            'cache'                        => { 'MaxUploadedArchiveSize' => 100 },
          },
          {
            'name'       => 'remote-runner',
            'token_key'  => 'runner_b',
            'image'      => 'alpine:3.20',
            'host'       => 'tcp://docker-daemon:2375',
            'tls_verify' => true,
            'cache'      => {},
          },
        ],
      }
    end

    it 'renders exactly the golden config.toml' do
      golden = File.read(File.join(__dir__, '..', 'fixtures', 'golden', 'config.toml.golden'))
      expect(rendered_config).to eq(golden)
    end
  end

  context 'rendered shell scripts (golden + shellcheck)' do
    let(:params) { { 'manage_standalone_self_update' => true, 'runner_uid' => 4242 } }

    {
      '/usr/local/sbin/rootless-gitlab-runner-apply'       => 'apply.sh.golden',
      '/usr/local/sbin/rootless-gitlab-runner-healthcheck' => 'healthcheck.sh.golden',
    }.each do |path, golden|
      describe path do
        it "renders exactly #{golden}" do
          expected = File.read(File.join(__dir__, '..', 'fixtures', 'golden', golden))
          expect(rendered_file(path)).to eq(expected)
        end

        it 'passes shellcheck' do
          skip 'shellcheck not on PATH' unless system('command -v shellcheck >/dev/null 2>&1')

          require 'open3'
          out, status = Open3.capture2e('shellcheck', '--shell=bash', '-', stdin_data: rendered_file(path))
          expect(status).to be_success, out
        end
      end
    end
  end

  context 'hostile input is escaped or rejected' do
    context 'a runner field carrying a quote and a newline TOML-injection payload' do
      let(:params) do
        {
          'runners' => [{
            'name'     => 'r',
            'url'      => 'https://gitlab.example.org/',
            'executor' => 'docker',
            'image'    => "ubuntu\"\nprivileged = true\n",
            'comment'  => "first line\nprivileged = true",
          }],
        }
      end

      it { is_expected.to compile.with_all_deps }

      it 'escapes the quote and newline rather than opening a bare TOML key' do
        # If the value were interpolated raw, the embedded newline would open a
        # top-level `privileged = true` at column 0 — assert it never does.
        expect(rendered_config).not_to match(%r{^privileged = true$})
        # The crafted value is written escaped, on the image line, between quotes.
        expect(rendered_config).to include('image = "ubuntu\"\nprivileged = true\n"')
      end

      it 'collapses a newline in a comment onto its single comment line' do
        expect(rendered_config).to include('# first line privileged = true')
      end
    end

    context 'a runner_user with shell-hostile characters' do
      let(:params) { { 'runner_user' => 'ev il"; rm -rf' } }

      it { is_expected.to compile.and_raise_error(%r{runner_user}) }
    end

    context 'a service_environment line containing a newline' do
      let(:params) do
        {
          'manage_runner_service' => true,
          'runner_uid'            => 2000,
          'service_environment'   => ["DOCKER_HOST=unix:///run/x\nExecStartPre=/bin/evil"],
        }
      end

      it { is_expected.to compile.and_raise_error(%r{service_environment}) }
    end
  end
end
