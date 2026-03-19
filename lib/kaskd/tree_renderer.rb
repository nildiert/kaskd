# frozen_string_literal: true

module Kaskd
  # Renders a blast radius result as an ASCII tree.
  #
  # Usage:
  #   radius = Kaskd.blast_radius("My::ServiceClass", root: Rails.root.to_s)
  #   puts Kaskd::TreeRenderer.render(radius)
  #
  # Output example:
  #   My::ServiceClass
  #   ├── My::InvoiceService  [depth 1]  app/services/my/invoice_service.rb
  #   │   ├── My::ReportService  [depth 2]  app/services/my/report_service.rb
  #   │   └── My::ExportService  [depth 2]  app/services/my/export_service.rb
  #   └── My::NotifierService  [depth 1]  app/services/my/notifier_service.rb
  #       └── My::AuditService  [depth 2]  app/services/my/audit_service.rb
  #
  # Also available as a convenience method:
  #   Kaskd.render_tree("My::ServiceClass", root: Rails.root.to_s)
  class TreeRenderer
    BRANCH = "├── "
    LAST   = "└── "
    PIPE   = "│   "
    SPACE  = "    "

    # @param radius [Hash] output of Kaskd::BlastRadius#compute or Kaskd.blast_radius
    # @param io     [IO]   output target (default: returns String)
    # @return [String]
    def self.render(radius)
      new(radius).render
    end

    def initialize(radius)
      @target   = radius[:target]
      @affected = radius[:affected]
    end

    def render
      # Build adjacency: parent -> [children] using the :via field
      children = Hash.new { |h, k| h[k] = [] }
      @affected.each { |entry| children[entry[:via]] << entry }

      # Sort each child list by class_name for deterministic output
      children.each_value { |list| list.sort_by! { |e| e[:class_name] } }

      lines = []
      lines << @target
      render_children(children[@target], children, "", lines)
      lines.join("\n")
    end

    private

    def render_children(nodes, children_map, prefix, lines)
      return if nodes.nil? || nodes.empty?

      nodes.each_with_index do |node, idx|
        last = idx == nodes.size - 1

        connector   = last ? LAST : BRANCH
        child_prefix = prefix + (last ? SPACE : PIPE)

        label = format_node(node)
        lines << "#{prefix}#{connector}#{label}"

        render_children(children_map[node[:class_name]], children_map, child_prefix, lines)
      end
    end

    def format_node(node)
      parts = [node[:class_name]]
      parts << "\e[2m[depth #{node[:depth]}]\e[0m"
      parts << "\e[36m#{node[:file]}\e[0m" if node[:file]
      unless node[:dependencies].nil? || node[:dependencies].empty?
        deps = node[:dependencies].join(", ")
        parts << "\e[2m(deps: #{deps})\e[0m"
      end
      parts.join("  ")
    end
  end
end
