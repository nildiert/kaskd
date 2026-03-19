# frozen_string_literal: true

require_relative "kaskd/version"
require_relative "kaskd/analyzer"
require_relative "kaskd/blast_radius"
require_relative "kaskd/test_finder"
require_relative "kaskd/configuration"
require_relative "kaskd/tree_renderer"

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
    #
    # @param class_name [String] fully-qualified class name of the modified service.
    # @param root       [String, nil] project root. Defaults to Dir.pwd.
    # @param max_depth  [Integer, nil] max BFS traversal depth (default: 6). nil = unlimited.
    #
    # Returns:
    #   {
    #     target:            "My::ServiceClass",
    #     max_depth:         3,
    #     max_depth_reached: 2,
    #     by_depth: {
    #       1 => [{ class_name:, via:, file: }, ...],
    #       2 => [{ class_name:, via:, file: }, ...],
    #     },
    #     affected: [ flat array sorted by depth then name ],
    #   }
    def blast_radius(class_name, root: nil, max_depth: BlastRadius::DEFAULT_MAX_DEPTH)
      result = analyze(root: root)
      BlastRadius.new(result[:services]).compute(class_name, max_depth: max_depth)
    end

    # Find test files related to a service and its blast radius.
    # Returns: { target_classes:, test_files: Array<{ path:, class_name: }> }
    def related_tests(class_name, root: nil, max_depth: BlastRadius::DEFAULT_MAX_DEPTH)
      result   = analyze(root: root)
      radius   = BlastRadius.new(result[:services]).compute(class_name, max_depth: max_depth)
      affected = radius[:affected].map { |a| a[:class_name] } + [class_name]
      TestFinder.new(root: root).find_for(affected, result[:services])
    end

    # Render the blast radius of a service as an ASCII tree.
    # Combines blast_radius + TreeRenderer in one call.
    #
    # Example output:
    #   My::ServiceClass
    #   ├── My::InvoiceService  [depth 1]  app/services/my/invoice_service.rb
    #   │   └── My::ReportService  [depth 2]  app/services/my/report_service.rb
    #   └── My::NotifierService  [depth 1]  app/services/my/notifier_service.rb
    #
    # @param class_name [String]
    # @param root       [String, nil]
    # @param max_depth  [Integer, nil]
    # @return [String]
    def render_tree(class_name, root: nil, max_depth: BlastRadius::DEFAULT_MAX_DEPTH)
      radius = blast_radius(class_name, root: root, max_depth: max_depth)
      TreeRenderer.render(radius)
    end
  end
end
