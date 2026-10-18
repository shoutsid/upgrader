# frozen_string_literal: true

require "bundler"

module AgentsFyi
  module Upgrader
    # What an application's own lockfile says about the Rails release it is on.
    #
    # Read with `Bundler::LockfileParser` rather than with a regex over the file, and
    # that is the ecosystem's rule rather than a convenience: a `Gemfile.lock` has a
    # grammar — a `specs:` tree whose indentation *is* the dependency graph, a
    # `RUBY VERSION` section, platform variants, a `BUNDLED WITH` trailer — and the
    # parser that ships with the interpreter is the one Bundler itself uses. The
    # service read the same file its own way (`api/app/lockfile.py`), because it had
    # to read a Gemfile.lock without Ruby; that is one reader more than this project
    # likes, and it is why this side does not add a third.
    class Lockfile
      # Raised when there is nothing to read at all.
      class Missing < StandardError; end

      # Raised when there is a lockfile and it cannot be parsed. A separate class from
      # `Missing` because the two want different sentences: one says "this is not a
      # Bundler application", the other says "this file is broken", and a bundle that
      # is broken is usually a working tree somebody interrupted.
      class Unreadable < StandardError; end

      # Which pinned gem carries the Rails version, in the order that reads it right.
      #
      # The meta-gem first, because it names the release the application believes it
      # is on. `railties` next, because an application that pins the framework as
      # components instead still pins that one and its version *is* the Rails
      # version. The rest only as a last resort: a component can be held back on its
      # own, and a plan that read `actionmailer`'s version as "the Rails version" of
      # an application on 7.1 would be wrong in a way nobody would notice until the
      # edits did not apply.
      COMPONENTS = %w[
        rails railties activerecord actionpack activesupport actionview
        activemodel actionmailer activejob actioncable activestorage
      ].freeze

      # The version, and the gem it was read from — both, because a plan that says
      # "Rails 4.2.11" about an application pinning only `activerecord` is claiming
      # to know something it inferred, and a reader is entitled to see which line of
      # their own lockfile it came from.
      Pinned = Struct.new(:gem, :version, keyword_init: true)

      # Guards the two process-global pieces of state the parse needs. One mutex and
      # not a per-call wrapper, because the state is a property of the process:
      # `serve` (phase 3) reads many applications in one process, and two parses
      # interleaving here would resolve one application's relative remote against
      # another's directory — a plan about the wrong repository that looks ordinary.
      ROOT_LOCK = Mutex.new

      def self.read(root)
        path = File.join(root, "Gemfile.lock")
        raise Missing, "no Gemfile.lock under #{root}" unless File.file?(path)

        new(path: path, root: root)
      end

      attr_reader :root

      def initialize(path:, root:)
        @root = root
        @parsed = parse(path, root)
        @specs = @parsed.specs.to_h { |spec| [spec.name, spec.version.to_s] }
      end

      # The Rails release, and the gem that names it, or nil when the application
      # pins neither the meta-gem nor a component this knows about.
      def rails
        chosen = COMPONENTS.find { |name| @specs.key?(name) }
        chosen && Pinned.new(gem: chosen, version: @specs[chosen])
      end

      def rails_version
        rails&.version
      end

      # The interpreter the lockfile was resolved under (`RUBY VERSION`): what the
      # application last succeeded against, which is a fact about the machine rather
      # than a requirement.
      def locked_ruby
        return nil unless @parsed.respond_to?(:ruby_version)

        value = @parsed.ruby_version.to_s.strip
        value.empty? ? nil : value.sub(/\Aruby\s+/, "")
      end

      # The `ruby "3.1.4"` line in the Gemfile: a constraint Bundler enforces, which
      # is a different statement from `.ruby-version` (what a developer happened to
      # have installed). Both are reported, and neither is treated as the floor —
      # the floor comes from the step, which knows what Rails itself requires.
      def declared_ruby
        gemfile = File.join(@root, "Gemfile")
        return nil unless File.file?(gemfile)

        match = File.read(gemfile).match(/^\s*ruby\s+["']([^"']+)["']/)
        match && match[1]
      end

      def dot_ruby_version
        path = File.join(@root, ".ruby-version")
        return nil unless File.file?(path)

        value = File.read(path).strip
        value.empty? ? nil : value
      end

      # Every pinned gem, for a caller that wants to look something else up later.
      def specs
        @specs.dup
      end

      # Every gem the lockfile pins at this exact version, sorted. **Rails releases its
      # framework components in lockstep**, so this is how a lockfile spells "the framework":
      # an application's `rails`, `actionpack`, `activemodel` and the rest are all at one
      # version, and the gems that merely depend on them (`rake`, `sprockets-rails`) are not.
      # The pin reads it to name the gems that have to move with the meta-gem.
      def pinned_at(version)
        @specs.select { |_name, pinned| pinned == version.to_s }.keys.sort
      end

      # **What the resolved graph requires of a name, as the graph itself states it.** Every spec in
      # the file lists the requirements it places on the gems it depends on, so this is the resolver's
      # own answer about whether some version is still acceptable — read out of its output rather than
      # probed with a second resolve. The pin reads it to tell a gem the move had no reason to touch
      # from one that has to move: measured on the lighthouse, the resolve moved thirty gems, and
      # holding all of them made every resolve impossible, because twenty-eight of them were the
      # framework's own new requirements (`activesupport 4.1` asks `i18n >= 0.6.9, ~> 0.6` against the
      # application's 0.6.4) while `rake` had nothing to do with it.
      def required_of(name)
        @parsed.specs.flat_map do |spec|
          # This Bundler hands a spec its dependencies as a list of `Gem::Dependency` rather than as
          # the name-keyed hash the lockfile is written in, so the name is what is matched on.
          spec.dependencies.select { |dependency| dependency.name == name }.map(&:requirement)
        end
      end

      # Whether the resolved graph still accepts this version of this gem.
      def accepts?(name, version)
        required_of(name).all? { |requirement| requirement.satisfied_by?(Gem::Version.new(version)) }
      end

      # **What the gem itself required, at the version this file pins.** The other half of "does this
      # version still fit": a gem can be accepted by every requirement placed on it and still be
      # impossible to keep, because its own dependencies have moved past what it asks for. Measured on
      # the lighthouse, `rspec 2.13.0` passes the first half and fails this one — it requires
      # `rspec-core ~> 2.13.0` while the rspec-rails move puts rspec-core at 2.14 — and holding it cost
      # three rounds of bundler naming rspec-mocks, rspec-expectations and rspec-core before the pin
      # gave up. A name the file does not pin requires nothing.
      def requires_of(name)
        spec = @parsed.specs.find { |candidate| candidate.name == name }
        return {} unless spec

        spec.dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }
      end

      private

      # Parse the file with the *application* as Bundler's root.
      #
      # A lockfile that vendors a gem names a relative remote — `remote: .`,
      # `remote: vendor/gems/dotenv-2.0.1` — and Bundler resolves that against its
      # root, which it takes from `BUNDLE_GEMFILE` rather than from the parser. Given
      # only the file's contents it raises `Bundler::GemfileNotFound`, and that is not
      # an exotic shape: it is how a Rails application pins a patched gem. huginn at
      # `v2022.01.04` is the first real repository this was pointed at, and it
      # vendors dotenv exactly that way — while every fixture in the suite used
      # absolute remotes, which is why nothing here had noticed.
      #
      # Both pieces of state are process-global, so both are set, reset around the
      # parse and handed back in an `ensure`: the environment variable, and Bundler's
      # own memo of the root it resolved. Without the reset the *next* read in this
      # process would keep the previous application's root.
      def parse(path, root)
        contents = File.read(path)
        gemfile = File.join(root, "Gemfile")
        # No Gemfile beside the lockfile: the root Bundler may use is whatever it finds by
        # walking *up*, and that search has to start where the lockfile is rather than
        # where this process happens to be running.
        #
        # **That distinction is not academic, and this repository is the proof.** The
        # application's own `Gemfile` is at the repository root, so a process started in
        # `upgrader/` — which is how the suite runs — was inside a Bundler application,
        # and a bare `LockfileParser` resolved a vendored `remote:` of a lockfile in a
        # scratch directory against *this repository's* `vendor/`. The answer then
        # depended on where the process was started rather than on the file being read,
        # which is the one thing this reader must never do. With the walk-up anchored at
        # the lockfile, a tree with no Gemfile anywhere above it has no root to give
        # Bundler and the parse says so — which is a better answer than borrowing one.
        return parse_from(root) { Bundler::LockfileParser.new(contents) } unless File.file?(gemfile)

        ROOT_LOCK.synchronize do
          previous = ENV.fetch("BUNDLE_GEMFILE", nil)
          ENV["BUNDLE_GEMFILE"] = gemfile
          Bundler.reset!
          begin
            Bundler::LockfileParser.new(contents)
          ensure
            if previous.nil?
              ENV.delete("BUNDLE_GEMFILE")
            else
              ENV["BUNDLE_GEMFILE"] = previous
            end
            Bundler.reset!
          end
        end
      rescue StandardError => e
        raise Unreadable, "#{path} could not be read as a Gemfile.lock: #{e.class}: #{e.message}"
      end

      # Run a parse with the process's directory moved to `root`, and put it back.
      #
      # `Dir.chdir` is process-global, which is why this lives inside the same lock the
      # root itself does: `serve` reads many applications in one process, and a parse
      # that left the process somewhere else would make every later relative path a
      # statement about the wrong repository. The `ensure` restores it even when the
      # parse raises, which is the case this method exists for.
      def parse_from(root)
        ROOT_LOCK.synchronize do
          previous = Dir.pwd
          begin
            Dir.chdir(root)
            Bundler.reset!
            yield
          ensure
            Dir.chdir(previous)
            Bundler.reset!
          end
        end
      end
    end
  end
end
