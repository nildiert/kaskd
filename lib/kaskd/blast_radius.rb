# frozen_string_literal: true

module Kaskd
  # Computes the blast radius of a service change via BFS on the reverse dependency graph.
  #
  # Given a target service class name, it finds every other service that depends on it
  # (directly or transitively) and groups results by depth level.
  #
  # Usage:
  #   result = Kaskd::Analyzer.new.analyze
  #   radius = Kaskd::BlastRadius.new(result[:services]).compute("My::ServiceClass", max_depth: 3)
  #
  #   radius[:target]  # => "My::ServiceClass"
  #   radius[:by_depth] # => {
  #     1 => [{ class_name: "A", via: "My::ServiceClass", file: "...", dependencies: [...], parent: "..." }, ...],
  #     2 => [{ class_name: "B", via: "A",                file: "...", dependencies: [...], parent: nil  }, ...],
  #   }
  #   radius[:affected] # => flat array of all entries, sorted by depth then name
  #   radius[:max_depth_reached] # => Integer — deepest level found (≤ max_depth)
  class BlastRadius
    DEFAULT_MAX_DEPTH = 8

    # @param services [Hash] output of Kaskd::Analyzer#analyze — services keyed by class name.
    def initialize(services)
      @services = services
    end

    # Run BFS from the target service through the reverse dependency index.
    #
    # @param target    [String]  fully-qualified class name of the modified service.
    # @param max_depth [Integer] maximum traversal depth (default: 6). nil = unlimited.
    # @return [Hash]
    def compute(target, max_depth: DEFAULT_MAX_DEPTH)
      reverse_index = build_reverse_index

      queue   = [[target, 0]]
      visited = { target => { depth: 0, via: nil } }

      while queue.any?
        svc, depth = queue.shift
        next if max_depth && depth >= max_depth

        (reverse_index[svc] || []).each do |caller_svc|
          next if visited.key?(caller_svc)

          visited[caller_svc] = { depth: depth + 1, via: svc }
          queue << [caller_svc, depth + 1]
        end
      end

      entries = visited
        .reject { |name, _| name == target }
        .sort_by { |name, meta| [meta[:depth], name] }
        .map do |name, meta|
          {
            class_name:   name,
            depth:        meta[:depth],
            via:          meta[:via],
            file:         @services.dig(name, :file),
            dependencies: @services.dig(name, :dependencies) || [],
            parent:       @services.dig(name, :parent),
          }
        end

      by_depth = entries.group_by { |e| e[:depth] }

      {
        target:           target,
        max_depth:        max_depth,
        max_depth_reached: entries.map { |e| e[:depth] }.max || 0,
        by_depth:         by_depth,
        affected:         entries,
      }
    end

    private

    # Builds a reverse index: given a service X, who depends on X?
    # reverse_index["X"] => ["A", "B", ...]
    def build_reverse_index
      index = Hash.new { |h, k| h[k] = [] }
      @services.each do |name, meta|
        meta[:dependencies].each do |dep|
          index[dep] << name
        end
      end
      index
    end
  end
end
