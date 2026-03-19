# frozen_string_literal: true

require_relative "kaskd/version"
require_relative "kaskd/analyzer"
require_relative "kaskd/blast_radius"
require_relative "kaskd/test_finder"
require_relative "kaskd/configuration"

module Kaskd
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Convenience entry point: analyze all services and return the full graph.
    # Returns: { services: Hash, generated_at: String, total: Integer }
    def analyze(root: nil)
      Analyzer.new(root: root).analyze
    end

    # Compute blast radius for a given service class name.
    # Returns: { target: String, affected: Array<{ class_name:, depth:, via:, file: }> }
    def blast_radius(class_name, root: nil)
      result = analyze(root: root)
      BlastRadius.new(result[:services]).compute(class_name)
    end

    # Find test files related to a service and its blast radius.
    # Returns: { target: String, test_files: Array<{ path:, class_name: }> }
    def related_tests(class_name, root: nil)
      result    = analyze(root: root)
      radius    = BlastRadius.new(result[:services]).compute(class_name)
      affected  = radius[:affected].map { |a| a[:class_name] } + [class_name]
      TestFinder.new(root: root).find_for(affected, result[:services])
    end
  end
end
