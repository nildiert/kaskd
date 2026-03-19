# frozen_string_literal: true

module Kaskd
  # Holds gem-wide configuration.
  # Use Kaskd.configure { |c| c.service_globs = [...] } to override defaults.
  class Configuration
    # Glob patterns used to discover service files.
    # Override if your project uses a non-standard layout.
    attr_accessor :service_globs

    # Glob patterns used to discover test files (Minitest and RSpec).
    attr_accessor :test_globs

    def initialize
      @service_globs = [
        "app/services/**/*.rb",
        "packs/**/app/services/**/*.rb",
      ]

      @test_globs = [
        "test/**/*_test.rb",
        "spec/**/*_spec.rb",
        "packs/**/test/**/*_test.rb",
        "packs/**/spec/**/*_spec.rb",
      ]
    end
  end
end
