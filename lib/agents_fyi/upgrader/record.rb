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
      # What an old application's Gemfile needs before it can be installed at all: a
      # `git://` remote GitHub stopped accepting in 2022, a fork that no longer exists, a
      # pin that cannot sit beside the framework. A stage rather than a silent
      # normalisation, because "the bundle could not be installed" means something
      # different once a preflight has already rewritten two lines of somebody's Gemfile.
      PREFLIGHT = "preflight"
      # Choosing and starting the machine the application's commands run on — the era
      # container for an application whose floor this process's interpreter cannot serve,
      # this process itself when it can. A stage because the choice is a fact the record has
      # to carry: "the bundle could not be installed" means something different on Ruby 2.1
      # than on 3.3, and a record that dropped which machine tried it cannot be read.
      INTERPRETER = "interpreter"
      # The application's own bundle, installed on the unmodified checkout before anything
      # is measured. It is a stage rather than an implementation detail because it is the
      # step that can fail for reasons that are not about the move at all — a gem that will
      # not build on this interpreter, an index that is unreachable — and a record that
      # hid it would report a red baseline with no way to tell why.
      BUNDLE = "bundle"
      # The services a Rails suite expects — PostgreSQL, Redis — started inside the step's
      # own container. A required stage: a suite that ran without its database failed for a
      # reason nobody reading the record could see, and "the suite was green before and red
      # after" is then a finding about the wrong thing.
      SERVICES = "services"
      # The gems that have to move with this rung, from the service's routing answer: a pin
      # whose recorded requirement the target violates and whose newest recorded release
      # fits. A stage of its own because it is a *different question* from the scan's — the
      # scan reads Rails' changes, this reads the application's own gems.
      GEMS = "gems"
      # The research pass that closes the routing's `unknown` pins, by fetching what a gem's
      # index declares. A stage of its own so a walk can be read for how much it had to learn
      # before it could move.
      RESEARCH = "research"
      # One agent attempt at a suite that went red after a green baseline: the model's command,
      # its exit code, and the files it touched. A stage per attempt, because "the suite went
      # green after two repairs" and "it went green on the first try" are different records.
      REPAIR = "repair"

      # The new framework defaults, stepped one at a time and judged by the suite (`Defaults`). Its
      # own stage because each toggle is a suite run, and the record has to say which run was about
      # which default.
      DEFAULTS = "defaults"
      BASELINE = "baseline"
      # The application's own database preparation (`db:create`, `db:test:prepare`), run
      # before the baseline. Deliberately *not* required: a suite that manages its own
      # schema is a normal application, and this stage failing is mentioned beside a failure
      # rather than being one itself (`verdict`).
      DATABASE = "database"
      APPLY = "apply"
      # **The digest's declarations for the rung, made between the pin rewrite and its
      # resolve.** A `declared` entry is about a gem the target framework brings in, so a
      # rung-scoped one cannot be applied while the Gemfile still names the release the move
      # starts from (`Preflight` defers it); this is where it lands. Its own stage because a
      # reader has to see what the digest added beside the pin it made possible.
      DECLARATIONS = "declarations"
      PIN = "pin"
      RAILS_UPDATE = "rails:update"
      BOOT = "boot"
      SUITE = "suite"

      # The stages a step cannot continue past, in the order they happen. Three absences are
      # deliberate.
      #
      # `apply` is not here because an edit the applier refused is an *output* of this tool,
      # not a reason to stop, and the plan already says which changes no machine can make.
      #
      # `interpreter` is not here because it is a selection rather than a step: its failures
      # end the step before this list is consulted (there is no machine to run anything on),
      # and the successful starts that a walk records are commands like any other.
      #
      # `baseline` is not here either, and that one was a bug found by asking what a
      # repository with no suite records. A baseline that could not be run is stored as a
      # not-run command — that is how the record says there was nothing to run — and while
      # it was in this list that not-run command read as a required stage that failed, so a
      # step with no suite came back `failed` where the rule is `unverified`. The suite's
      # outcome, including its absence, is judged by `verdict` itself, below; being
      # ungated here is what lets it be.
      REQUIRED = [PREPARE, SERVICES, PIN, RAILS_UPDATE, BOOT].freeze

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
        # **No exit status is not a success.** A command killed at its deadline has
        # `ran: true` and no exit code, and `nil.to_i` reads that as zero — which is how a
        # timed-out repair would have counted as one that worked.
        def ok?
          ran && !exit_code.nil? && exit_code.to_i.zero?
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
      #
      # Every branch that turns the *suite* into a verdict also names a failed database
      # preparation when there was one, because the two are indistinguishable in the suite's
      # own exit code and a reader acts on them differently: a red suite after a green
      # baseline is a finding about the move, unless the command that loads the test schema
      # never worked, in which case nothing about the move was measured at all.
      # **The failed stages a verdict gates on, one per kind, judged by each kind's last
      # attempt.** The pin is the one stage that may run more than once — each round unlocks the
      # gems bundler said it could not leave alone — and a walk whose pin succeeded on the
      # second round is a walk whose pin succeeded. `filing.rb` reads this same list, so the
      # sentence a reader gets from the verdict and the evidence filed are about one command.
      def self.failed_stages(stages)
        last = stages.group_by(&:stage).transform_values(&:last)
        REQUIRED.filter_map { |stage| last[stage] }.reject(&:ok?)
      end

      def self.verdict(baseline:, suite:, stages:)
        failed = failed_stages(stages)
        unless failed.empty?
          first = failed.first
          return [FAILED, "#{first.stage} did not succeed: `#{first.command}` " \
                          "#{first.ran ? "exited #{first.exit_code}" : 'did not run'}#{database_note(stages)}"]
        end

        if suite.nil?
          return [UNVERIFIED, "no test suite was found in this application, so this step is " \
                              "unverified rather than passed: the ladder's changes were applied " \
                              "and nothing checked them#{database_note(stages)}"]
        end

        unless suite.ran
          return [UNVERIFIED, "the suite did not run (#{suite.exit_code || "no exit code"}), so " \
                              "nothing is established about this step: #{first_line(suite.output_tail)}" \
                              "#{database_note(stages)}"]
        end

        unless baseline&.ok?
          return [UNVERIFIED, "the suite was not green before this step " \
                              "(#{baseline&.ran ? "exit #{baseline.exit_code}" : "it did not run"}), " \
                              "so what it says afterwards cannot be attributed to the move#{database_note(stages)}"]
        end

        if suite.ok?
          repairs = stages.count { |stage| stage.stage == REPAIR && stage.ran }
          return [PASSED, "the suite was green before this step and green after it" \
                          "#{baseline_repair_note(stages)}"] if repairs.zero?

          return [PASSED, "the suite was green before this step and green after #{repairs} agent " \
                          "repair attempt(s); the attempt(s) are in the record" \
                          "#{baseline_repair_note(stages)}"]
        end

        [FAILED, "the suite was green before this step and failed after it " \
                 "(exit #{suite.exit_code})#{repair_note(stages)}#{database_note(stages)}"]
      end

      # **A baseline that was red and then green, as a clause.** The verdict's sentence says
      # "the suite was green before this step" — which is *false* for an application that
      # arrived with a red suite and was repaired before anything was measured, and a record
      # that said it would be describing an application that was measured before it was fixed.
      # The stage list shows the order; this is the line a reviewer reads first.
      def self.baseline_repair_note(stages)
        last_baseline = stages.rindex { |stage| stage.stage == BASELINE }
        return "" if last_baseline.nil?

        before = stages[0...last_baseline]
        return "" unless before.any? { |stage| stage.stage == BASELINE && !stage.ok? }

        repairs = before.count { |stage| stage.stage == REPAIR && stage.ran }
        return "" if repairs.zero?

        " (the baseline was red when the step arrived: #{repairs} agent repair attempt(s) made " \
          "it green before anything was moved)"
      end

      # The repair attempts a failed step carries, as a clause, or "" when there were none.
      def self.repair_note(stages)
        attempts = stages.count { |stage| stage.stage == REPAIR && stage.ran }
        return "" if attempts.zero?

        " — and #{attempts} agent repair attempt(s) did not fix it"
      end

      # The database stage's failure, as a clause for a suite-shaped verdict, or "" when
      # there is nothing to say. Written once so every branch says it the same way.
      def self.database_note(stages)
        stage = stages.find { |command| command.stage == DATABASE }
        return "" if stage.nil? || stage.ok?

        " — and the database preparation failed (`#{stage.command}` " \
          "#{stage.ran ? "exited #{stage.exit_code}" : 'did not run'}: " \
          "#{first_line(stage.output_tail)}), which may be why"
      end

      def self.first_line(text)
        text.to_s.lines.first.to_s.strip
      end

      attr_reader :repository, :commit, :worktree, :from_version, :to_version, :name,
        :requires_ruby, :interpreter, :image, :machine, :era, :stages, :applied, :refused,
        :decisions, :patch, :verdict, :why, :baseline, :suite, :recorded_at

      def initialize(repository:, from_version:, to_version:, verdict:, why:, commit: nil,
                     worktree: nil, name: nil, requires_ruby: nil, interpreter: nil, image: nil,
                     machine: nil, era: nil, stages: [], applied: [], refused: [], decisions: [],
                     patch: "", baseline: nil, suite: nil, recorded_at: nil)
        @repository = repository
        @commit = commit
        @worktree = worktree
        @from_version = from_version
        @to_version = to_version
        @name = name
        @requires_ruby = requires_ruby
        @interpreter = interpreter
        @image = image
        # The machine's identity as the ledger compares it (interpreter, image ref, image
        # digest) and the era's own name, which is what a later cycle reads to try the same
        # interpreter first. The two are not one field: a stamp can name a machine whose era
        # this matrix no longer carries, and that is a fact the selection has to survive.
        @machine = machine
        @era = era
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
      #
      # `machine` and `era` are carried by the two unverified records that are *about* their
      # machine rather than about the application: a step no interpreter could be built for
      # is a verdict that must be re-opened when the matrix grows one, and the stamp it
      # carries is what says so.
      def self.unverified(repository:, from_version:, to_version:, why:, commit: nil,
                          worktree: nil, stages: [], machine: nil, era: nil)
        new(repository: repository, commit: commit, worktree: worktree,
          from_version: from_version, to_version: to_version,
          verdict: UNVERIFIED, why: why, stages: stages, machine: machine, era: era)
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
          "machine" => @machine,
          "era" => @era,
          "verdict" => @verdict,
          "why" => @why,
          "baseline" => @baseline&.to_h,
          "suite" => @suite&.to_h,
          "stages" => @stages.map(&:to_h),
          "applied" => @applied.map { |edit|
                         { "path" => edit.path, "line" => edit.line,
                                               "text" => edit.text, "after" => edit.after,
                                               "subject" => edit.subject,
                                               # **Who made the edit**, where the edit knows: `rule` is
                                               # the ladder's own rewrites, `companion` a gem's own
                                               # upgrade, absent a preflight repair. A reader that
                                               # cannot tell them apart reads a gem's edit as a
                                               # framework change.
                                               "origin" => edit.respond_to?(:origin) ? edit.origin : nil,
                                               # A preflight repair carries the digest's reason for
                                               # the move; a scanned edit does not, because the
                                               # ladder's note for it lives in the plan the step was
                                               # driven from. Nil rather than absent, so a reader
                                               # does not have to test for the key.
                                               "note" => edit.respond_to?(:note) ? edit.note : nil } },
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
        # The interpreter line, or the machine's own sentence when there is no interpreter
        # to print: a record from the "no interpreter installed the bundle" path carries no
        # interpreter (none ran) and would otherwise print the word with nothing after it —
        # the empty-field-reads-as-fresh trap in a report meant to be evidence.
        if @interpreter.to_s.empty?
          lines << "   machine: #{@machine}" unless @machine.to_s.empty?
        else
          lines << "   interpreter #{@interpreter}#{@image.to_s.empty? ? "" : ", image #{@image}"}"
        end
        lines << "   baseline: #{describe(@baseline)}"
        stages.each { |stage| lines << "   #{stage.stage}: #{describe(stage)}" }
        # **A decision with a line to look at and a decision with nothing to look at are different
        # work.** The first is a call site this application has; the second is a change this rung
        # carried that the application does not use — a reviewer reads the first and ticks the
        # second. Counting them together is how "16 need a decision" reads as sixteen edits when it
        # is three.
        located = @decisions.count { |decision| !decision.path.to_s.empty? }
        carried = @decisions.size - located
        lines << "   applied #{@applied.size} edit(s), refused #{@refused.size}, " \
                 "#{@decisions.size} need(s) a decision" \
                 "#{@decisions.empty? ? "" : " (#{located} located, #{carried} carried)}"}"
        # **The applied list holds three kinds of edit, and only two of them have an origin.** A preflight
        # repair (`Preflight::Repair`) is a Gemfile line this step rewrote on the digest's authority,
        # and it has no `origin` because there is no other side to tell it apart from; a scanned or
        # rule-written edit (`Applier::Applied`) does, and a companion's edits say `companion` because
        # they are neither a ladder rule nor a Gemfile repair — they are the edits a *gem's* own upgrade
        # needed. Reading `origin` without asking first is a `NoMethodError` in the one place that
        # renders a finished run — so every run whose preflight repaired a Gemfile raised while printing
        # its summary, which is the shape `AGENTS.md` keeps paying for: a `to_s` the tests never call
        # with the input a real run has.
        origins = @applied.select { |edit| edit.respond_to?(:origin) }
          .map { |edit| edit.origin.to_s }.tally
        by_rule = origins.fetch("rule", 0)
        by_companion = origins.fetch("companion", 0)
        lines << "   #{by_rule} of those edit(s) were made by this tool's own rules" if by_rule.positive?
        lines << "   #{by_companion} of those edit(s) were made by a gem's own upgrade" if
          by_companion.positive?
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
