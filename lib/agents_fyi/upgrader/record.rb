# frozen_string_literal: true

require "json"
require "time"

module AgentsFyi
  module Upgrader
    # What one step did, and the one rule that decides what that means.
    #
    # The verdict is computed here and nowhere else, from the three things that can be
    # known about a move: how far the pipeline got, whether the suite was green
    # *before* the step ran, and what the suite said afterwards. One function, because
    # this repository has already paid for the alternative — a status computed in two
    # places drifts into a status that disagrees with the counts printed beside it.
    #
    # The rule that carries the weight is the baseline, and it is's: without a run of the
    # unmodified checkout, "the upgrade broke the suite" and "the suite was already red" are
    # the same sentence, and the second one files a report blaming a release for a
    # pre-existing breakage. So a verdict about the *suite* requires a green baseline: a red
    # one, before or after, means nothing was established about this move.
    class Record
      PASSED = "passed"
      FAILED = "failed"
      REFUSED = "refused"
      UNVERIFIED = "unverified"

      # The stages, named, because "the step failed" is not actionable and "bundle
      # update failed" is. They are used as stage labels on a `Command`.
      PREPARE = "prepare"
      # The application's own bundle, installed on the unmodified checkout before anything
      # is measured. It is a stage rather than an implementation detail because it is the
      # step that can fail for reasons that are not about the move at all — a gem that will
      # not build on this interpreter, an index that is unreachable — and a record that
      # hid it would report a red baseline with no way to tell why.
      BUNDLE = "bundle"
      BASELINE = "baseline"
      APPLY = "apply"
      PIN = "pin"
      RAILS_UPDATE = "rails:update"
      BOOT = "boot"
      SUITE = "suite"

      # The stages a step cannot continue past, in the order they happen. Two absences are
      # deliberate.
      #
      # `apply` is not here because an edit the applier refused is an *output* of this tool,
      # not a reason to stop, and the plan already says which changes no machine can make.
      #
      # `baseline` is not here either, and that one was a bug found by asking what a
      # repository with no suite records. A baseline that could not be run is stored as a
      # not-run command — that is how the record says there was nothing to run — and while
      # it was in this list that not-run command read as a required stage that failed, so a
      # step with no suite came back `failed` where the rule is `unverified`. The suite's
      # outcome, including its absence, is judged by `verdict` itself, below; being
      # ungated here is what lets it be.
      REQUIRED = [PREPARE, PIN, RAILS_UPDATE, BOOT].freeze

      # A change this step carries that no machine may apply: the service's `manual`
      # half, with the reason it gave. Its own list rather than a flag on a refusal,
      # because the two mean different things — a refusal is a line that did not match,
      # a decision is a change that needs a person — and one field holding both is how
      # a reader acts on the wrong one.
      #
      # `kind`, `replacement` and `source` are the ladder's own words, carried rather
      # than summarised: the service stores a refusal under exactly these fields, where
      # `kind` is "the kind of change, as the ladder names it" and `source` is the
      # chapter of the guide it came from (`Upgrade::Refusal`). The first version of
      # this sent `kind: "plan"` — this tool's word for where the refusal came from — in
      # a field that means what kind of *change* it is, which is the same trap as a field
      # that means two things (`AGENTS.md`). `path` and `line` are present only when the
      # scan found the change in this application, and the change travels either way.
      Decision = Struct.new(
        :path, :line, :subject, :reason, :kind, :replacement, :source, keyword_init: true
      )

      # One thing that ran, and what it said. `ran` and `passed` are separate because
      # a command that never started established nothing: not a failure, not a pass.
      Command = Struct.new(
        :stage, :command, :ran, :exit_code, :seconds, :output_tail,
        keyword_init: true
      ) do
        def ok?
          ran && exit_code.to_i.zero?
        end

        def to_h
          { "stage" => stage, "command" => command, "ran" => ran, "exit_code" => exit_code,
            "seconds" => seconds, "output_tail" => output_tail }
        end
      end

      # The decision, and the sentence a reader gets with it. Returns `[verdict, why]`
      # rather than only the word, because every one of these four needs a reason to be
      # usable and a reason written next to the word is a reason somebody updates.
      #
      # `suite` is the run *after* the step, `baseline` the one before it; either may
      # be nil, and nil means "there was nothing to run", never "it passed".
      def self.verdict(baseline:, suite:, stages:)
        failed = stages.select { |stage| REQUIRED.include?(stage.stage) && !stage.ok? }
        unless failed.empty?
          first = failed.first
          return [FAILED, "#{first.stage} did not succeed: `#{first.command}` " \
                          "#{first.ran ? "exited #{first.exit_code}" : 'did not run'}"]
        end

        if suite.nil?
          return [UNVERIFIED, "no test suite was found in this application, so this step is " \
                              "unverified rather than passed: the ladder's changes were applied " \
                              "and nothing checked them"]
        end

        unless suite.ran
          return [UNVERIFIED, "the suite did not run (#{suite.exit_code || "no exit code"}), so " \
                              "nothing is established about this step: #{first_line(suite.output_tail)}"]
        end

        unless baseline&.ok?
          return [UNVERIFIED, "the suite was not green before this step " \
                              "(#{baseline&.ran ? "exit #{baseline.exit_code}" : "it did not run"}), " \
                              "so what it says afterwards cannot be attributed to the move"]
        end

        return [PASSED, "the suite was green before this step and green after it"] if suite.ok?

        [FAILED, "the suite was green before this step and failed after it " \
                 "(exit #{suite.exit_code})"]
      end

      def self.first_line(text)
        text.to_s.lines.first.to_s.strip
      end

      attr_reader :repository, :commit, :worktree, :from_version, :to_version, :name,
        :requires_ruby, :interpreter, :image, :stages, :applied, :refused, :decisions,
        :patch, :verdict, :why, :baseline, :suite, :recorded_at

      def initialize(repository:, from_version:, to_version:, verdict:, why:, commit: nil,
                     worktree: nil, name: nil, requires_ruby: nil, interpreter: nil, image: nil,
                     stages: [], applied: [], refused: [], decisions: [], patch: "",
                     baseline: nil, suite: nil, recorded_at: nil)
        @repository = repository
        @commit = commit
        @worktree = worktree
        @from_version = from_version
        @to_version = to_version
        @name = name
        @requires_ruby = requires_ruby
        @interpreter = interpreter
        @image = image
        @stages = stages
        @applied = applied
        @refused = refused
        @decisions = decisions
        @patch = patch
        @verdict = verdict
        @why = why
        @baseline = baseline
        @suite = suite
        @recorded_at = recorded_at || Time.now.utc.iso8601
      end

      # A refusal is a record too, and this is how one is built: nothing ran, and the
      # sentence is the whole of the answer.
      def self.refused(repository:, from_version:, to_version:, why:, commit: nil, worktree: nil)
        new(repository: repository, commit: commit, worktree: worktree,
          from_version: from_version, to_version: to_version,
          verdict: REFUSED, why: why)
      end

      # Something ran and nothing about this move is established — the machine failing to
      # make the measurement, as opposed to an application or a service saying no.
      #
      # Its own constructor for the reason `refused` has one: a verdict is not a string a
      # caller picks, and the two are different answers to "what happened". A bundle that
      # cannot be installed is the case this exists for — it is not the move failing, and
      # it is not the application refusing; it is no baseline, which makes every later
      # observation uninterpretable (`AGENTS.md`: a probe that could not be made is not
      # evidence about anything).
      def self.unverified(repository:, from_version:, to_version:, why:, commit: nil,
                          worktree: nil, stages: [])
        new(repository: repository, commit: commit, worktree: worktree,
          from_version: from_version, to_version: to_version,
          verdict: UNVERIFIED, why: why, stages: stages)
      end

      def passed? = @verdict == PASSED
      def failed? = @verdict == FAILED
      def refused? = @verdict == REFUSED
      def unverified? = @verdict == UNVERIFIED

      def to_h
        {
          "repository" => @repository,
          "commit" => @commit,
          "worktree" => @worktree,
          "from_version" => @from_version,
          "to_version" => @to_version,
          "name" => @name,
          "requires_ruby" => @requires_ruby,
          "interpreter" => @interpreter,
          "image" => @image,
          "verdict" => @verdict,
          "why" => @why,
          "baseline" => @baseline&.to_h,
          "suite" => @suite&.to_h,
          "stages" => @stages.map(&:to_h),
          "applied" => @applied.map { |edit|
                         { "path" => edit.path, "line" => edit.line,
                                               "text" => edit.text, "after" => edit.after,
                                               "subject" => edit.subject } },
          "refused" => @refused.map { |edit|
                         { "path" => edit.path, "line" => edit.line,
                                               "text" => edit.text, "found" => edit.found,
                                               "reason" => edit.reason, "subject" => edit.subject,
                                               "kind" => edit.kind,
                                               "replacement" => edit.replacement,
                                               "source" => edit.source,
                                               "note" => edit.note } },
          "decisions" => @decisions.map { |change|
                           { "path" => change.path, "line" => change.line,
                                                     "subject" => change.subject,
                                                     "reason" => change.reason,
                                                     "kind" => change.kind,
                                                     "replacement" => change.replacement,
                                                     "source" => change.source } },
          "patch" => @patch,
          "recorded_at" => @recorded_at,
          # Always true, and worth carrying rather than assuming: this tool's whole
          # product is a patch and a record, and a consumer of the JSON should not have
          # to read the source to know the caller's repository was not touched.
          "wrote_nothing_to_the_repository" => true
        }
      end

      def to_json(*args)
        JSON.generate(to_h, *args)
      end

      # Written where an operator asked for it, and only there: the tool keeps no
      # history of its own runs beyond the ledger's one line per move.
      def write(dir)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        stem = "#{@repository.gsub(/[^A-Za-z0-9._-]/, "-")}-#{@from_version}-#{@to_version}"
        json = File.join(dir, "#{stem}.json")
        patch = File.join(dir, "#{stem}.patch")
        File.write(json, "#{JSON.pretty_generate(to_h)}\n")
        File.write(patch, @patch)
        [json, patch]
      end

      # What an operator reads on stdout. Short, and in the order a decision is made:
      # what was attempted, what it said, and what to do next.
      def to_s
        lines = ["== #{@name || "#{@from_version} -> #{@to_version}"} (#{@repository})"]
        lines << "   worktree #{@worktree}" if @worktree
        lines << "   interpreter #{@interpreter}#{@image ? ", image #{@image}" : ""}"
        lines << "   baseline: #{describe(@baseline)}"
        stages.each { |stage| lines << "   #{stage.stage}: #{describe(stage)}" }
        lines << "   applied #{@applied.size} edit(s), refused #{@refused.size}, " \
                 "#{@decisions.size} need(s) a decision"
        @refused.first(5).each { |edit| lines << "     refused: #{edit.path}:#{edit.line} — #{edit.reason}" }
        @decisions.first(5).each { |change| lines << "     decide: #{change.subject} — #{change.reason}" }
        lines << "   patch: #{@patch.empty? ? "no diff" : "#{@patch.lines.size} line(s)"}"
        lines << "#{@verdict.upcase}: #{@why}"
        lines.join("\n")
      end

      def describe(command)
        return "not run" if command.nil?

        "#{command.command} — " +
          if command.ran
            "exit #{command.exit_code} in #{command.seconds.round(1)}s"
          else
            "did not run (#{command.output_tail.to_s.lines.first.to_s.strip})"
          end
      end
    end
  end
end
