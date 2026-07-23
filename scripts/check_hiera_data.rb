#!/usr/bin/env ruby
# frozen_string_literal: true

# Hiera data-versus-surface check.
#
# Hiera's automatic parameter lookup resolves only the parameters a class
# declares; any other `class::param` key in consumer data is silently ignored
# — a typo, a stale key from an older module version, or a key that never
# existed compiles cleanly and the intended configuration never lands. This
# check makes those keys loud: it compares every top-level key in a control
# repository's Hiera data directory against the declared parameter surface of
# the deployed modules and fails, listing every offender, when a key names a
# class absent from the deployed modules or a parameter that class does not
# declare.
#
# Usage:
#   check_hiera_data.rb --data-dir DIR --hiera-config FILE --modulepath DIR[:DIR...]
#
#   --data-dir      the Hiera data directory to walk (every *.yaml and *.eyaml
#                   under it; eyaml key names are plaintext YAML)
#   --hiera-config  the repository's hiera.yaml (version 5); it orders the data
#                   layers for the advisory below
#   --modulepath    directory (or PATH-style list) holding the deployed
#                   modules, e.g. r10k's moduledir
#
# The parameter surface comes from `puppet strings generate --format json`
# (the same tool that generates REFERENCE.md), run against each deployed
# module — the manifests are never grepped. `puppet` with the puppet-strings
# gem must be on PATH. Hiera's reserved `lookup_options` key is skipped; keys
# without a `::` are not automatic-parameter-lookup keys and are ignored.
#
# Advisory (non-failing): a declared hash-valued parameter can carry a
# `manage` toggle ("false means hands-off"), at the top level or nested inside
# a sub-hash (for example `packages.sources.manage`,
# `standalone.self_update.manage`). Each subkey is judged against the nearest
# enclosing `manage` on its own path: a `manage` that resolves to false means
# the module does not create or enforce that concern's resources, so subkeys
# set under it are not enforced — though a module may still read some of them
# as shared inputs (identity keys other concerns derive from). Setting them can
# be legitimate declared-state documentation of an externally owned concern, so
# the check reports an advisory and a human judges intent.
#
# The effective `manage` is resolved from the consumer's own data layers over
# the deployed module's module data layer (its `hiera.yaml` and data directory,
# the lowest-priority source), in hierarchy order, highest-priority `manage`
# subkey wins (first-found, matching Hiera's first-found and deep-merge
# semantics for a scalar subkey). Reading the module defaults resolves a toggle
# left at its default (silent before) and lets the advisory separate a consumer
# value that differs from the module default (flagged) from a mere restatement
# of the default (inert, suppressed). Node contexts are derived from the data
# file names matched by interpolated hierarchy paths.
#
# Stated limits: the check validates key names, not values (types are the
# compiler's job), and it cannot see consumer data layers outside the checked
# directory (for example an off-repository secret store; hierarchy levels whose
# datadir resolves outside the checked data directory are skipped). The module
# data layer is read for its defaults over static `path`/`paths` levels only; a
# module with no data layer, or whose defaults sit behind interpolated,
# `glob`/`globs`, or `mapped_paths` levels, contributes no default and its
# toggles fall back to unresolved. On the consumer side too, hierarchy levels
# addressed by `glob`/`globs` or `mapped_paths` are not modeled: advisory
# resolution covers `path`/`paths` levels only. The `manage` resolution is
# subkey-level, i.e. deep-merge semantics (what the module's `lookup_options`
# establish for its struct parameters); a higher-priority layer replacing the
# whole value with a non-hash under first-found semantics is not modeled.
#
# Exit codes: 0 = every key resolves (advisories may still be printed);
# 1 = at least one unresolvable key, all listed; 2 = usage or tool error.

require 'date'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'set'
require 'tmpdir'
require 'yaml'

class HieraDataCheck
  RESERVED_KEYS = %w[lookup_options].freeze

  # A hierarchy level flattened to one path pattern: a regex over absolute
  # file paths, with one capture group per `%{...}` interpolation.
  Level = Struct.new(:regex, :interpolated)

  def initialize(data_dir:, hiera_config:, modulepaths:, out: $stdout)
    @data_dir = data_dir
    @hiera_config = hiera_config
    @modulepaths = modulepaths
    @out = out
  end

  def run
    @out.puts "data-versus-surface check: #{surface.size} deployed class(es), " \
              "#{parsed_data.size} data file(s) under #{@data_dir}"
    advisories.each { |line| @out.puts "advisory (non-failing): #{line}" }
    offenders.each { |file, key, reason| @out.puts "FAIL #{file}: '#{key}' — #{reason}" }
    if offenders.empty?
      @out.puts 'OK: every class::param key resolves against the deployed parameter surface.'
      0
    else
      @out.puts "FAIL: #{offenders.size} Hiera key(s) resolve to no declared parameter " \
                'and would be silently ignored.'
      1
    end
  end

  private

  # --- parameter surface (puppet strings JSON) ----------------------------

  # class name => Set of declared parameter names, for every class of every
  # deployed module.
  def surface
    @surface ||= module_dirs.each_with_object({}) do |dir, acc|
      strings_classes(dir).each do |cls|
        # Parameters are the union of the class's default-carrying parameters
        # and its @param docstring tags: `defaults` misses parameters without
        # a default, the tags miss undocumented parameters.
        params = Set.new(cls['defaults'].to_h.keys)
        cls.dig('docstring', 'tags').to_a.each do |tag|
          params << tag['name'] if tag['tag_name'] == 'param' && tag['name']
        end
        acc[cls['name']] = params
      end
    end
  end

  def module_dirs
    @modulepaths.flat_map do |mp|
      raise "modulepath directory not found: #{mp}" unless Dir.exist?(mp)

      Dir.children(mp).sort.map { |c| File.join(mp, c) }
         .select { |dir| Dir.exist?(File.join(dir, 'manifests')) }
    end
  end

  def strings_classes(module_dir)
    Dir.mktmpdir do |tmp|
      out_file = File.join(tmp, 'strings.json')
      # puppet strings leaves a YARD cache in the module directory; remove it
      # unless it was already there.
      yardoc = File.join(module_dir, '.yardoc')
      had_yardoc = File.exist?(yardoc)
      _stdout, stderr, status = Open3.capture3(
        'puppet', 'strings', 'generate', '--format', 'json', '--out', out_file,
        chdir: module_dir
      )
      FileUtils.remove_entry(yardoc, true) unless had_yardoc
      raise "puppet strings failed for #{module_dir}: #{stderr}" unless status.success?

      JSON.parse(File.read(out_file))['puppet_classes'].to_a
    end
  end

  # --- data walk ----------------------------------------------------------

  # file path => parsed top-level mapping, for every YAML/eyaml file under
  # the data directory (eyaml key names are plaintext YAML).
  def parsed_data
    @parsed_data ||= Dir.glob(File.join(@data_dir, '**', '*.{yaml,eyaml}')).sort.to_h do |file|
      content = YAML.safe_load_file(file, aliases: true, permitted_classes: [Date, Time, Symbol])
      unless content.nil? || content.is_a?(Hash)
        raise "#{file}: top level is #{content.class}, expected a mapping"
      end

      [file, content || {}]
    end
  end

  def offenders
    @offenders ||= parsed_data.flat_map do |file, data|
      data.keys.filter_map do |key|
        next if RESERVED_KEYS.include?(key)
        next unless key.is_a?(String) && key.include?('::')

        klass, _, param = key.rpartition('::')
        if !surface.key?(klass)
          [file, key, "class '#{klass}' is not in the deployed modules"]
        elsif !surface[klass].include?(param)
          [file, key, "class '#{klass}' declares no parameter '#{param}'"]
        end
      end
    end
  end

  # --- advisory: subkeys under an effective manage: false -----------------

  def hierarchy_levels
    @hierarchy_levels ||= begin
      cfg = YAML.safe_load_file(@hiera_config)
      base = File.dirname(File.expand_path(@hiera_config))
      default_datadir = cfg.to_h.dig('defaults', 'datadir') || 'data'
      data_root = File.expand_path(@data_dir)
      cfg.to_h['hierarchy'].to_a.flat_map do |level|
        datadir = File.expand_path(level['datadir'] || default_datadir, base)
        Array(level['paths'] || level['path']).filter_map do |path|
          pattern = File.join(datadir, path)
          # Levels resolving outside the checked data directory (for example
          # an off-repository secret store) are invisible to the check.
          next unless pattern.start_with?("#{data_root}#{File::SEPARATOR}")

          parts = pattern.split(/%\{[^}]*\}/, -1).map { |s| Regexp.escape(s) }
          Level.new(/\A#{parts.join('([^\/]+)')}\z/, parts.size > 1)
        end
      end
    end
  end

  # Every capture tuple produced by matching the data files against the
  # interpolated hierarchy paths (typically one per node), plus the empty
  # tuple: the static layers on their own.
  def contexts
    parsed_data.keys.each_with_object(Set.new([[]])) do |file, acc|
      hierarchy_levels.each do |level|
        match = level.regex.match(File.expand_path(file))
        acc << match.captures if match && level.interpolated
      end
    end
  end

  # The concrete data files a context resolves, in hierarchy (priority) order.
  def files_for(context)
    hierarchy_levels.filter_map do |level|
      parsed_data.keys.find do |file|
        match = level.regex.match(File.expand_path(file))
        match && (!level.interpolated || match.captures == context)
      end
    end
  end

  # class::param => deep-merged default value across every deployed module's
  # own module data layer (its hiera.yaml + data dir): the lowest-priority
  # source for the manage resolution. Static path/paths levels only; a module
  # without a data layer, or whose data sits behind interpolated/glob/
  # mapped_paths levels, contributes nothing (its toggles stay unresolved).
  def module_defaults
    @module_defaults ||= module_dirs.each_with_object({}) do |dir, acc|
      module_layer(dir).each { |key, value| acc[key] = value }
    end
  end

  def module_layer(dir)
    hiera_config = File.join(dir, 'hiera.yaml')
    return {} unless File.exist?(hiera_config)

    cfg = YAML.safe_load_file(hiera_config)
    base = File.expand_path(dir)
    default_datadir = cfg.to_h.dig('defaults', 'datadir') || 'data'
    files = cfg.to_h['hierarchy'].to_a.flat_map do |level|
      datadir = File.expand_path(level['datadir'] || default_datadir, base)
      Array(level['paths'] || level['path']).reject { |p| p.include?('%{') }
                                            .map { |p| File.join(datadir, p) }
    end.select { |f| File.file?(f) }
    merge_layers(files.filter_map do |file|
      content = YAML.safe_load_file(file, aliases: true, permitted_classes: [Date, Time, Symbol])
      content if content.is_a?(Hash)
    end)
  end

  # Deep-merge a list of hash layers given highest-priority first.
  def merge_layers(values)
    values.reverse.reduce({}) { |acc, value| deep_merge(value, acc) }
  end

  # Merge high over low: hashes merge recursively; for any non-hash the
  # higher-priority value wins (array-union across layers is not modeled).
  def deep_merge(high, low)
    return high unless high.is_a?(Hash) && low.is_a?(Hash)

    low.merge(high) { |_key, low_val, high_val| deep_merge(high_val, low_val) }
  end

  def advisories
    @advisories ||= contexts.flat_map { |context| context_advisories(context) }.uniq
  end

  def context_advisories(context)
    files = files_for(context)
    offending_keys = offenders.map { |_, key, _| key }.to_set
    candidate_keys(files).flat_map do |key|
      next [] if offending_keys.include?(key)

      repo_values = files.filter_map { |f| parsed_data[f][key] }
      default = module_defaults[key]
      consumer = merge_layers(repo_values)
      effective = merge_layers(repo_values + [default].compact)

      # One line per governing toggle, so subkeys under different nested
      # toggles of the same key are each named against the toggle that disables
      # them (a top-level toggle renders as 'manage').
      leaves = unenforced_leaves(consumer, effective, default, nil, [], [])
      leaves.group_by { |_, _, toggle| toggle }.sort.map do |toggle, entries|
        grouped = entries.group_by { |dotted, value, _| source_file(files, key, dotted, value) }
                         .map { |file, subkeys| "#{subkeys.map(&:first).sort.join(', ')} (#{file})" }
        "'#{key}': effective '#{toggle}' is false, so the module does not enforce " \
          "resources from these subkeys: #{grouped.sort.join('; ')} — the module " \
          'may still read some of them as shared inputs; legitimate as declared ' \
          'state of an externally owned concern; a human judges intent'
      end
    end
  end

  # Consumer-set leaves ([dotted path, value, toggle]) governed by an effective
  # manage:false whose value differs from the module default (a restatement of
  # the default is inert and suppressed). `enclosing` is the nearest manage on
  # the path, resolved from the effective (consumer-over-module) value, and
  # `enclosing_path` is where it sits, so the toggle can be named (`manage`,
  # `sources.manage`, `self_update.manage`).
  def unenforced_leaves(consumer, effective, default, enclosing, enclosing_path, path)
    return [] unless consumer.is_a?(Hash)

    if effective.is_a?(Hash) && effective.key?('manage')
      enclosing = effective['manage']
      enclosing_path = path
    end
    consumer.flat_map do |key, value|
      next [] if key == 'manage'

      child_path = path + [key]
      eff_child = effective.is_a?(Hash) ? effective[key] : nil
      def_child = default.is_a?(Hash) ? default[key] : nil
      if value.is_a?(Hash)
        unenforced_leaves(value, eff_child, def_child, enclosing, enclosing_path, child_path)
      elsif enclosing == false && value != def_child
        [[child_path.join('.'), value, (enclosing_path + ['manage']).join('.')]]
      else
        []
      end
    end
  end

  # The highest-priority data file supplying this leaf: the merged value hides
  # which layer won under first-found, so re-derive it for the advisory.
  def source_file(files, key, dotted_path, value)
    keys = dotted_path.split('.')
    files.find { |f| dig_path(parsed_data[f][key], keys) == value } || files.first
  end

  def dig_path(node, keys)
    keys.reduce(node) { |n, k| n.is_a?(Hash) ? n[k] : nil }
  end

  # Hash-valued class::param keys present in the given files.
  def candidate_keys(files)
    files.flat_map do |file|
      parsed_data[file].filter_map do |key, value|
        key if key.is_a?(String) && key.include?('::') &&
               !RESERVED_KEYS.include?(key) && value.is_a?(Hash)
      end
    end.uniq
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: check_hiera_data.rb --data-dir DIR --hiera-config FILE --modulepath DIR[:DIR...]'
    opts.on('--data-dir DIR', 'Hiera data directory to walk') { |v| options[:data_dir] = v }
    opts.on('--hiera-config FILE', "the repository's hiera.yaml") { |v| options[:hiera_config] = v }
    opts.on('--modulepath DIRS', 'deployed-modules directory (PATH-style list allowed; repeatable)') do |v|
      (options[:modulepaths] ||= []).concat(v.split(File::PATH_SEPARATOR))
    end
  end

  begin
    parser.parse!
    missing = %i[data_dir hiera_config modulepaths].reject { |k| options[k] }
    raise OptionParser::MissingArgument, missing.join(', ') unless missing.empty?

    exit HieraDataCheck.new(
      data_dir: options[:data_dir],
      hiera_config: options[:hiera_config],
      modulepaths: options[:modulepaths]
    ).run
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    exit 2
  rescue StandardError => e
    warn "check_hiera_data: #{e.message}"
    exit 2
  end
end
