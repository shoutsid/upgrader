# frozen_string_literal: true

module Agents
  module Upgrader
    # **Rails 7.0 deleted classic mode, so Zeitwerk owns the application's autoload paths — and an
    # acronym is a spelling it cannot guess.**
    #
    # Measured at the 7.0 rung, whose suite is green except for one routing example:
    # `Zeitwerk::NameError: expected file /app/lib/sse.rb to define constant Sse, but didn't`. The file
    # defines `module SSE`, which is what this 2013 application calls it, and the events controller
    # `require`s it explicitly. **Taking `lib` off `config.autoload_paths` does not repair it** —
    # measured, the same error comes back, because `lib` is on the loader's paths regardless — and
    # **Zeitwerk's own answer for an acronym is an inflector**: measured,
    # `Rails.autoloaders.main.inflector.inflect("sse" => "SSE")` takes the rung's suite to **201
    # examples, 0 failures**.
    #
    # The file is the application's and its name is its own, so the loader is taught the spelling rather
    # than the other way round. **Only a spelling difference counts.** A file whose constant is a
    # different word is an application whose file is misnamed, which is a decision about its code and not
    # an acronym, and it gets nothing here rather than a wrong inflection.
    module Zeitwerk
      # Where the spellings live. Rails' own guides use this file name, and a second one would be a
      # second place to look for the same fact.
      PATH = "config/initializers/zeitwerk.rb"

      # **The rung this mechanism belongs to, and it is the *only* thing that scopes it.** Rails 6.0
      # has `Rails.autoloaders`, but this application is in classic mode there — the `config.autoloader`
      # setting arrived with Zeitwerk as an option and classic was not deleted until 7.0 — so the
      # initializer's `Rails.autoloaders.main` is `nil` and the boot dies with `undefined method
      # `inflector' for nil:NilClass`. Measured: the same file that takes the 7.0 rung's suite to 201
      # examples, 0 failures fails the 6.0 rung's boot, because a scaffold written for every rung is a
      # file the application cannot load until the rung that made Zeitwerk the only loader.
      RUNG = "7.0"

      class << self
        # The inflector lines the application needs, or `[]` when it needs none. `root` is the
        # application, not the repository: this reads the application's own `lib`. `rung` is the release
        # being moved to, and a rung below `RUNG` gets nothing at all.
        def spellings(root:, rung:)
          return [] unless Rewrites.rung_reached?(RUNG, rung)

          files = Dir.glob(File.join(root, "lib", "**", "*.rb")).sort
          found = files.filter_map { |full| spelling(full, root: root) }
          return [] if found.empty?

          [Rewrites::Scaffold.new(path: PATH, content: "#{found.map { |it| line(*it) }.join("\n")}\n")]
        end

        private

        # `lib/sse.rb` → `["sse", "SSE"]`, or nil when the file needs nothing: no constant this can read,
        # a constant that already matches, or a constant that is a different word.
        def spelling(full, root:)
          relative = full.delete_prefix("#{File.join(root, "lib")}/").delete_suffix(".rb")
          expected = relative.split("/").map { |part| camelise(part) }.join("::")
          defined = File.read(full, encoding: "utf-8")[/^\s*(?:module|class)\s+([A-Z]\w*)\b/, 1]
          return nil if defined.nil? || defined == expected
          return nil unless defined.casecmp?(expected)

          [relative, defined]
        end

        def camelise(part)
          part.split("_").map(&:capitalize).join
        end

        def line(name, constant)
          %(Rails.autoloaders.main.inflector.inflect("#{name}" => "#{constant}"))
        end
      end
    end
  end
end
