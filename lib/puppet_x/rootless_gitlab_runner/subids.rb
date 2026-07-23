# frozen_string_literal: true

module PuppetX
  module RootlessGitlabRunner
    # Pure parsing of the subordinate UID/GID files (subuid(5)), split from the
    # fact that reads them so the logic is unit-testable without Facter or the
    # filesystem. The fact (and any future consumer) share this one parser.
    module Subids
      FILES = { 'subuid' => '/etc/subuid', 'subgid' => '/etc/subgid' }.freeze

      module_function

      # Parse subuid/subgid lines into { owner => [ { 'start', 'count' } ] }.
      # 'owner' is field one verbatim (the name usermod writes); malformed and
      # non-numeric lines are skipped.
      def parse(lines)
        lines.each_with_object({}) do |line, owners|
          owner, start, count = line.strip.split(':')
          next if owner.nil? || start !~ /\A\d+\z/ || count !~ /\A\d+\z/

          (owners[owner] ||= []) << { 'start' => start.to_i, 'count' => count.to_i }
        end
      end

      # Read and parse each file, keyed by kind. An unreadable file yields an
      # empty map, so a host without it simply carries no advisory input.
      def read(files = FILES)
        files.transform_values do |path|
          File.readable?(path) ? parse(File.foreach(path)) : {}
        end
      end
    end
  end
end
