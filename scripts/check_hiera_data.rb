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
# `manage` toggle ("false means hands-off"). Subkeys set under a struct whose
# effective `manage` resolves to false are recognized but inert; that can be
# legitimate declared-state documentation of an externally owned concern, so
# the check reports it as an advisory and a human judges intent. The
# effective `manage` is resolved from the repository's own data layers: the
# hierarchy levels of the given hiera.yaml that resolve inside the data
# directory, in hierarchy order, highest-priority `manage` subkey wins (the
# first-found value, matching both Hiera first-found and deep-merge semantics
# for a scalar subkey). Node contexts are derived from the data file names
# matched by interpolated hierarchy paths. When no in-repository layer sets
# `manage`, the check stays silent — the module-side default is a data layer
# it cannot see.
#
# Stated limits: the check validates key names, not values (types are the
# compiler's job), and it cannot see data layers outside the repository (for
# example an off-repository secret store; hierarchy levels whose datadir
# resolves outside the checked data directory are skipped).
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

  def advisories
    @advisories ||= contexts.flat_map { |context| context_advisories(context) }.uniq
  end

  def context_advisories(context)
    files = files_for(context)
    offending_keys = offenders.map { |_, key, _| key }.to_set
    candidate_keys(files).filter_map do |key|
      next if offending_keys.include?(key)

      # Highest-priority manage subkey wins; unresolved in-repository => silent.
      managed = files.filter_map { |f| parsed_data[f][key] }
                     .find { |v| v.is_a?(Hash) && v.key?('manage') }
      next unless managed && managed['manage'] == false

      inert = files.filter_map do |file|
        value = parsed_data[file][key]
        subkeys = value.is_a?(Hash) ? value.keys - ['manage'] : []
        "#{subkeys.sort.join(', ')} (#{file})" unless subkeys.empty?
      end
      next if inert.empty?

      "'#{key}': effective 'manage' is false, so these subkeys are set but " \
        "inert: #{inert.join('; ')} — legitimate as declared-state " \
        'documentation of an externally owned concern; a human judges intent'
    end
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
