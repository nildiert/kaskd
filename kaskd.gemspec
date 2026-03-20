# frozen_string_literal: true

require_relative "lib/kaskd/version"

Gem::Specification.new do |spec|
  spec.name    = "kaskd"
  spec.version = Kaskd::VERSION
  spec.authors = ["nildiert"]
  spec.email   = []

  spec.summary     = "Static analyzer for Ruby service dependency graphs and blast radius calculation."
  spec.description = <<~DESC
    Kaskd scans Ruby service files via static analysis, builds a dependency graph,
    and answers two questions: (1) which services are affected if a given service changes
    (blast radius), and (2) which test files should be run as a result.
    Works with standard Rails layouts and Packwerk-based monorepos.
  DESC

  spec.homepage = "https://github.com/nildiert/kaskd"
  spec.license  = "MIT"

  spec.metadata = {
    "homepage_uri"    => spec.homepage,
    "source_code_uri" => "https://github.com/nildiert/kaskd",
    "changelog_uri"   => "https://github.com/nildiert/kaskd/releases",
  }

  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]

  spec.require_paths = ["lib"]
end
