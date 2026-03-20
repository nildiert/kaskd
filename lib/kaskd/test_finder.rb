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

    # Heuristic 1 — naming convention.
    # test/services/my/service_test.rb => base "service" or "my_service"
    # Returns matched class names or nil.
    #
    # Path-similarity guard: when a candidate class is namespaced (e.g.
    # Talent::EmployeeEvaluations::Restore), we require that at least one
    # namespace segment (underscored) appears somewhere in the test file's
    # directory path. This prevents generic base names like "restore" from
    # matching unrelated tests in other packs/modules.
    def match_by_convention(rel_path, target_set, name_map)
      base = File.basename(rel_path, ".rb")
                 .delete_suffix("_test")
                 .delete_suffix("_spec")

      dir_segments = File.dirname(rel_path).split("/").map(&:downcase)

      candidates = name_map[base] || []
      matched    = candidates.select do |class_name|
        next false unless target_set.include?(class_name)

        namespace_parts = class_name.split("::").map { |p| underscore(p) }
        # The leaf (last part) matches by definition (it's the base name).
        # Require at least one of the *namespace* segments (all except the last)
        # to appear in the directory path of the test file.
        ns_parts = namespace_parts[0..-2]
        ns_parts.empty? || ns_parts.any? { |seg| dir_segments.include?(seg) }
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
