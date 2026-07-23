require 'spec_helper'
require 'yaml'
require 'deep_merge'

# rspec-puppet exposes no matcher for compile-time warning() output, so a
# registered Puppet log destination collects warning messages for the sub-ID
# advisory tests (see the module_warnings helper). Module-global by Puppet's
# design; the helper clears it before each capture.
RGR_WARNINGS = [] # rubocop:disable Style/MutableConstant
Puppet::Util::Log.newdesttype(:rgr_capture) do
  def handle(msg)
    RGR_WARNINGS << msg.message if msg.level == :warning
  end
end

# puppetlabs-apt compiles only on Debian-family facts; the suite otherwise runs
# factless, so the apt-enabled and example contexts pin the single supported
# OS's facts. Derived from metadata.json via rspec-puppet-facts / facterdb (one
# fact source, not a hand-maintained hash), so the fact set follows metadata.
UBUNTU_FACTS = on_supported_os.values.first.freeze

# Every parameter default lives in the module data layer; rspec params are
# resource-style and bypass Hiera's deep merge, so struct params built here
# merge their overrides over the module defaults the same way Hiera would.
MODULE_DATA = YAML.safe_load(
  File.read(File.expand_path(File.join(__dir__, '..', '..', 'data', 'common.yaml'))),
).freeze

describe 'rootless_gitlab_runner' do
  # The rendered content of any managed File resource (unwrapped if Sensitive).
  def rendered_file(path)
    content = catalogue.resource('File', path)[:content]
    content.respond_to?(:unwrap) ? content.unwrap : content
  end

  # config.toml content is Sensitive (it carries tokens); rendered_file unwraps
  # it for byte and pattern assertions. The path is the module default.
  def rendered_config
    rendered_file('/etc/gitlab-runner/config.toml')
  end

  # Load and parse a YAML file from examples/.
  def example_yaml(*path)
    YAML.safe_load(File.read(File.expand_path(File.join(__dir__, '..', '..', 'examples', *path))))
  end

  # rspec-puppet serializes a Ruby nil param value as the literal string
  # "nil"; a YAML `~` default must reach Puppet as undef instead.
  def undefize(value)
    case value
    when Hash then value.transform_values { |v| undefize(v) }
    when nil then :undef
    else value
    end
  end

  # A struct parameter's module-data default with overrides merged deep over
  # it, mirroring the deep-merge lookup_options a Hiera consumer gets (strategy:
  # deep, knockout_prefix: '--'): scalars from the override win, sub-hashes
  # merge recursively, arrays union across layers, and a '--'-prefixed element
  # knocks the matching one out. Uses the same deep_merge gem Hiera's deep
  # strategy is built on, so struct_param merges the way Hiera would rather than
  # replacing whole arrays. Both operands are deep-copied first: deep_merge!
  # mutates its destination, and MODULE_DATA must stay pristine across calls.
  def struct_param(name, overrides = {})
    base = Marshal.load(Marshal.dump(MODULE_DATA.fetch("rootless_gitlab_runner::#{name}")))
    undefize(DeepMerge.deep_merge!(Marshal.load(Marshal.dump(overrides)), base, knockout_prefix: '--'))
  end

  # The common runner_account shape: a derivable uid (the socket path derives
  # from it) plus any extra keys. Most contexts need only the uid.
  def account_with_uid(uid, extra = {})
    struct_param('runner_account', { 'uid' => uid }.merge(extra))
  end

  # A structured subid fact for the runner user (and optionally foreign owners),
  # the shape lib/puppet_x/rootless_gitlab_runner/subids.rb produces. Both files
  # carry the runner ranges; `others` adds foreign owners for the overlap case.
  def subid_facts(runner_ranges, others = {})
    owners = { 'gitlab-runner' => runner_ranges }.merge(others)
    { 'rootless_gitlab_runner_subids' => { 'subuid' => owners, 'subgid' => owners } }
  end

  # This module's compile-time warning() lines. Attach the capture destination,
  # force the one memoized compile, then filter to the module's own messages.
  # Call before any other catalogue access in the example, so the destination is
  # live when warnings fire (rspec-puppet caches the catalog, compiling once).
  def module_warnings
    RGR_WARNINGS.clear
    Puppet::Util::Log.newdestination(:rgr_capture)
    catalogue
    RGR_WARNINGS.grep(/\Arootless_gitlab_runner:/)
  ensure
    Puppet::Util::Log.close(:rgr_capture)
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

    it 'manages the runner configuration file owned by the runner account, fixed mode 0600' do
      is_expected.to contain_file('/etc/gitlab-runner/config.toml').with(
        'ensure' => 'file',
        'owner'  => 'gitlab-runner',
        'group'  => 'gitlab-runner',
        'mode'   => '0600',
      )
    end

    it 'wraps the rendered configuration content Sensitive so tokens stay out of the catalog' do
      # A Sensitive-wrapped parameter lands in the catalog as the raw value
      # flagged sensitive — the flag is what redacts it from reports and diffs.
      expect(catalogue.resource('File', '/etc/gitlab-runner/config.toml').sensitive_parameters)
        .to include(:content)
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
      is_expected.not_to contain_file('/usr/local/sbin/rootless-gitlab-runner-apply')
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

  context 'with an unknown struct subkey' do
    let(:params) { { 'runner_account' => struct_param('runner_account', 'nmae' => 'typo') } }

    it 'fails the compile naming the unrecognised key' do
      is_expected.to compile.and_raise_error(%r{runner_account.*nmae}m)
    end
  end

  context 'with an unknown nested struct subkey' do
    let(:params) do
      { 'packages' => struct_param('packages', 'sources' => { 'dokcer' => { 'location' => 'https://x/' } }) }
    end

    it 'fails the compile naming the unrecognised key' do
      is_expected.to compile.and_raise_error(%r{packages.*dokcer}m)
    end
  end

  context 'with packages.sources.manage' do
    # puppetlabs-apt compiles only on Debian-family facts; the suite otherwise
    # runs factless, so this context pins the supported OS fact set (reused).
    let(:facts) { UBUNTU_FACTS }
    let(:params) { { 'packages' => struct_param('packages', 'sources' => { 'manage' => true }) } }

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

    context 'with mirror locations and key sources' do
      let(:params) do
        {
          'packages' => struct_param('packages', 'sources' => {
            'manage'        => true,
            'docker'        => { 'location'   => 'https://mirror.example.org/docker/ubuntu',
                                 'key_source' => 'https://mirror.example.org/docker/gpg' },
            'gitlab_runner' => { 'location'   => 'https://mirror.example.org/runner/ubuntu',
                                 'key_source' => 'https://mirror.example.org/runner/gpgkey' },
          }),
        }
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
  # parameter surface, resolved through Hiera itself (automatic parameter
  # lookup + the module's deep-merge lookup_options) — the consumption path a
  # control repository uses, which resource-style params would bypass.
  context 'examples/data resolves through Hiera' do
    let(:facts) { UBUNTU_FACTS }
    let(:hiera_config) { File.expand_path(File.join(__dir__, '..', 'fixtures', 'hiera', 'examples.yaml')) }

    it { is_expected.to compile.with_all_deps }

    it 'deep-merges the partial example structs over the module defaults' do
      # The example node sets only sources.manage; the vendor locations come
      # from the module data layer underneath.
      is_expected.to contain_apt__source('docker').with_location('https://download.docker.com/linux/ubuntu')
      # The example sets only manage + uid on runner_account; name and home
      # come from the module defaults.
      is_expected.to contain_user('gitlab-runner').with('uid' => 2000, 'home' => '/home/gitlab-runner')
    end

    it 'installs the apply script for the declared-standalone example host' do
      is_expected.to contain_file('/usr/local/sbin/rootless-gitlab-runner-apply')
        .with_content(%r{"/opt/runner-infra/puppet/manifests/site\.pp"})
    end

    context 'with examples/secrets.example.yaml tokens' do
      let(:params) do
        tokens = example_yaml('secrets.example.yaml')['rootless_gitlab_runner::runner_tokens']
        { 'runner_tokens' => sensitive(tokens) }
      end

      it 'renders the referenced runner token into the configuration' do
        expect(rendered_config).to match(%r{glrt-REPLACE-WITH-RUNNER-TOKEN})
      end
    end
  end

  # The shipped example data is held to the same rule the data-versus-surface
  # check (scripts/check_hiera_data.rb) enforces on a consumer repository:
  # every rootless_gitlab_runner:: key under examples/data/ must name a
  # declared parameter of the compiled class — Hiera silently ignores any
  # other key, so a stale example would teach consumers an inert key.
  context 'examples/data keys match the declared parameter surface' do
    let(:facts) { UBUNTU_FACTS }
    let(:hiera_config) { File.expand_path(File.join(__dir__, '..', 'fixtures', 'hiera', 'examples.yaml')) }

    it 'declares every rootless_gitlab_runner:: key set under examples/data' do
      declared = catalogue.resource('Class', 'rootless_gitlab_runner').parameters.keys.map(&:to_s)
      example_files = Dir.glob(File.expand_path(File.join(__dir__, '..', '..', 'examples', 'data', '**', '*.{yaml,eyaml}')))
      expect(example_files).not_to be_empty
      strays = example_files
               .flat_map { |f| YAML.safe_load(File.read(f)).to_h.keys }
               .select { |k| k.start_with?('rootless_gitlab_runner::') }
               .map { |k| k.delete_prefix('rootless_gitlab_runner::') }
               .reject { |param| declared.include?(param) }
      expect(strays).to be_empty
    end
  end

  # The deep-merge contract end to end, through a consumer-shaped hierarchy:
  # partial consumer hashes pick up the rest of each struct from the module
  # data layer; a scalar subkey set higher in the hierarchy wins; the knockout
  # prefix removes a subkey a lower layer set; and a plain-YAML token store is
  # wrapped Sensitive by the module's convert_to rule.
  context 'a partial consumer hash through a Hiera hierarchy' do
    let(:node) { 'deep-merge.example.org' }
    let(:hiera_config) { File.expand_path(File.join(__dir__, '..', 'fixtures', 'hiera', 'deep_merge.yaml')) }

    it { is_expected.to compile.with_all_deps }

    it 'fills the unset struct subkeys from the module defaults' do
      # The consumer layer sets only rootless_docker.manage and the account
      # uid: the subid range comes from the module defaults (231072 wide
      # 165536), the account name from the module default.
      is_expected.to contain_exec('rootless_gitlab_runner subuid entry')
        .with_command('usermod --add-subuids 231072-396607 gitlab-runner')
    end

    it 'lets the node layer override a common-layer scalar subkey' do
      # The common layer sets uid 2000; the node layer's 4242 wins.
      is_expected.to contain_exec('rootless_gitlab_runner await user session')
        .with_unless('test -S /run/user/4242/bus')
    end

    it 'unions array subkeys across layers and removes an element via the knockout prefix' do
      # environment is set in both layers: the common TRACE=1 survives the union,
      # while the node layer's '--DEBUG=1' removes the common DEBUG=1. DOCKER_HOST
      # is module-owned and renders from the merged uid (4242) alongside it.
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^Environment=DOCKER_HOST=unix:///run/user/4242/docker\.sock$})
        .with_content(%r{^Environment=TRACE=1$})
        .without_content(%r{DEBUG=1})
    end

    it 'wraps a plain-YAML token store Sensitive on lookup and renders the token' do
      expect(catalogue.resource('File', '/etc/gitlab-runner/config.toml').sensitive_parameters)
        .to include(:content)
      expect(rendered_config).to match(%r{token = "glrt-DEEP-MERGE-TOKEN"})
    end
  end

  # #26: a fleet layer sets an environment line, the node layer removes it with
  # the '--' knockout prefix, and the deep merge yields an empty array. Because
  # DOCKER_HOST is module-owned, the derived line renders regardless, so an
  # emptied environment can no longer leave the managed service without a socket.
  context 'an environment emptied through the knockout prefix' do
    let(:node) { 'empty-env.example.org' }
    let(:hiera_config) { File.expand_path(File.join(__dir__, '..', 'fixtures', 'hiera', 'empty_environment.yaml')) }

    it { is_expected.to compile.with_all_deps }

    it 'still renders the derived DOCKER_HOST when environment empties to []' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^Environment=DOCKER_HOST=unix:///run/user/2000/docker\.sock$})
        .without_content(%r{DEBUG=1})
    end
  end

  context 'with packages listed' do
    let(:params) { { 'packages' => struct_param('packages', 'install' => %w[uidmap dbus-user-session]) } }

    it { is_expected.to contain_package('uidmap').with_ensure('installed') }
    it { is_expected.to contain_package('dbus-user-session').with_ensure('installed') }
  end

  context 'with self_update.manage but standalone.manage off' do
    let(:params) do
      { 'standalone' => struct_param('standalone', 'self_update' => { 'manage' => true }) }
    end

    it 'fails the compile: the loop is contained in the standalone topology' do
      is_expected.to compile.and_raise_error(%r{standalone\.self_update\.manage requires\s+standalone\.manage})
    end
  end

  context 'without runner_account.uid' do
    {
      'runner_account.manage'  => { 'runner_account' => { 'manage' => true } },
      'rootless_docker.manage' => { 'rootless_docker' => { 'manage' => true } },
      'self_update.manage'     => { 'standalone' => { 'manage' => true, 'self_update' => { 'manage' => true } } },
    }.each do |toggle, overrides|
      context "with #{toggle} enabled" do
        let(:params) { overrides.to_h { |name, over| [name, struct_param(name, over)] } }

        it { is_expected.to compile.and_raise_error(%r{runner_account\.uid must be set}) }
      end
    end

    context 'with a socket_mount runner' do
      let(:params) do
        { 'runners' => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                          'image' => 'i', 'socket_mount' => true }] }
      end

      it { is_expected.to compile.and_raise_error(%r{set runner_account\.uid}) }
    end

    context 'with the runner service managed' do
      let(:params) { { 'runner_service' => struct_param('runner_service', 'manage' => true) } }

      it { is_expected.to compile.and_raise_error(%r{runner_service\.manage requires runner_account\.uid}) }
    end

    context 'with a secret store present and an unresolvable token_key' do
      let(:params) do
        { 'runner_tokens' => sensitive({ 'runner_a' => 'glrt-x' }),
          'runners'       => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
                                'image' => 'i', 'token_key' => 'runner_b' }] }
      end

      it { is_expected.to compile.and_raise_error(%r{token_key 'runner_b' of runner 'r' not found}) }
    end

    context 'with a secret store present and a runner missing its token_key' do
      let(:params) do
        { 'runner_tokens' => sensitive({ 'runner_a' => 'glrt-x' }),
          'runners'       => [{ 'name' => 'r', 'url' => 'https://x/', 'executor' => 'docker',
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

  context 'with runner_account.manage' do
    let(:params) { { 'runner_account' => account_with_uid(4242, 'manage' => true) } }

    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_group('gitlab-runner').with('ensure' => 'present', 'system' => true) }

    it 'owns the user with the declared uid and home, primary group defaulting to the name' do
      is_expected.to contain_user('gitlab-runner').with(
        'ensure'     => 'present',
        'system'     => true,
        'uid'        => 4242,
        'gid'        => 'gitlab-runner',
        'home'       => '/home/gitlab-runner',
        'managehome' => true,
      ).that_requires('Group[gitlab-runner]')
    end

    %w[subuid subgid].each do |f|
      it "writes no #{f} entry (subids belong to rootless_docker.manage)" do
        is_expected.not_to contain_exec("rootless_gitlab_runner #{f} entry")
      end
    end
  end

  # runner_account.group names the account's primary group; unset it defaults
  # to the account name. With manage on, the module creates that group and sets
  # it as the user's primary group instead of a same-named group.
  context 'with runner_account.manage and a differently named primary group' do
    let(:params) do
      { 'runner_account' => account_with_uid(4242, 'manage' => true, 'group' => 'ci') }
    end

    it { is_expected.to compile.with_all_deps }

    it 'creates the named group and sets it as the user primary group, not the account name' do
      is_expected.to contain_group('ci').with('ensure' => 'present', 'system' => true)
      is_expected.not_to contain_group('gitlab-runner')
      is_expected.to contain_user('gitlab-runner').with('gid' => 'ci').that_requires('Group[ci]')
    end
  end

  context 'with rootless_docker.manage' do
    let(:params) do
      { 'rootless_docker' => struct_param('rootless_docker', 'manage' => true),
        'runner_account'  => account_with_uid(4242) }
    end

    it { is_expected.to compile.with_all_deps }

    it 'enables lingering, guarded by the logind flag file' do
      is_expected.to contain_exec('rootless_gitlab_runner enable-linger').with(
        'command' => 'loginctl enable-linger gitlab-runner',
        'unless'  => 'test -e /var/lib/systemd/linger/gitlab-runner',
      )
    end

    # runner_account.manage stays off here, so this is the externally-owned
    # account shape: the module provisions subids without owning the account.
    # The range is the module default: start 231072, width 165536.
    { 'subuid' => '--add-subuids', 'subgid' => '--add-subgids' }.each do |f, flag|
      it "provisions the #{f} range for the (possibly external) runner user, guarded by an existing entry" do
        is_expected.to contain_exec("rootless_gitlab_runner #{f} entry").with(
          'command' => "usermod #{flag} 231072-396607 gitlab-runner",
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

  context 'with rootless_docker.manage, runner_account.manage and a custom subid range' do
    let(:params) do
      { 'rootless_docker' => struct_param('rootless_docker', 'manage' => true,
                                                            'subid_start' => 300_000, 'subid_count' => 131_072),
        'runner_account'  => account_with_uid(4242, 'manage' => true) }
    end

    it { is_expected.to compile.with_all_deps }

    it 'renders the inclusive usermod range from subid_start/subid_count' do
      is_expected.to contain_exec('rootless_gitlab_runner subuid entry')
        .with_command('usermod --add-subuids 300000-431071 gitlab-runner')
      is_expected.to contain_exec('rootless_gitlab_runner subgid entry')
        .with_command('usermod --add-subgids 300000-431071 gitlab-runner')
    end
  end

  # sub-ID minimum-width enforcement. The structured subid fact makes /etc/subuid
  # and /etc/subgid state visible to the catalog, so the class decides create /
  # widen / advise from real host state that rspec and --noop cannot see. Each
  # case supplies the fact directly.
  context 'with rootless_docker.manage and a fact-visible subid state' do
    let(:base_params) do
      { 'rootless_docker' => struct_param('rootless_docker', 'manage' => true),
        'runner_account'  => account_with_uid(4242) }
    end

    context 'a module-owned range narrower than declared' do
      let(:params) { base_params }
      let(:facts)  { subid_facts([{ 'start' => 231_072, 'count' => 65_536 }]) }

      { 'subuid' => ['--del-subuids', '--add-subuids'],
        'subgid' => ['--del-subgids', '--add-subgids'] }.each do |f, (del, add)|
        it "widens #{f} in place with a literal usermod, guarded on the exact current line" do
          is_expected.to contain_exec("rootless_gitlab_runner #{f} widen").with(
            'command'  => "usermod #{del} 231072-296607 #{add} 231072-396607 gitlab-runner",
            'onlyif'   => "grep -qxF 'gitlab-runner:231072:65536' /etc/#{f}",
            'provider' => 'shell',
          ).that_comes_before('Exec[rootless_gitlab_runner preflight]')
        end

        it "fires the rootless-daemon restart from the #{f} widen" do
          is_expected.to contain_exec("rootless_gitlab_runner #{f} widen")
            .that_notifies('Exec[rootless_gitlab_runner rootless docker restart (subid widen)]')
        end
      end

      it 'restarts the rootless daemon refreshonly as the runner user, after bring-up' do
        is_expected.to contain_exec('rootless_gitlab_runner rootless docker restart (subid widen)').with(
          'command'     => 'systemctl --user try-restart docker',
          'user'        => 'gitlab-runner',
          'refreshonly' => true,
          'environment' => [
            'HOME=/home/gitlab-runner',
            'USER=gitlab-runner',
            'XDG_RUNTIME_DIR=/run/user/4242',
            'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/4242/bus',
          ],
        ).that_requires('Exec[rootless_gitlab_runner setuptool install]')
      end

      it 'sums against the declared count in the preflight' do
        is_expected.to contain_exec('rootless_gitlab_runner preflight')
          .with_unless(%r{-v need=165536 '\$1==u\{sum\+=\$3\} END\{exit !\(sum>=need\)\}' /etc/subuid})
          .with_command(%r{subuid\+subgid totalling >= 165536 for gitlab-runner})
      end

      it 'emits no advisory while it converges the range' do
        expect(module_warnings).to be_empty
      end
    end

    context 'an exact-match range' do
      let(:params) { base_params }
      let(:facts)  { subid_facts([{ 'start' => 231_072, 'count' => 165_536 }]) }

      it 'declares no widen and stays silent' do
        expect(module_warnings).to be_empty
        %w[subuid subgid].each do |f|
          is_expected.not_to contain_exec("rootless_gitlab_runner #{f} widen")
        end
      end
    end

    context 'a module-owned range wider than declared' do
      let(:params) { base_params }
      let(:facts)  { subid_facts([{ 'start' => 231_072, 'count' => 262_144 }]) }

      it 'never shrinks it: no widen, and a wider-than-declared warning' do
        expect(module_warnings).to include(
          match(%r{/etc/subuid grants gitlab-runner 231072:262144, wider than the declared subid_count 165536}),
        )
        is_expected.not_to contain_exec('rootless_gitlab_runner subuid widen')
      end
    end

    context 'a foreign-start range wide enough in sum' do
      let(:params) { base_params }
      let(:facts)  { subid_facts([{ 'start' => 500_000, 'count' => 200_000 }]) }

      it 'leaves it untouched and warns that data does not mirror the host' do
        expect(module_warnings).to include(
          match(%r{/etc/subuid for gitlab-runner does not mirror the declared range 231072:165536}),
        )
        is_expected.not_to contain_exec('rootless_gitlab_runner subuid widen')
      end
    end

    context 'a foreign-start range too narrow' do
      let(:params) { base_params }
      let(:facts)  { subid_facts([{ 'start' => 500_000, 'count' => 1000 }]) }

      it 'stays silent at compile time: the preflight fails loud instead' do
        expect(module_warnings).to be_empty
        is_expected.not_to contain_exec('rootless_gitlab_runner subuid widen')
      end
    end

    context 'the declared range overlapping another user' do
      let(:params) { base_params }
      let(:facts) do
        subid_facts([{ 'start' => 231_072, 'count' => 165_536 }],
                    'sophie' => [{ 'start' => 300_000, 'count' => 65_536 }])
      end

      it 'warns that the two users would share container UIDs' do
        expect(module_warnings).to include(
          match(%r{declared range 231072-396607 overlaps sophie's 300000-365535 in /etc/subuid}),
        )
      end
    end
  end

  context 'with rootless_docker.manage, a custom declared range and a narrower host range' do
    let(:params) do
      { 'rootless_docker' => struct_param('rootless_docker', 'manage' => true,
                                                            'subid_start' => 300_000, 'subid_count' => 200_000),
        'runner_account'  => account_with_uid(4242, 'manage' => true) }
    end
    let(:facts) { subid_facts([{ 'start' => 300_000, 'count' => 70_000 }]) }

    it 'computes both inclusive bounds from the fact width and the declared width' do
      is_expected.to contain_exec('rootless_gitlab_runner subuid widen')
        .with_command('usermod --del-subuids 300000-369999 --add-subuids 300000-499999 gitlab-runner')
        .with_onlyif("grep -qxF 'gitlab-runner:300000:70000' /etc/subuid")
    end

    it 'carries the declared non-default count into the summed preflight' do
      is_expected.to contain_exec('rootless_gitlab_runner preflight')
        .with_unless(%r{-v need=200000 '\$1==u\{sum\+=\$3\} END\{exit !\(sum>=need\)\}' /etc/subuid})
        .with_command(%r{subuid\+subgid totalling >= 200000})
    end
  end

  # Puppet turns exit 127 from an exec guard (`unless`/`onlyif`) into a raised
  # "Could not evaluate" error rather than a false condition, and dash — the
  # /bin/sh behind the shell provider on Ubuntu — exits 127 from a PATH probe
  # (`command -v`, `which`, `type`) on a missing binary, unlike bash's 1.
  # Guards must test host state (`test`, `grep`) and exit 0/1 only.
  context 'exec guard hygiene (all toggles on)' do
    # Facts pinned so packages.sources.manage (puppetlabs-apt needs
    # Debian-family facts) can join the sweep and its keyring-refresh guards
    # are covered.
    let(:facts) { UBUNTU_FACTS }
    let(:params) do
      {
        'runner_account'  => account_with_uid(4242, 'manage' => true),
        'rootless_docker' => struct_param('rootless_docker', 'manage' => true),
        'runner_service'  => struct_param('runner_service', 'manage' => true),
        'packages'        => struct_param('packages', 'sources' => { 'manage' => true }),
        'standalone'      => struct_param('standalone', 'manage' => true, 'self_update' => { 'manage' => true }),
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

  context 'with runner_service.manage' do
    let(:params) do
      { 'runner_service' => struct_param('runner_service', 'manage' => true),
        'runner_account' => account_with_uid(4242) }
    end

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

    it 'owns .runner_system_id as the runner account so the dropped manager can read the root-created file' do
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

    it 'hardcodes the graceful-shutdown KillSignal=SIGQUIT and renders no TimeoutStopSec by default' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^KillSignal=SIGQUIT$})
        .without_content(%r{^TimeoutStopSec=})
    end

    context 'with a stop timeout for long drains' do
      let(:params) do
        super().merge('runner_service' => struct_param('runner_service', 'manage' => true,
                                                                         'timeout_stop_sec' => 7200))
      end

      it 'renders the configured TimeoutStopSec and keeps the fixed KillSignal' do
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
          .with_content(%r{^KillSignal=SIGQUIT$})
          .with_content(%r{^TimeoutStopSec=7200$})
      end
    end
  end

  # runner_service.environment is a passthrough for additional Environment=
  # lines; DOCKER_HOST is module-owned and rendered from the uid, so it renders
  # alongside the passthrough vars rather than being supplied through them.
  context 'with runner_service.environment passthrough vars' do
    let(:params) do
      { 'runner_service' => struct_param('runner_service', 'manage' => true,
                                                           'environment' => ['DEBUG=1', 'BUILDX_NO_DEFAULT_ATTESTATIONS=1']),
        'runner_account' => account_with_uid(4242) }
    end

    it 'renders the derived DOCKER_HOST alongside the passthrough vars' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^Environment=DOCKER_HOST=unix:///run/user/4242/docker\.sock$})
        .with_content(%r{^Environment=DEBUG=1$})
        .with_content(%r{^Environment=BUILDX_NO_DEFAULT_ATTESTATIONS=1$})
    end
  end

  # DOCKER_HOST is derived, not configured: a DOCKER_HOST line in the passthrough
  # would diverge from the socket the healthcheck and socket_mount use, so it
  # fails the compile rather than rendering a manager pointed elsewhere.
  context 'with a DOCKER_HOST line in runner_service.environment' do
    let(:params) do
      { 'runner_service' => struct_param('runner_service', 'manage' => true,
                                                           'environment' => ['DOCKER_HOST=unix:///run/user/9/docker.sock']),
        'runner_account' => account_with_uid(4242) }
    end

    it { is_expected.to compile.and_raise_error(%r{do not set DOCKER_HOST in runner_service\.environment}) }
  end

  # The ownership-derivation contract (the 1.x latent wrong-owner bug): a
  # non-default account name and home must flow into every derived resource —
  # file ownership, the drop-in path, the service ExecStart, the socket path.
  context 'with a non-default runner account name and home' do
    let(:params) do
      {
        'runner_account' => account_with_uid(5000, 'name' => 'ci-worker', 'home' => '/srv/ci-worker'),
        'runner_service' => struct_param('runner_service', 'manage' => true),
      }
    end

    it { is_expected.to compile.with_all_deps }

    it 'derives the configuration file ownership from the account name' do
      is_expected.to contain_file('/etc/gitlab-runner/config.toml')
        .with('owner' => 'ci-worker', 'group' => 'ci-worker')
    end

    it 'derives the configuration directory group and system-id ownership from the account name' do
      is_expected.to contain_file('/etc/gitlab-runner').with('group' => 'ci-worker')
      is_expected.to contain_file('/etc/gitlab-runner/.runner_system_id')
        .with('owner' => 'ci-worker', 'group' => 'ci-worker')
    end

    it 'derives the no-detach-netns drop-in path and ownership from the account home and name' do
      is_expected.to contain_file('/srv/ci-worker/.config/systemd/user/docker.service.d/no-detach-netns.conf')
        .with('owner' => 'ci-worker', 'group' => 'ci-worker')
    end

    it 'derives the privilege drop, working directory and socket from the account' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner.service.d/10-rootless.conf')
        .with_content(%r{^User=ci-worker$})
        .with_content(%r{^ExecStart=/usr/bin/gitlab-runner run --working-directory /srv/ci-worker --config /etc/gitlab-runner/config\.toml --service gitlab-runner$})
        .with_content(%r{^Environment=DOCKER_HOST=unix:///run/user/5000/docker\.sock$})
    end

    # An externally provisioned account (manage off) whose primary group is
    # named differently. Every managed group ownership must derive from the
    # group, while owners stay the account name — otherwise the first apply
    # fails to resolve a group that does not exist.
    context 'with a differently named primary group' do
      let(:params) do
        super().merge('runner_account' => account_with_uid(5000, 'name' => 'ci-worker',
                                                                 'home' => '/srv/ci-worker', 'group' => 'ci'))
      end

      it { is_expected.to compile.with_all_deps }

      it 'derives every managed group ownership from the group, owners staying the account name' do
        is_expected.to contain_file('/etc/gitlab-runner/config.toml')
          .with('owner' => 'ci-worker', 'group' => 'ci')
        is_expected.to contain_file('/etc/gitlab-runner').with('group' => 'ci')
        is_expected.to contain_file('/etc/gitlab-runner/.runner_system_id')
          .with('owner' => 'ci-worker', 'group' => 'ci')
        is_expected.to contain_file('/srv/ci-worker/.config/systemd/user')
          .with('owner' => 'ci-worker', 'group' => 'ci')
        is_expected.to contain_file('/srv/ci-worker/.config/systemd/user/docker.service.d/no-detach-netns.conf')
          .with('owner' => 'ci-worker', 'group' => 'ci')
      end
    end
  end

  context 'with standalone.manage alone (no self-update loop)' do
    let(:params) do
      { 'standalone' => struct_param('standalone', 'manage' => true,
                                                   'control_repository_path' => '/opt/infra') }
    end

    it { is_expected.to compile.with_all_deps }

    it 'installs the apply script with every path derived from the control repository layout' do
      is_expected.to contain_file('/usr/local/sbin/rootless-gitlab-runner-apply')
        .with_mode('0755')
        .with_content(%r{r10k puppetfile install})
        .with_content(%r{--puppetfile "/opt/infra/Puppetfile"})
        .with_content(%r{--moduledir "/opt/infra/puppet/modules"})
        .with_content(%r{--modulepath "/opt/infra/puppet/modules"})
        .with_content(%r{--hiera_config "/opt/infra/puppet/hiera\.yaml"})
        .with_content(%r{--confdir "/etc/gitlab-runner-infra/puppet"})
        .with_content(%r{--vardir "/var/lib/grunner-puppet"})
        .with_content(%r{--detailed-exitcodes})
        .with_content(%r{"/opt/infra/puppet/manifests/site\.pp"})
    end

    it 'installs no self-update units and no healthcheck without the loop' do
      is_expected.not_to contain_file('/usr/local/sbin/rootless-gitlab-runner-healthcheck')
      is_expected.not_to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
      is_expected.not_to contain_file('/etc/systemd/system/gitlab-runner-apply.timer')
      is_expected.not_to contain_service('gitlab-runner-apply.timer')
      is_expected.not_to contain_exec('rootless_gitlab_runner daemon-reload (self-update)')
    end
  end

  context 'with standalone.self_update.manage' do
    let(:params) do
      { 'standalone'     => struct_param('standalone', 'manage' => true, 'self_update' => { 'manage' => true }),
        'runner_account' => account_with_uid(4242) }
    end

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

    it 'renders no OnFailure hook (failure surfacing is the failed unit itself)' do
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
        .without_content(%r{OnFailure})
      is_expected.to contain_file('/etc/systemd/system/gitlab-runner-healthcheck.service')
        .without_content(%r{OnFailure})
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

    context 'with a non-default branch and intervals' do
      let(:params) do
        super().merge('standalone' => struct_param('standalone',
                                                   'manage'                    => true,
                                                   'control_repository_branch' => 'deploy',
                                                   'healthcheck_interval'      => '30min',
                                                   'self_update'               => {
                                                     'manage'         => true,
                                                     'apply_interval' => '10min',
                                                     'apply_timeout'  => '20min',
                                                   }))
      end

      it 'threads the overrides into the units and the healthcheck' do
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.service')
          .with_content(%r{verify-commit origin/deploy$})
          .with_content(%r{^TimeoutStartSec=20min$})
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner-apply.timer')
          .with_content(%r{^OnUnitActiveSec=10min$})
        is_expected.to contain_file('/etc/systemd/system/gitlab-runner-healthcheck.timer')
          .with_content(%r{^OnUnitActiveSec=30min$})
        expect(rendered_file('/usr/local/sbin/rootless-gitlab-runner-healthcheck'))
          .to match(%r{ls-remote origin 'refs/heads/deploy'})
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
        'runner_account' => account_with_uid(4242),
        'runner_tokens'  => sensitive({ 'runner_a' => 'glrt-GOLDEN-TOKEN-A',
                                        'runner_b' => 'glrt-GOLDEN-TOKEN-B' }),
        # url + executor deliberately live in runner_defaults: the golden file
        # must render byte-identical, proving the merge changes nothing.
        'runner_defaults' => { 'url' => 'https://gitlab.example.org/', 'executor' => 'docker' },
        # Every documented runner key set to a non-default value across the two
        # runners, so a mutation to any exercised template line (e.g. hard-wiring
        # privileged to false) breaks the byte-exact render.
        'runners' => [
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
    let(:params) do
      { 'standalone'     => struct_param('standalone', 'manage' => true, 'self_update' => { 'manage' => true }),
        'runner_account' => account_with_uid(4242) }
    end

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

    context 'a runner account name with shell-hostile characters' do
      let(:params) { { 'runner_account' => struct_param('runner_account', 'name' => 'ev il"; rm -rf') } }

      it { is_expected.to compile.and_raise_error(%r{runner_account}) }
    end

    context 'a runner_service.environment line containing a newline' do
      let(:params) do
        {
          'runner_service' => struct_param('runner_service',
                                           'manage'      => true,
                                           'environment' => ["DEBUG=1\nExecStartPre=/bin/evil"]),
          'runner_account' => account_with_uid(2000),
        }
      end

      it { is_expected.to compile.and_raise_error(%r{runner_service}) }
    end
  end
end
