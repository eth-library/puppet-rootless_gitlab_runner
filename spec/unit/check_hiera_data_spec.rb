# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# End-to-end tests for scripts/check_hiera_data.rb, the Hiera
# data-versus-surface check. Each example runs the script as a consumer CI
# job would (a child process, asserting on output and exit status) against a
# fixture control-repository layout under spec/fixtures/data_check/.
#
# The `puppet strings` surface generation runs per invocation, so the
# examples against the real module surface are the slowest in the suite;
# they stay because they reproduce the exact consumer shape that motivated
# the check (a stray `session_timeout` key that no tooling ever flagged).
describe 'scripts/check_hiera_data.rb' do
  CHECK_SCRIPT = File.expand_path('../../scripts/check_hiera_data.rb', __dir__)
  CHECK_FIXTURES = File.expand_path('../fixtures/data_check', __dir__)
  DEMO_MODULES = File.join(CHECK_FIXTURES, 'demo_modules')

  # Modulepath holding only this module (a symlink in a tmpdir), so the
  # surface generation does not also document the fetched fixture modules.
  # Removed on exit; without the hook, every suite run leaks a tmpdir.
  REAL_MODULE_PATH = Dir.mktmpdir('data_check_modules').tap do |dir|
    File.symlink(File.expand_path('../..', __dir__), File.join(dir, 'rootless_gitlab_runner'))
    at_exit { FileUtils.remove_entry(dir, true) }
  end

  def run_check(fixture_dir, modulepath, data_dir: File.join(fixture_dir, 'data'))
    Open3.capture2e(
      'ruby', CHECK_SCRIPT,
      '--data-dir', data_dir,
      '--hiera-config', File.join(fixture_dir, 'hiera.yaml'),
      '--modulepath', modulepath
    )
  end

  context 'against the real module surface' do
    it 'fails listing the stray consumer keys (the live session_timeout shape)' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'consumer_stray'), REAL_MODULE_PATH)
      expect(status.exitstatus).to eq(1)
      expect(output).to match(/FAIL .*common\.yaml: 'rootless_gitlab_runner::session_timeout' — class 'rootless_gitlab_runner' declares no parameter 'session_timeout'/)
      expect(output).to match(/FAIL .*ci-runner\.yaml: 'no_such_module::thing' — class 'no_such_module' is not in the deployed modules/)
      # Declared keys from the same files are not flagged.
      expect(output).not_to match(/FAIL .*'rootless_gitlab_runner::concurrent'/)
      expect(output).not_to match(/FAIL .*'rootless_gitlab_runner::runner_account'/)
    end

    it 'passes the same shape without the stray keys, skipping lookup_options and walking eyaml' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'consumer_clean'), REAL_MODULE_PATH)
      expect(status.exitstatus).to eq(0)
      expect(output).not_to match(/FAIL/)
      expect(output).to match(/OK: every class::param key resolves/)
    end

    it 'passes the shipped examples/data against the module surface' do
      examples = File.expand_path('../../examples', __dir__)
      output, status = run_check(examples, REAL_MODULE_PATH,
                                 data_dir: File.join(examples, 'data'))
      expect(status.exitstatus).to eq(0)
      expect(output).not_to match(/FAIL/)
    end
  end

  context 'against the demo fixture surface' do
    it 'fails on a stray key inside an eyaml file (key names are plaintext)' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'eyaml_stray'), DEMO_MODULES)
      expect(status.exitstatus).to eq(1)
      expect(output).to match(/FAIL .*ci-runner\.eyaml: 'demo::beta' — class 'demo' declares no parameter 'beta'/)
      expect(output).not_to match(/FAIL .*'demo::alpha'/)
    end

    it 'emits a non-failing advisory for subkeys under an effective manage: false' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'advisory'), DEMO_MODULES)
      expect(status.exitstatus).to eq(0)
      expect(output).to match(/advisory \(non-failing\): 'demo::standalone': effective 'manage' is false, so the module does not enforce resources from these subkeys/)
      expect(output).to match(/self_update.*ci-runner\.yaml/)
      # The advisory must not call the subkeys inert: shared-input keys
      # (account identity) are read by every concern regardless of the toggle.
      expect(output).not_to match(/inert/)
    end

    it 'emits no advisory when a higher-priority layer turns manage on' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'advisory_on'), DEMO_MODULES)
      expect(status.exitstatus).to eq(0)
      expect(output).not_to match(/advisory \(non-failing\)/)
    end
  end

  context 'against the real module surface, resolving nested and module-default toggles' do
    it 'flags a nested subkey whose toggle sits at the module default, sparing a restated default' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'nested_default_sources'), REAL_MODULE_PATH)
      expect(status.exitstatus).to eq(0)
      expect(output).to match(%r{advisory \(non-failing\): 'rootless_gitlab_runner::packages': effective 'manage' is false.*sources\.docker\.location .*nodes/ci-runner\.yaml})
      # The gitlab-runner location merely restates the module default: inert, not flagged.
      expect(output).not_to match(/sources\.gitlab_runner\.location/)
    end

    it 'judges a nested loop toggle at the module default independently of the enclosing manage' do
      output, status = run_check(File.join(CHECK_FIXTURES, 'nested_self_update'), REAL_MODULE_PATH)
      expect(status.exitstatus).to eq(0)
      expect(output).to match(%r{advisory \(non-failing\): 'rootless_gitlab_runner::standalone': effective 'manage' is false.*self_update\.apply_interval .*nodes/ci-runner\.yaml})
      # apply_timeout restates the module default; standalone.manage is true but does not lift the inner toggle.
      expect(output).not_to match(/apply_timeout/)
    end
  end
end
