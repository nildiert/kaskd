# frozen_string_literal: true

module Kaskd
  # Computes the blast radius of a service change via BFS on the reverse dependency graph.
  #
  # Given a target service class name, it finds every other service that depends on it
  # (directly or transitively) and reports the depth and the intermediate service via
  # which the dependency flows.
  #
  # Usage:
  #   result   = Kaskd::Analyzer.new.analyze
  #   radius   = Kaskd::BlastRadius.new(result[:services]).compute("My::ServiceClass")
  #   radius[:target]   # => "My::ServiceClass"
  #   radius[:affected] # => [{ class_name:, depth:, via:, file: }, ...]
  class BlastRadius
    # @param services [Hash] output of Kaskd::Analyzer#analyze — services keyed by class name.
    def initialize(services)
      @services = services
    end

    # Run BFS from the target service through the reverse dependency index.
    #
    # @param target [String] fully-qualified class name of the modified service.
    # @return [Hash]
    def compute(target)
      reverse_index = build_reverse_index

      queue   = [[target, 0]]
      visited = { target => { depth: 0, via: nil } }

      while queue.any?
        svc, depth = queue.shift
        (reverse_index[svc] || []).each do |caller_svc|
          next if visited.key?(caller_svc)

          visited[caller_svc] = { depth: depth + 1, via: svc }
          queue << [caller_svc, depth + 1]
        end
      end

      affected = visited
        .reject { |name, _| name == target }
        .sort_by { |_, meta| [meta[:depth], meta[:via].to_s] }
        .map do |name, meta|
          {
            class_name: name,
            depth:      meta[:depth],
            via:        meta[:via],
            file:       @services.dig(name, :file),
          }
        end

      {
        target:   target,
        affected: affected,
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
