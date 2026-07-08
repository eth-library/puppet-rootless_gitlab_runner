# Unit-test dependencies for this module. rspec-puppet is not packaged in
# nixpkgs, so the dev shell (flake.nix) provides ruby + bundler and the gems
# come from here. CI uses the same Gemfile for reproducible versions.
source 'https://rubygems.org'

# Tested on Ruby 3.3 (the version flake.nix pins via ruby_3_3). puppet 8.10
# itself needs only Ruby >= 3.1; the base64/syslog/racc gems below are listed
# explicitly because Ruby 3.4 promoted them from default to bundled gems. This
# constraint pins the tested 3.3.x range and fails the no-Nix path fast on
# other versions rather than deep in a load error; 3.4+ is untested here.
ruby '>= 3.3.0', '< 3.4.0'

gem 'metadata-json-lint', '~> 5.0'
gem 'puppet', '~> 8.10'
gem 'puppet-lint', '~> 5.1'
gem 'puppet-strings', '~> 5.0' # generates REFERENCE.md (`just docs`)
gem 'puppet_fixtures', '~> 2.2' # `puppet-fixtures install`: fixture modules per .fixtures.yml
gem 'rspec-puppet', '~> 5.0'
gem 'rspec-puppet-facts', '~> 6.0' # on_supported_os: facts from metadata.json (via facterdb)

# Bundled (not default) gems the puppet gem needs but does not declare; under
# bundler they must be listed explicitly.
gem 'racc'

# Default gems puppet loads but does not declare: warned about under ruby 3.3,
# gone from the default set (LoadError under bundler) from ruby 3.4.
gem 'base64'
gem 'syslog'
