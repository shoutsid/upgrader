# frozen_string_literal: true

require "fileutils"
require "find"

module Agents
  module Upgrader
    # **A fresh clone is not a working application, and the difference is the files the
    # repository git-ignores.**
    #
    # An application keeps its local configuration out of its history on purpose — a Rails
    # application's `config/database.yml`, a deployment's `.env`, a fork's
    # `config/diaspora.toml` — and ships a `<name>.example` beside it, which its README tells a
    # person to copy. The walker clones, so it has every file except that one, and then measures
    # an application that has not been configured: the second real target started no PostgreSQL
    # (the services stage reads `database.yml`), and `app:update` exited on the application's own
    # `FATAL: Configuration not found. Copy over diaspora.toml.example`.
    #
    # **The rule is detected, not declared.** It asks the repository two questions and takes a yes
    # to both as permission:
    #
    # * the file is ignored by git (`.gitignore`, `.git/info/exclude`, a nested ignore file — git
    #   itself answers, not a reader of one ignore file), and
    # * the repository ships a tracked sibling named `<file>.example` or `<file>.sample`.
    #
    # A file git does not ignore is not local configuration; one without an example is not
    # something the repository has told a person how to create. An existing target is never
    # overwritten: it belongs to the application's operator, or to an earlier step in this walk,
    # and either is more authoritative than the example.
    #
    # Nothing here is committed. The target is ignored by definition, so `Checkpoint`'s commits
    # and the step's patch cannot carry it — the copy configures *this* working copy for the
    # measurements about to be taken, which is what a person's own copy does.
    class Bootstrap
      # One local file the repository expects and the clone does not have.
      Seed = Struct.new(:path, :source, keyword_init: true) do
        def sentence = "#{path} from #{source} (git-ignored, and the repository ships the example)"
      end

      # One candidate the repository expects and this walk could not create. A copy failure is
      # recorded rather than raised: the stage's job is to say what was not prepared, and the
      # command that needed the file says the rest.
      Failure = Struct.new(:path, :source, :reason, keyword_init: true) do
        def sentence = "#{path} from #{source} could not be copied: #{reason}"
      end

      # Directories that are build output, dependency trees or other tools' state. `vendor` is
      # here whole rather than only `vendor/bundle`: a vendored gem's test fixture named
      # `something.example` is not this application's configuration.
      SKIP_DIRECTORIES = %w[.git node_modules vendor log tmp coverage storage].freeze

      # **The example can come before the extension as well as after it.** `config/database.yml.example`
      # is the spelling this rule was written for; Figaro applications ship
      # `config/application.example.yml`, whose target is `config/application.yml` — the same promise,
      # one suffix further left. Measured on `ohana-api`: the example was tracked and the target
      # ignored, and the rule looked past it, so `bin/rails` died on `Figaro::MissingKeys` for every
      # stage after the install.
      #
      # **The trailing segment is not always the target's extension.** Rails 3/4 applications
      # commonly ship one example per adapter — `config/database.yml.example.pg`,
      # `.example.mysql2`, `.example.sqlite3` — where `.pg` names the variant and the target is
      # `config/database.yml`. Measured on `19wu`: the file was ignored and the examples tracked,
      # and the rule computed `config/database.yml.pg`, so no database file was seeded and every
      # rung's boot died on `Could not load database configuration`. The two readings are told
      # apart by git: the target is the one the repository ignores, which is the same question
      # the rule already asks.
      EXAMPLE = %r{\.(example|sample)(\.[^./]+)?\z}

      # **When several examples promise the same target, the walk configures the one it can
      # serve.** `19wu` ships PostgreSQL, MySQL and SQLite examples; the era images start a
      # PostgreSQL server only, so choosing by filename order would configure MySQL and measure
      # a failure the walk itself caused. The preference is the walker's capability, not a guess
      # about the application: PostgreSQL first, then the adapters the image does not start.
      ADAPTER_PREFERENCE = %w[pg postgres postgresql mysql2 mysql sqlite3 sqlite].freeze

      def self.seed(root, out: nil)
        new(root: root, out: out).seed
      end

      def initialize(root:, out: nil)
        @root = File.expand_path(root.to_s)
        @out = out
      end

      # `[seeds, failures]`, in tree order, so the stage's text is stable across runs.
      def seed
        seeds = []
        failures = []
        candidates.each do |source, target|
          # **One target is configured once.** Several examples can promise it — one per
          # adapter — and the first is the preferred one; copying the rest over it would make
          # the record claim three seeds and leave the last filename's content.
          next if File.exist?(target)

          FileUtils.cp(source, target)
          seed = Seed.new(path: relative(target), source: relative(source))
          seeds << seed
          @out&.puts("  local config: #{seed.sentence}")
        rescue SystemCallError => e
          failure = Failure.new(path: relative(target), source: relative(source),
            reason: "#{e.class}: #{e.message}")
          failures << failure
          @out&.puts("  local config: #{failure.sentence}")
        end
        [seeds, failures]
      end

      private

      # Every `<name>.example`/`.sample` whose target is missing, ignored and whose source is
      # tracked. `Find` rather than a glob because a dependency tree can be gigabytes and the
      # prune is what keeps this a walk of the application.
      def candidates
        found = []
        Find.find(@root) do |path|
          if File.directory?(path)
            Find.prune if path != @root && SKIP_DIRECTORIES.include?(File.basename(path))
            next
          end

          match = path.match(EXAMPLE)
          next if match.nil?
          next unless tracked?(path)

          target = targets(path, match).find do |candidate|
            !File.exist?(candidate) && ignored?(candidate)
          end
          next if target.nil?

          found << [path, target]
        end
        found.sort_by { |source, target| [relative(target), rank(source), relative(source)] }
      end

      # **The two readings of the suffix, decided by git.** `application.example.yml` promises
      # `application.yml`; `database.yml.example.pg` promises `database.yml`, with `.pg` naming
      # the variant. Both are computed, and the caller takes the one the repository ignores — a
      # file git does not ignore is not local configuration, which is the rule's first question.
      # More than one ignored candidate is an ambiguity this class will not resolve by guessing.
      def targets(path, match)
        base = path.sub(EXAMPLE, "")
        suffix = match[2].to_s
        options = [base, suffix.empty? ? nil : "#{base}#{suffix}"].compact.uniq
        ignored = options.select { |candidate| ignored?(candidate) }
        ignored.size == 1 ? ignored : []
      end

      # PostgreSQL first because that is the server the era images start; the other adapters
      # are ranked only so that a repository shipping several examples has a stable answer.
      def rank(source)
        variant = File.basename(source).split(".").last
        ADAPTER_PREFERENCE.index(variant) || ADAPTER_PREFERENCE.length
      end

      # A path git ignores. `--no-index` is deliberately absent: the question is about the file
      # in this working copy, and the answer includes every ignore file above it.
      def ignored?(path)
        _output, status = Checkpoint.git(@root, "check-ignore", "-q", "--", relative(path))
        status&.success? == true
      end

      # The example has to be part of the repository, not a file a previous step left behind.
      def tracked?(path)
        _output, status = Checkpoint.git(@root, "ls-files", "--error-unmatch", "--", relative(path))
        status&.success? == true
      end

      def relative(path)
        path.delete_prefix("#{@root}/")
      end
    end
  end
end
