# frozen_string_literal: true

require "rubygems"

module Agents
  module Upgrader
    # The plan, as a reader sees it.
    #
    # Every line here is either a fact the service gave or a fact the lockfile gave.
    # Nothing is inferred and nothing is filled in, and the two halves of a step stay
    # apart on purpose: one is a digest of Rails' own guide and the other is a record
    # of something executed, and a reader who cannot tell them apart will act on a
    # deprecation as if it were a finding.
    #
    # The count that matters is the split within a step — how much of what this move
    # carries a machine can apply and how much needs a person — because that is the
    # number this whole product exists to raise, and it is the one a plan is for.
    class Plan
      def initialize(payload:, repository:, commit:, lockfile:)
        @payload = payload
        @repository = repository
        @commit = commit
        @lockfile = lockfile
      end

      def to_s
        # `header` is itself a list of lines: concatenated rather than nested, because
        # a plan is one flat document and an array inside an array joins as its own
        # inspect output.
        lines = header + [""]
        steps.each do |step|
          lines.concat(step_lines(step))
          lines << ""
        end
        lines.concat(footer)
        "#{lines.join("\n").rstrip}\n"
      end

      private

      def steps
        @payload.fetch("steps", [])
      end

      def header
        lines = []
        lines << if @commit
          "#{@repository} at #{@commit}"
        else
          "#{@repository} (not a git working tree, so there is no commit to name)"
                 end
        lines << pinned_line
        lines << ruby_line
        lines << floor_line
        lines << "#{steps.size} step(s): #{steps.map { |step| step["name"] }.join(" -> ")}"
        lines
      end

      def pinned_line
        pinned = @lockfile.rails
        return "no Rails release is pinned in Gemfile.lock" unless pinned

        "on Rails #{pinned.version}, read from `#{pinned.gem}` in Gemfile.lock"
      end

      # Three statements about Ruby, none of which is the floor a step needs: the
      # version the lockfile was resolved under, the constraint the Gemfile declares,
      # and what a developer's `.ruby-version` says. Reported together, because a move
      # that ignores them is a move that fails at `bundle install` with a sentence
      # this service already knows how to check for.
      def ruby_line
        known = [
          @lockfile.locked_ruby && "lockfile: ruby #{@lockfile.locked_ruby}",
          @lockfile.declared_ruby && "Gemfile: ruby #{@lockfile.declared_ruby}",
          @lockfile.dot_ruby_version && ".ruby-version: #{@lockfile.dot_ruby_version}"
        ].compact
        return "the Ruby version is not pinned anywhere this tool reads" if known.empty?

        known.join(", ")
      end

      # The highest floor among the steps, because a walk is as demanding as its
      # most demanding step — and the step that demands it is named, because "move
      # Ruby first, on its own" is advice about a particular release.
      def floor_line
        floors = steps.filter_map { |step| [step["to_version"], step["requires_ruby"]] if step["requires_ruby"] }
        return "no step in this move names a Ruby floor" if floors.empty?

        to_version, floor = floors.max_by { |_, version| version_of(version) }
        "Ruby floor this move needs: #{floor} (Rails #{to_version} requires it; per step below)"
      end

      def version_of(value)
        Gem::Version.new(value.to_s)
      rescue ArgumentError
        Gem::Version.new("0")
      end

      def step_lines(step)
        changes = step["changes"] || []
        automatic, decisions = changes.partition { |change| change["automatic"] }

        lines = ["== #{step["name"]} (#{step["from_version"]} -> #{step["to_version"]})"]
        lines << "   requires Ruby #{step["requires_ruby"]} or newer" if step["requires_ruby"]
        lines << "   #{changes.size} documented change(s): #{automatic.size} a machine can apply, " \
                 "#{decisions.size} need a decision"
        # An empty documented list has a reason, and the reason is in the step's own
        # note: it is either a release whose guide chapter this digest has not taken
        # down yet, or a step with nothing that breaks. Printing the list's absence
        # without its reason reads as "nothing to do".
        if changes.empty?
          lines << "   the documented list for this step is empty here"
          lines << "   #{step["note"]}" unless step["note"].to_s.empty?
        end
        automatic.each { |change| lines << "   apply:  #{describe(change)}" }
        decisions.each { |change| lines << "   decide: #{describe(change)}" }
        lines.concat(observed_lines(step))
        lines
      end

      def describe(change)
        replacement = change["replacement"] ? " -> #{change["replacement"]}" : ""
        flags = []
        flags << "raises by your target" if change["enforced_in_your_move"]
        flags << "no call site in source" unless change["findable"]
        flag = flags.empty? ? "" : " [#{flags.join("; ")}]"
        "#{change["subject"]}#{replacement} (#{change["kind"]}; #{change["source"]})#{flag}"
      end

      # The other half, and the half that has to say when it is empty and why. Two
      # different emptinesses: nothing was ever executed inside this step's window, or
      # things were executed and none of them was recorded as a change. Only the
      # first means the documented list is all there is, and the second means the
      # corpus knows something it cannot call a change yet.
      def observed_lines(step)
        observed = step["observed"] || []
        unclassified = step["observed_unclassified"].to_i
        if observed.any?
          lines = ["   executed here: #{observed.size} change(s)"]
          observed.each do |entry|
            worked = entry["from_version"] ? ", still worked in #{entry["from_version"]}" : ""
            lines << "     - #{entry["subject"] || entry["title"]}: broke in #{entry["broken_in"]}" \
                     "#{worked} | #{entry["status"]} | trust #{entry["trust"]}"
          end
          if unclassified.positive?
            lines << "     #{unclassified} report(s) in this window are not recorded as changes"
          end
          lines
        else
          reason = if unclassified.positive?
            "nothing executed here is recorded as a change, and #{unclassified} report(s) " \
              "in this window are not recorded as changes either"
          else
            "nothing this corpus executed falls inside this step's window, so the list " \
              "above is Rails' own guide rather than a finding"
                   end
          ["   executed here: 0 — #{reason}"]
        end
      end

      def footer
        lines = []
        lines << "next: #{@payload["next_step"]}" if @payload["next_step"]
        lines << "guide: #{@payload["guide"]}" if @payload["guide"]
        if @payload["truncated"]
          lines << "partial: one of these components holds more reports than one plan reads, " \
                   "so the executed half is not complete"
        end
        unplaced = @payload["unplaced"].to_i
        lines << "#{unplaced} report(s) about these components could not be placed in any step" if unplaced.positive?
        lines << "nothing was written to #{@repository}, and the service kept nothing"
        lines
      end
    end
  end
end
