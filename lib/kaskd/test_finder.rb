# frozen_string_literal: true

module Kaskd
  # Finds test files related to a set of service class names.
  #
  # Strategy:
  #   1. Scan all test files matched by the configured globs.
  #   2. For each test file, extract the class name it likely tests using two heuristics:
  #      a. Naming convention: strip _test / _spec suffix from the filename and map it
  #         to a Ruby constant (e.g. my_service_test.rb => MyService).
  #      b. Content scan: look for references to any of the target class names inside
  #         the file body.
  #   3. Return a deduplicated list of { path:, class_name: } for every match.
  #
  # Usage:
  #   result  = Kaskd::Analyzer.new.analyze
  #   radius  = Kaskd::BlastRadius.new(result[:services]).compute("My::ServiceClass")
  #   targets = radius[:affected].map { |a| a[:class_name] } + ["My::ServiceClass"]
  #   tests   = Kaskd::TestFinder.new.find_for(targets, result[:services])
  #   tests[:test_files]  # => [{ path: "test/...", class_name: "My::ServiceClass" }, ...]
  class TestFinder
    # @param root  [String, nil] project root. Defaults to Dir.pwd.
    # @param globs [Array<String>, nil] override test glob patterns.
    def initialize(root: nil, globs: nil)
      @root  = root || Dir.pwd
      @globs = globs || Kaskd.configuration.test_globs
    end

    # @param target_classes [Array<String>] fully-qualified class names to search for.
    # @param services       [Hash] services map from Kaskd::Analyzer#analyze (used for
    #                              quick filename-to-class lookups).
    # @return [Hash]
    def find_for(target_classes, services = {})
      target_set  = target_classes.to_set
      all_tests   = resolve_test_files
      found       = {}

      # Build a reverse map: snake_case base name => class name (from services)
      # so naming-convention matching can cover namespaced classes too.
      name_map = build_name_map(services)

      all_tests.each do |path|
        rel     = relative_path(path)
        matched = match_by_convention(rel, target_set, name_map)
        matched ||= match_by_content(path, target_set)
        next unless matched

        # A test file may cover multiple targets — accumulate all
        Array(matched).each do |class_name|
          key = "#{rel}::#{class_name}"
          found[key] = { path: rel, class_name: class_name }
        end
      end

      {
        target_classes: target_classes,
        test_files:     found.values.sort_by { |t| [t[:path], t[:class_name]] },
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
  end
end
