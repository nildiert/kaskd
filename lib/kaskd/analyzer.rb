# frozen_string_literal: true

module Kaskd
  # Analyzes dependencies between Ruby service classes via two-pass static analysis.
  #
  # Pass 1 — collect class names and metadata from all matched files.
  # Pass 2 — detect cross-references between known classes.
  #
  # Usage:
  #   result = Kaskd::Analyzer.new.analyze
  #   result[:services]     # => Hash<class_name => metadata>
  #   result[:total]        # => Integer
  #   result[:generated_at] # => ISO 8601 String
  class Analyzer
    # @param root [String, nil] project root directory. Defaults to Dir.pwd.
    # @param globs [Array<String>, nil] override service glob patterns.
    def initialize(root: nil, globs: nil)
      @root  = root || Dir.pwd
      @globs = globs || Kaskd.configuration.service_globs
    end

    # Run the full two-pass analysis.
    # @return [Hash]
    def analyze
      all_files     = resolve_files
      services      = {}
      file_contents = {}

      # Pass 1: collect class names and metadata
      all_files.each do |path|
        content = read_file(path)
        file_contents[path] = content
        class_name = extract_class_name(content)
        next unless class_name

        services[class_name] = {
          class_name:   class_name,
          file:         relative_path(path),
          pack:         extract_pack(path),
          description:  extract_description(content),
          parent:       extract_parent(content),
          dependencies: [],
        }
      end

      known_classes = services.keys.to_set

      # Pass 2: detect dependencies by intersecting references with known classes
      all_files.each do |path|
        content    = file_contents[path]
        class_name = extract_class_name(content)
        next unless class_name && services[class_name]

        services[class_name][:dependencies] = extract_dependencies(content, known_classes, class_name)
      end

      {
        services:     services,
        generated_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        total:        services.size,
      }
    end

    private

    def resolve_files
      @globs
        .flat_map { |pattern| Dir.glob(File.join(@root, pattern)) }
        .uniq
    end

    def read_file(path)
      File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end

    # Extracts the pack name from the file path.
    #   packs/talent/evaluation_process/... => "talent/evaluation_process"
    #   app/services/...                    => "app"
    def extract_pack(path)
      rel = relative_path(path)
      return "app" unless rel.start_with?("packs/")

      parts = rel.split("/")
      parts[1..2].join("/")
    end

    # Extracts the fully qualified class name, handling module wrappers.
    # E.g.: module Foo / class Bar => "Foo::Bar"
    def extract_class_name(content)
      modules = []
      content.each_line do |line|
        stripped = line.strip
        if (m = stripped.match(/\Amodule\s+([\w:]+)/))
          modules << m[1]
        elsif (m = stripped.match(/\Aclass\s+([\w:]+)/))
          return build_qualified_name(modules, m[1])
        end
      end
      nil
    end

    def extract_parent(content)
      content.each_line do |line|
        stripped = line.strip
        if (m = stripped.match(/\Aclass\s+[\w:]+\s*<\s*([\w:]+(?:::\w+)*)/))
          return m[1]
        end
      end
      nil
    end

    def build_qualified_name(modules, class_part)
      return class_part if modules.empty?

      full_module = modules.join("::")
      class_part.start_with?("#{full_module}::") ? class_part : "#{full_module}::#{class_part}"
    end

    # Extracts description from the comment block preceding the class declaration.
    # Ignores Sorbet/Rubocop directives and YARD tags like @param/@return.
    def extract_description(content)
      lines          = content.lines
      class_line_idx = lines.find_index { |l| l.strip.match?(/\Aclass\s/) }
      return "" unless class_line_idx

      comments = []
      (class_line_idx - 1).downto(0) do |i|
        line = lines[i].strip
        break if line.empty? && comments.any?
        next  if line.empty?

        if line.start_with?("#")
          stripped = line.sub(/^#+\s?/, "").strip
          next if stripped.start_with?("@")
          next if stripped.match?(/\A(typed:|frozen_string_literal)/)

          comments.unshift(stripped) unless stripped.empty?
        else
          break
        end
      end

      comments.reject(&:empty?).join(" ").then { |s| s.empty? ? "" : s }
    end

    # Detects dependencies by finding references to known classes in the file content.
    def extract_dependencies(content, known_classes, self_class)
      references = content.scan(/\b([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*)/).flatten.to_set
      (references & known_classes - Set[self_class]).to_a.sort
    end
  end
end
