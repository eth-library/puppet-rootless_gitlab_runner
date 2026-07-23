# frozen_string_literal: true

require 'puppet_x/rootless_gitlab_runner/subids'

# Structured view of the host's subordinate UID/GID allocations, backing the
# compile-time width and overlap advisories in rootless_gitlab_runner. rspec
# compiles a catalog and cannot see host state, so the class reads this fact to
# compare the declared range against what /etc/subuid and /etc/subgid grant.
# Value shape: { 'subuid' => { '<owner>' => [ { 'start', 'count' } ] }, 'subgid' => {…} }.
# Parsing lives in PuppetX::RootlessGitlabRunner::Subids so it is testable
# without Facter; this fact is the thin IO adapter. Puppet puts each module's
# lib/ on $LOAD_PATH after pluginsync, so the require resolves on the agent.
Facter.add(:rootless_gitlab_runner_subids) do
  setcode { PuppetX::RootlessGitlabRunner::Subids.read }
end
