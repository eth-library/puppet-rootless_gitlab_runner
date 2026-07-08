require 'rspec-puppet'
require 'rspec-puppet-facts'
include RspecPuppetFacts

RSpec.configure do |c|
  c.module_path = File.expand_path(File.join(__dir__, 'fixtures', 'modules'))
  # Hash-backed facts instead of invoking real Facter for the server facts,
  # so local (darwin) and CI runs use the same fact source. rspec-puppet
  # derives networking.hostname/fqdn/domain from the node name for every
  # example but not networking.ip, and warns per compiled catalog when the
  # lookup fails (on darwin real Facter cannot resolve it either) — a
  # synthetic default (TEST-NET-1 documentation address) completes the set.
  c.facter_implementation = :rspec
  c.default_facts = { 'networking' => { 'ip' => '192.0.2.1' } }

  # Print a resource-coverage summary after the suite (informational; no
  # threshold gate). rspec-puppet tracks every resource declared by the
  # catalogs the examples compile.
  c.after(:suite) do
    RSpec::Puppet::Coverage.report!
  end
end
