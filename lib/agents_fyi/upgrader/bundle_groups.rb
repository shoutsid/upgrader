# frozen_string_literal: true

require "bundler"

module AgentsFyi
  module Upgrader
    # **Which Bundler groups a bundle must include, read from the application's own Gemfile.**
    #
    # Bundler installs `default` and every non-optional group unless it is named in
    # `BUNDLE_WITHOUT`; an `optional: true` group is installed only when `BUNDLE_WITH` names it.
    # The walker installs with `BUNDLE_WITHOUT=development` because a development-only gem is not
    # what a rung is measured against — until a gem the application *needs* sits in one of those
    # groups. Measured on the second real target: `pg` is declared in
    # `group :postgresql, optional: true` because the application supports PostgreSQL and MySQL,
    # its `database.yml` says PostgreSQL, and the fresh bundle therefore had no adapter for the
    # suite it was about to run. The application's CI says the same thing in its own words
    # (`BUNDLE_WITH: ${{ matrix.db }}`), and a walk that ignored it measured a suite about the
    # database instead of about the release.
    #
    # **The reader is Bundler's own DSL, not a regular expression over a Ruby file.** The DSL
    # knows which group a dependency is in and which groups are optional, and evaluating the
    # Gemfile is what `bundle install` does immediately afterwards. A Gemfile the DSL refuses — a
    # `ruby` directive this interpreter does not satisfy, a `path:` gem whose gemspec is gone —
    # answers no groups rather than raising: the install that follows is the authority on whether
    # that Gemfile works at all, and a detection that took the whole step down would replace a
    # bundle error with a parser error.
    class BundleGroups
      # The groups a set of needed gems lives in, and which of those are optional. Symbols and
      # no strings, because that is Bundler's spelling and the caller is the one that writes an
      # environment.
      Result = Struct.new(:groups, :optional, keyword_init: true)

      EMPTY = Result.new(groups: [], optional: []).freeze

      def self.for(root) = new(root: root)

      def initialize(root:)
        @root = root
      end

      # The groups that carry any of `gems`, in declaration order. A gem in two groups is in
      # both; a gem the Gemfile does not declare is in neither.
      def needed(gems)
        wanted = Array(gems).map(&:to_s).uniq
        return EMPTY if wanted.empty? || dsl.nil?

        groups = wanted.flat_map { |name| index.fetch(name, []) }.uniq
        Result.new(groups: groups, optional: groups & optional_groups)
      end

      private

      def dsl
        return @dsl if defined?(@dsl)

        @dsl = begin
          path = File.join(@root, "Gemfile")
          if File.file?(path)
            dsl = Bundler::Dsl.new
            dsl.eval_gemfile(path)
            dsl
          end
        rescue StandardError
          nil
        end
      end

      # `dependency#name => groups`, which is the one fact the DSL will not hand over as a table.
      def index
        @index ||= begin
          found = {}
          Array(dsl&.dependencies).each do |dependency|
            found[dependency.name.to_s] = dependency.groups.map(&:to_sym)
          end
          found
        end
      end

      # **Bundler 2.5 keeps the optional groups on the DSL and offers no reader for them.** The
      # alternative — deciding optionality from the source text — would be a second Gemfile
      # parser beside the one Bundler just used, and the two would disagree about a line neither
      # of them can see (`group :name do` assembled by a method, a block that reopens a group).
      # The ivar is Bundler's, checked by a test that builds an optional group and asks this class
      # for it, so an upgrade that renames it fails here rather than silently stopping detection.
      def optional_groups
        @optional_groups ||= Array(dsl&.instance_variable_get(:@optional_groups)).map(&:to_sym)
      end
    end
  end
end
