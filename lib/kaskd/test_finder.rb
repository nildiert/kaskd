# frozen_string_literal: true

module Kaskd
  # Finds test files related to a set of service class names.
  #
  # Strategy:
  #   1. Scan all test files matched by the configured globs.
  #   2. For each test file, extract the class name it likely tests using two heuristics:
  #      a. Naming convention: strip _test / _spec suffix from the filename and map it
  #         to a Ruby constant (e.g. my_service_test.rb => MyService).
  #         This is the default (and recommended) strategy — it has zero false positives
  #         because it relies on Rails path conventions (namespace + underscore name).
  #      b. Content scan: look for references to any of the target class names inside
  #         the file body. Use with caution — generates false positives when a class
  #         name appears in comments, factories, or shared setup without being the
  #         actual subject under test.
  #   3. Return a deduplicated list of { path:, class_name: } for every match.
  #
  # Usage:
  #   result  = Kaskd::Analyzer.new.analyze
  #   radius  = Kaskd::BlastRadius.new(result[:services]).compute("My::ServiceClass")
  #   targets = radius[:affected].map { |a| a[:class_name] } + ["My::ServiceClass"]
  #   tests   = Kaskd::TestFinder.new.find_for(targets, result[:services])
  #   tests[:test_files]  # => [{ path: "test/...", class_name: "My::ServiceClass" }, ...]
  #
  #   # Use content scan as well (more results, possible false positives):
  #   tests = Kaskd::TestFinder.new.find_for(targets, result[:services], strategy: :convention_and_content)
  class TestFinder
    STRATEGIES = %i[convention_only convention_and_content].freeze

    # @param root  [String, nil] project root. Defaults to Dir.pwd.
    # @param globs [Array<String>, nil] override test glob patterns.
    def initialize(root: nil, globs: nil)
      @root  = root || Dir.pwd
      @globs = globs || Kaskd.configuration.test_globs
    end

    # Find test files that reference any of the given terms (method names, strings).
    #
    # Unlike find_for (which requires class names and uses naming conventions),
    # find_referencing performs a raw content search across all test files.
    # This catches tests that exercise modified code through parent routes or
    # integration paths where the test filename doesn't match the modified source.
    #
    # Example: if evaluator_people_controller.rb changes a redirect, this finds
    # evaluation_processes_controller_active_test.rb that asserts that redirect.
    #
    # @param terms      [Array<String>] strings to search for (method names, constants, etc.)
    # @param with_cases [Boolean] when true, extract individual test cases from each file.
    # @return [Hash] { terms:, test_files: [{ path:, matched_terms: [...] }] }
    def find_referencing(terms, with_cases: false)
      return { terms: terms, test_files: [] } if terms.empty?

      all_tests = resolve_test_files
      found     = {}

      all_tests.each do |path|
        rel           = relative_path(path)
        matched_terms = terms_in_file(path, terms)
        next if matched_terms.empty?

        found[rel] = { path: rel, matched_terms: matched_terms }
      end

      test_files = found.values.sort_by { |t| t[:path] }

      if with_cases
        extractor = TestCaseExtractor.new(root: @root)
        test_files.each { |entry| entry[:test_cases] = extractor.extract(entry[:path]) }
      end

      { terms: terms, test_files: test_files }
    end

    # @param target_classes [Array<String>] fully-qualified class names to search for.
    # @param services       [Hash] services map from Kaskd::Analyzer#analyze (used for
    #                              quick filename-to-class lookups).
    # @param strategy       [Symbol] :convention_only (default) or :convention_and_content.
    #                                :convention_only  — only match by Rails filename convention (zero false positives).
    #                                :convention_and_content — also scan file body for class name references
    #                                                          (more results, possible false positives).
    # @param with_cases     [Boolean] when true, each result includes :test_cases — an Array of
    #                                 { description:, line:, context: } extracted from the test file.
    # @return [Hash]
    def find_for(target_classes, services = {}, strategy: :convention_only, with_cases: false)
      unless STRATEGIES.include?(strategy)
        raise ArgumentError, "Unknown strategy #{strategy.inspect}. Use one of: #{STRATEGIES.join(', ')}"
      end

      target_set  = target_classes.to_set
      all_tests   = resolve_test_files
      found       = {}

      # Build a reverse map: snake_case base name => class name (from services)
      # so naming-convention matching can cover namespaced classes too.
      name_map = build_name_map(services)

      all_tests.each do |path|
        rel     = relative_path(path)
        matched = match_by_convention(rel, target_set, name_map)
        matched ||= match_by_content(path, target_set) if strategy == :convention_and_content
        next unless matched

        # A test file may cover multiple targets — accumulate all
        Array(matched).each do |class_name|
          key = "#{rel}::#{class_name}"
          found[key] = { path: rel, class_name: class_name }
        end
      end

      test_files = found.values.sort_by { |t| [t[:path], t[:class_name]] }

      if with_cases
        extractor = TestCaseExtractor.new(root: @root)
        test_files.each { |entry| entry[:test_cases] = extractor.extract(entry[:path]) }
      end

      {
        target_classes: target_classes,
        strategy:       strategy,
        test_files:     test_files,
      }
    end

    private

    def resolve_test_files
      @globs
        .flat_map { |pattern| Dir.glob(File.join(@root, pattern)) }
        .uniq
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end

    # Builds a map from underscore base name to fully-qualified class names.
    # e.g. "my_service" => ["My::ServiceClass"] where the file is my_service.rb
    def build_name_map(services)
      map = Hash.new { |h, k| h[k] = [] }
      services.each do |class_name, meta|
        base = File.basename(meta[:file].to_s, ".rb")
        map[base] << class_name
      end
      map
    end

    # Heuristic 1 — naming convention (Rails-style path guard).
    #
    # Rails convention: the test file path mirrors the class namespace.
    #   Talent::EmployeeEvaluations::Restore
    #     => expected path fragment: "talent/employee_evaluations/restore"
    #
    # A test file matches a candidate class only when the full underscored
    # namespace path (e.g. "talent/employee_evaluations/restore") is a
    # substring of the test's relative path (ignoring the _test/_spec suffix).
    # This is the same guard Rails autoload uses and eliminates false positives
    # from generic leaf names like "restore" or "create" appearing in unrelated
    # packs.
    def match_by_convention(rel_path, target_set, name_map)
      base = File.basename(rel_path, ".rb")
                 .delete_suffix("_test")
                 .delete_suffix("_spec")

      # Normalise the test path for substring matching (drop extension suffix).
      normalised_path = File.join(File.dirname(rel_path), base)

      candidates = name_map[base] || []
      matched    = candidates.select do |class_name|
        next false unless target_set.include?(class_name)

        # Build the expected path fragment from the fully-qualified class name.
        expected_fragment = class_name.split("::").map { |p| underscore(p) }.join("/")
        normalised_path.include?(expected_fragment)
      end

      matched.empty? ? nil : matched
    end

    # Minimal underscore — converts CamelCase to snake_case.
    # e.g. "EmployeeEvaluations" => "employee_evaluations"
    def underscore(str)
      str
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
    end

    # Heuristic 2 — content scan.
    # Read the file and look for direct references to any of the target class names.
    # Returns matched class names or nil.
    def match_by_content(path, target_set)
      content = File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
      matched = target_set.select { |class_name| content.include?(class_name) }
      matched.empty? ? nil : matched.to_a
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # Term scan — returns which of the given terms appear in the file.
    def terms_in_file(path, terms)
      content = File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
      terms.select { |term| content.include?(term) }
    rescue Errno::ENOENT, Errno::EACCES
      []
    end
  end
end
