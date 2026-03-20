# frozen_string_literal: true

require_relative "kaskd/version"
require_relative "kaskd/analyzer"
require_relative "kaskd/blast_radius"
require_relative "kaskd/test_case_extractor"
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

    # Find test files and their individual test cases for a list of source file paths.
    #
    # Unlike related_tests (which requires service class names and blast radius traversal),
    # test_coverage works with ANY source file — controllers, resources, cells, queries, models.
    # It uses :convention_and_content strategy to maximise recall.
    #
    # @param file_paths [Array<String>] paths to source files (relative to root).
    # @param root       [String, nil]  project root. Defaults to Dir.pwd.
    # @return [Hash]
    #   {
    #     source_files:   ["packs/.../resource.rb", ...],
    #     target_classes: ["Talent::EmployeeEvaluationsResource", ...],
    #     test_files: [
    #       {
    #         path:       "packs/.../resource_test.rb",
    #         class_name: "Talent::EmployeeEvaluationsResource",
    #         test_cases: [
    #           { description: "incluir los campos del recurso", line: 21, context: "campos básicos" },
    #           ...
    #         ]
    #       },
    #       ...
    #     ]
    #   }
    def test_coverage(file_paths, root: nil)
      root_dir = root || Dir.pwd

      target_classes = file_paths.filter_map do |path|
        abs = path.start_with?("/") ? path : File.join(root_dir, path)
        content = File.read(abs, encoding: "utf-8", invalid: :replace, undef: :replace) rescue nil
        next unless content

        Analyzer.new(root: root_dir).send(:extract_class_name, content)
      end

      finder = TestFinder.new(root: root_dir)
      result = finder.find_for(
        target_classes,
        {},
        strategy:   :convention_and_content,
        with_cases: true,
      )

      {
        source_files:   file_paths,
        target_classes: target_classes,
        test_files:     result[:test_files],
      }
    end

    # Find test files that reference any of the given terms (method names, strings).
    #
    # Unlike test_coverage (which works from source file paths and naming conventions),
    # find_tests_referencing performs a raw content search across all test files.
    # This is the "extended discovery" step that catches tests crossing naming boundaries —
    # for example, evaluation_processes_controller_active_test.rb that asserts a redirect
    # inside evaluator_people_controller.rb (which it exercises through the parent route).
    #
    # Usage:
    #   results = Kaskd.find_tests_referencing(
    #     ["evaluators_subtab_redirect_params", "remove_evaluator"],
    #     root: Dir.pwd,
    #     with_cases: true,
    #   )
    #   results[:test_files]
    #   # => [
    #   #   { path: "packs/.../evaluation_processes_controller_active_test.rb",
    #   #     matched_terms: ["remove_evaluator"],
    #   #     test_cases: [...] },
    #   #   ...
    #   # ]
    #
    # @param terms      [Array<String>] method names, constants, or any strings to search for.
    # @param root       [String, nil] project root. Defaults to Dir.pwd.
    # @param with_cases [Boolean] when true, each result includes :test_cases.
    # @return [Hash] { terms:, test_files: [{ path:, matched_terms:, test_cases?: [...] }] }
    def find_tests_referencing(terms, root: nil, with_cases: false)
      TestFinder.new(root: root).find_referencing(terms, with_cases: with_cases)
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
