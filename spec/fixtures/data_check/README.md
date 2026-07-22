# Data-check fixtures

Miniature control-repository layouts for `spec/unit/check_hiera_data_spec.rb`, each pinning
one documented behavior of `scripts/check_hiera_data.rb`. Every fixture's `hiera.yaml` header
states its own hierarchy shape; the node files are named like real hosts (`ci-runner`)
because the hierarchy resolves them via `%{facts.networking.hostname}`.

| Fixture | Represents | Pins |
| --- | --- | --- |
| `consumer_stray` | A real consumer layout carrying the observed stray key (`session_timeout`) plus a key naming an undeployed class | Both failure modes: unknown parameter, unknown class |
| `consumer_clean` | The same layout, clean, with a `lookup_options` key and an eyaml tokens file | The pass path, the `lookup_options` skip, and the eyaml walk |
| `eyaml_stray` | A stray key inside an in-repository encrypted-secrets level | Failure detection inside `*.eyaml` files |
| `advisory` | Struct subkeys set under `manage: false` in the common layer | The non-failing advisory fires |
| `advisory_on` | The same, with a higher-priority node layer setting `manage: true` | Hierarchy priority suppresses the advisory |
| `demo_modules/demo` | A minimal module whose class has a struct parameter with a `manage` subkey | The surface the advisory fixtures resolve against, kept module-independent |
