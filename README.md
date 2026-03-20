# kaskd

Static analyzer for Ruby service dependency graphs and blast radius calculation.

> **kaskd** = cascade — when a service changes, the ripple propagates.

Kaskd scans your `app/services` and `packs/**/app/services` directories via static analysis, builds a full dependency graph, and answers two questions:

1. **Which services are affected** if a given service changes? (blast radius)
2. **Which test files should be run** as a result?

Works with standard Rails layouts and [Packwerk](https://github.com/Shopify/packwerk)-based monorepos.

---

## Installation

Add to your `Gemfile`:

```ruby
gem "kaskd", github: "nildiert/kaskd"
```

Or for development/CI only:

```ruby
group :development, :test do
  gem "kaskd", github: "nildiert/kaskd"
end
```

Then:

```bash
bundle install
```

---

## Usage

### Full dependency graph

```ruby
result = Kaskd.analyze
result[:services]     # Hash<class_name => metadata>
result[:total]        # Integer
result[:generated_at] # ISO 8601 String
```

### Blast radius

```ruby
radius = Kaskd.blast_radius("My::PayrollService")

# Control traversal depth (default: 8, nil = unlimited)
radius = Kaskd.blast_radius("My::PayrollService", max_depth: 3)

radius[:target]            # => "My::PayrollService"
radius[:max_depth]         # => 3
radius[:max_depth_reached] # => 2

# Results grouped by depth level
radius[:by_depth] # => {
#   1 => [
#     { class_name: "My::InvoiceService", depth: 1, via: "My::PayrollService",
#       file: "app/services/my/invoice_service.rb",
#       dependencies: ["My::PayrollService", "My::TaxService"], parent: nil },
#   ],
#   2 => [
#     { class_name: "My::ReportService", depth: 2, via: "My::InvoiceService",
#       file: "app/services/my/report_service.rb",
#       dependencies: ["My::InvoiceService"], parent: nil },
#   ],
# }

# Flat array sorted by depth then name
radius[:affected] # => [
#   { class_name: "My::InvoiceService", depth: 1, via: "My::PayrollService",
#     file: "...", dependencies: [...], parent: nil },
#   { class_name: "My::ReportService",  depth: 2, via: "My::InvoiceService",
#     file: "...", dependencies: [...], parent: nil },
# ]
```

### ASCII tree view

```ruby
# Convenience method — runs blast_radius and renders in one call
puts Kaskd.render_tree("My::PayrollService")
puts Kaskd.render_tree("My::PayrollService", max_depth: 3)

# Or render from an existing blast radius result
radius = Kaskd.blast_radius("My::PayrollService")
puts Kaskd::TreeRenderer.render(radius)
```

Example output:

```
My::PayrollService
├── My::InvoiceService  [depth 1]  app/services/my/invoice_service.rb  (deps: My::PayrollService, My::TaxService)
│   ├── My::ExportService  [depth 2]  app/services/my/export_service.rb
│   └── My::ReportService  [depth 2]  app/services/my/report_service.rb
└── My::NotifierService  [depth 1]  app/services/my/notifier_service.rb
    └── My::AuditService  [depth 2]  app/services/my/audit_service.rb
```

Each node shows: class name, depth (gray), file path (cyan), and direct dependencies (gray).

### Related tests

```ruby
tests = Kaskd.related_tests("My::PayrollService")

# Also accepts max_depth to match the blast radius scope
tests = Kaskd.related_tests("My::PayrollService", max_depth: 3)

tests[:test_files] # => [
#   { path: "test/services/my/payroll_service_test.rb", class_name: "My::PayrollService" },
#   { path: "test/services/my/invoice_service_test.rb", class_name: "My::InvoiceService" },
# ]
```

### Lower-level API

```ruby
# 1. Analyze
result = Kaskd::Analyzer.new(root: "/path/to/project").analyze

# 2. Blast radius
radius = Kaskd::BlastRadius.new(result[:services]).compute("My::PayrollService", max_depth: 4)

# 3. Tree
puts Kaskd::TreeRenderer.render(radius)

# 4. Tests
affected_classes = radius[:affected].map { |a| a[:class_name] } + ["My::PayrollService"]
tests = Kaskd::TestFinder.new(root: "/path/to/project").find_for(affected_classes, result[:services])
```

---

## Configuration

```ruby
Kaskd.configure do |c|
  # Override service glob patterns
  c.service_globs = [
    "app/services/**/*.rb",
    "packs/**/app/services/**/*.rb",
  ]

  # Override test glob patterns
  c.test_globs = [
    "test/**/*_test.rb",
    "spec/**/*_spec.rb",
    "packs/**/test/**/*_test.rb",
    "packs/**/spec/**/*_spec.rb",
  ]
end
```

---

## How it works

### Analyzer — two-pass static analysis

**Pass 1** — collect all class names and metadata (file path, pack, parent class, description from preceding comment block). Handles module-nested classes (`module Foo / class Bar` → `Foo::Bar`).

**Pass 2** — for each file, scan for references to known class names. The intersection of identifiers in the file with the set of known classes gives the dependency list.

### BlastRadius — BFS on the reverse graph

A reverse index maps each class to the services that depend on it. BFS traversal computes the full transitive blast radius with predecessor tracking (`via` field) for path reconstruction. Results are grouped by depth level in `by_depth` and also returned as a flat `affected` array.

### TreeRenderer — ASCII tree from the `via` chain

Reconstructs the parent-child relationships from the `via` field of each entry and renders them as an indented ASCII tree using `├──` / `└──` connectors.

### TestFinder — two-heuristic matching

1. **Naming convention** — strip `_test`/`_spec` suffix from the filename and match against the service name map.
2. **Content scan** — search the test file body for direct references to any of the target class names.

---

## Used by

- [`service_graph_dev`](https://github.com/nildiert/service_graph_dev) — mountable Rails engine that visualizes the dependency graph interactively. Uses `kaskd` as its analysis core via git submodule.

---

## License

MIT
