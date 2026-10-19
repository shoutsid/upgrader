# frozen_string_literal: true

require "json"

module AgentsFyi
  module Upgrader
    # **A project is an application the walk can be pointed at, declared rather than coded.**
    #
    # Everything here is a fact about *somebody's* application: where it lives, which ref the walk
    # starts from, which releases it moves between, how its suite runs, which services it needs, which
    # environment *names* its suite reads, which interpreters it may use, and where a passed rung is
    # delivered. None of it belongs to the engine. Measured on the first complete walk, the engine
    # named `bin/rails`, `bundle exec rspec`, `agents-fyi-services`, `RAILS_SECRET_TOKEN`, the era image
    # prefix and the GitHub target, and every one of those is a property of one application
    # (`docs/refactor/adr/0008`).
    #
    # A project names a **stack** — `rails` today — whose pack knows what a release changes and how a
    # command is spelled for it. The project says *which* of the stack's commands to run and what its
    # suite is called; the pack says how to run them.
    class Project
      # The fields a declaration may carry. **An unknown key is an error rather than a comment:** a
      # typo is a setting that silently does nothing, and a walk that ignores a setting its operator
      # believes is in force is the failure this class exists to prevent.
      FIELDS = %w[slug repo base_ref from to stack suite services env_names eras delivery].freeze

      # What a suite can be. `none` is a real answer, not a missing one: an application without a
      # suite is measured by its boot, and a declaration that says so is not one typo away from a
      # declaration that forgot.
      SUITES = %w[rspec minitest none].freeze

      # Where a passed rung is delivered. `none` is a repository the walk may still commit to but has
      # nowhere to open a request for — the patch and the record are then the product.
      PROVIDERS = %w[github none].freeze

      # The default destination of a branch a rung is published on. `<release>` is the rung's target
      # release, which is what makes one branch per rung the default shape rather than a convention.
      DEFAULT_BRANCH = "agents-fyi/upgrade-<release>"

      # An environment *name*, never a value: `RAILS_SECRET_TOKEN`, not `RAILS_SECRET_TOKEN=…`. The
      # value lives in the deployment (a compose secret, a `suite.env` on the walker's volume) and a
      # project file that carried one would be a secret written into an image and into every record
      # that ever prints the declaration.
      ENV_NAME = /\A[A-Z][A-Z0-9_]*\z/

      # Where the declarations live, beside the client rather than in the repository root: the image
      # copies `lib/`, and a data file the image did not copy is a declaration that reads as absent in
      # the deployment and present everywhere else.
      PROJECTS = File.expand_path("data/projects", __dir__)

      class Invalid < StandardError; end

      # The suite: its dialect, and the command the pack runs it with.
      Suite = Struct.new(:kind, :command, keyword_init: true) do
        def none? = kind == "none"

        def to_h = { "kind" => kind, "command" => command }
      end

      # Where a rung is delivered, and whether each request targets the rung before it.
      Delivery = Struct.new(:provider, :branch, :chain, keyword_init: true) do
        def github? = provider == "github"

        def branch_for(release) = branch.to_s.gsub("<release>", release.to_s)

        def to_h = { "provider" => provider, "branch" => branch, "chain" => chain }
      end

      attr_reader :slug, :repo, :base_ref, :from, :to, :stack, :suite, :services, :env_names,
        :eras, :delivery, :path

      # The declaration named by a slug, from the projects directory.
      def self.find(slug, dir: PROJECTS)
        path = File.join(dir, "#{slug}.json")
        raise Invalid, "no project named #{slug.inspect} in #{dir}" unless File.file?(path)

        load(path)
      end

      def self.load(path)
        text = File.read(path, encoding: "utf-8")
        parse(text, path: path)
      rescue Errno::ENOENT
        raise Invalid, "no project declaration at #{path}"
      end

      # A declaration, validated. Public because the console will write one and has to be able to ask
      # whether it is valid before storing it (`docs/refactor/adr/0008`, the config screen).
      def self.parse(text, path: nil)
        parsed = JSON.parse(text.to_s)
        raise Invalid, "a project declaration is an object, not #{parsed.class}" unless parsed.is_a?(Hash)

        new(parsed, path: path)
      rescue JSON::ParserError => e
        raise Invalid, "the project declaration is not JSON: #{e.message.to_s.lines.first.to_s.strip}"
      end

      def initialize(fields, path: nil)
        @path = path
        unknown = fields.keys - FIELDS
        unless unknown.empty?
          raise Invalid, "unknown field(s) in the project declaration: #{unknown.sort.join(", ")} — " \
                         "known: #{FIELDS.join(", ")}"
        end

        @slug = required(fields, "slug")
        @repo = required(fields, "repo")
        @from = required(fields, "from")
        @to = required(fields, "to")
        @base_ref = optional_text(fields, "base_ref")
        @stack = optional_text(fields, "stack") || "rails"
        @suite = read_suite(fields["suite"])
        @services = read_names(fields["services"] || [], "services")
        @env_names = environment_names(fields["env_names"] || [])
        @eras = read_eras(fields["eras"])
        @delivery = read_delivery(fields["delivery"])
      end

      # The declaration as it would be written back — what the console edits and what a record quotes.
      def to_h
        {
          "slug" => slug, "repo" => repo, "base_ref" => base_ref, "from" => from, "to" => to,
          "stack" => stack, "suite" => suite.to_h, "services" => services,
          "env_names" => env_names, "eras" => eras, "delivery" => delivery.to_h
        }.compact
      end

      # Where the walk starts: the named ref when the declaration has one, the repository's own
      # default branch otherwise. Said as a sentence rather than a nil so the record can quote it.
      def starting_point = base_ref.to_s.empty? ? "the repository's default branch" : base_ref

      # Whether a release is one this project's walk can be asked about.
      def moves_from?(release) = release.to_s == from.to_s

      def suite_command = suite&.command

      private

      def required(fields, name)
        value = fields[name]
        raise Invalid, "the project declaration has no #{name}" if value.nil? || value.to_s.strip.empty?

        value.to_s.strip
      end

      def optional_text(fields, name)
        value = fields[name]
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def read_suite(value)
        return Suite.new(kind: "none", command: nil) if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "suite must be an object with kind and command, not #{value.class}"
        end

        unknown = value.keys - %w[kind command]
        raise Invalid, "unknown suite field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        kind = value["kind"].to_s
        raise Invalid, "suite.kind is #{kind.inspect}; known: #{SUITES.join(", ")}" unless SUITES.include?(kind)

        command = value["command"].to_s.strip
        if kind != "none" && command.empty?
          raise Invalid, "suite.kind is #{kind.inspect} and no command is declared"
        end

        Suite.new(kind: kind, command: command.empty? ? nil : command)
      end

      def read_names(value, field)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
          raise Invalid, "#{field} must be a list of names"
        end

        value.map(&:strip)
      end

      # **Names, never values.** A declaration that carried `RAILS_SECRET_TOKEN=abc` would be a secret
      # in an image and in every record that prints the declaration, so the check is the shape of a
      # name rather than a check for the word "secret".
      def environment_names(value)
        value.each do |name|
          unless name.is_a?(String) && name.match?(ENV_NAME)
            raise Invalid,
              "env_names carries #{name.to_s.inspect}: a name like RAILS_SECRET_TOKEN, never a value — " \
              "the value belongs in the deployment"
          end
        end

        value
      end

      def read_eras(value)
        return "auto" if value.nil?
        return "auto" if value == "auto"

        read_names(value, "eras")
      end

      def read_delivery(value)
        return Delivery.new(provider: "none", branch: nil, chain: false) if value.nil?

        unless value.is_a?(Hash)
          raise Invalid, "delivery must be an object with provider, branch and chain, not #{value.class}"
        end

        unknown = value.keys - %w[provider branch chain]
        raise Invalid, "unknown delivery field(s): #{unknown.sort.join(", ")}" unless unknown.empty?

        provider = value["provider"].to_s
        unless PROVIDERS.include?(provider)
          raise Invalid, "delivery.provider is #{provider.inspect}; known: #{PROVIDERS.join(", ")}"
        end

        Delivery.new(provider: provider, branch: value["branch"] || DEFAULT_BRANCH,
          chain: value.key?("chain") ? value["chain"] == true : true)
      end
    end
  end
end
