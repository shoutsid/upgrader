# frozen_string_literal: true

require "json"
require "time"
require "uri"

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
      JAVASCRIPT = "javascript"
      ASSETS = "assets"
      APPLY = "apply"
      # **The decisions this project has already made, applied before anything is scanned.** Its own
      # stage because a reader has to see that the tree was not as the application left it *before* the
      # scan read it — and the edits carry `origin: decision:<id>`, so the stage and the applied list
      # agree about which decision made them.
      DECISIONS = "decisions"
      # **The digest's rung-scoped entries, made between the pin rewrite and its resolve.** A
      # `declared` entry is about a gem the target framework brings in, and a rewrite is about a
      # line that release asks for, so neither can be applied while the Gemfile still names the
      # release the move starts from (`Preflight` defers both); this is where they land. Its own
      # stage because a reader has to see what the digest changed beside the pin it made possible.
      DECLARATIONS = "declarations"
      PIN = "pin"
      RAILS_UPDATE = "rails:update"
      # **The formatter, and it is part of the step rather than a commit somebody makes afterwards.**
      # A style commit added after the suite has passed is a change the suite never saw; running the
      # formatter before the suite is what makes "the branch is the run's own head" true.
      STYLE = "style"
      BOOT = "boot"
      SUITE = "suite"
      # **One command from the application's own gate.** A check result is structured (`Checks`),
      # and this label is how the same command appears in the record's command list. It is not in
      # `REQUIRED`: a failed check is named by `verdict`, so the sentence says *which* check failed
      # rather than "a check stage did not succeed".
      CHECK = "check"

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
      # that means two things (see `docs/design-notes.md`). `path` and `line` are present
      # only when the scan found the change in this application, and the change travels
      # either way.
      Decision = Struct.new(
        :path, :line, :subject, :reason, :kind, :replacement, :source, :component, :change_key,
        keyword_init: true
      )

      # One thing that ran, and what it said. `ran` and `passed` are separate because
      # a command that never started established nothing: not a failure, not a pass.
      Command = Struct.new(
        :stage, :command, :ran, :exit_code, :seconds, :output_tail, :display,
        keyword_init: true
      ) do
        # **No exit status is not a success.** A command killed at its deadline has
        # `ran: true` and no exit code, and `nil.to_i` reads that as zero — which is how a
        # timed-out repair would have counted as one that worked.
        def ok?
          ran && !exit_code.nil? && exit_code.to_i.zero?
        end

        # **`command` is what ran and `display` is what it was asked to do**, and the two are the
        # same string for every stage this tool runs itself. They differ for a stage a *machine*
        # ran: `docker exec --interactive --user 10003:999 --workdir /agents-fyi/targets/… -e
        # BUNDLE_PATH=… <container> bundle update rails --conservative` is the evidence, and
        # `bundle update rails --conservative` is the fact. The record keeps both — the run's own
        # page and the API's `argv` read `command`, a filed report reads `display` — because a
        # report that made a reader wade through a container id to reach "the pin exited 7" is a
        # report whose reason is buried under its plumbing. `nil` rather than a copy: a stage with
        # no machine has one answer, and `to_s` of a missing field is that answer.
        def readable = display.to_s.empty? ? command.to_s : display.to_s

        def to_h
          { "stage" => stage, "command" => command, "display" => display, "ran" => ran,
            "exit_code" => exit_code, "seconds" => seconds, "output_tail" => output_tail }
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

      def self.verdict(baseline:, suite:, stages:, checks: [])
        failed = failed_stages(stages)
        unless failed.empty?
          first = failed.first
          return [FAILED, "#{first.stage} did not succeed: `#{first.command}` " \
                          "#{first.ran ? "exited #{first.exit_code}" : 'did not run'}#{database_note(stages)}"]
        end

        # **The formatter has the same three answers as every other command.** A formatter that
        # ran and failed is a failed rung; one that is not installed established nothing, and
        # `unverified` is the verdict that says so rather than blaming the application.
        style = stages.find { |stage| stage.stage == STYLE }
        if style
          if style.ran && !style.ok?
            outcome = style.exit_code.nil? ? "was killed before it finished" :
              "exited #{style.exit_code}"
            return [FAILED, "the style formatter `#{style.command}` #{outcome}" \
                            "#{database_note(stages)}"]
          end
          unless style.ran
            return [UNVERIFIED, "the style formatter `#{style.command}` did not run, so the " \
                                "application's formatting was not measured#{database_note(stages)}"]
          end
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
          # **The suite is one check, not the gate.** A green suite with a red lint or packwerk
          # check has not established the rung, and the PR must not say it did. The failure names
          # the check and its exit code; an external check never reaches this branch, because this
          # walk did not run it.
          failed_check = Array(checks).find(&:blocking_failure?)
          if failed_check
            return [FAILED, "the suite passed, and the #{failed_check.label} check failed " \
                            "(#{failed_check.reason})"]
          end

          absent_check = Array(checks).find(&:blocking_absence?)
          if absent_check
            return [UNVERIFIED, "the suite passed, and the #{absent_check.label} check did not " \
                                "run (#{absent_check.reason}), so the application's gate was not " \
                                "measured"]
          end

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
        :decisions, :patch, :verdict, :why, :baseline, :suite, :recorded_at, :brief, :repairs,
        :checks, :commits, :accepted_decisions, :app_update, :toolchain, :project, :changes,
        :expected, :fired_rules
      # The corpus's id for the run, learned after the record is written and used by the pull
      # request to link the run's page. It is an accessor rather than a constructor argument
      # because the record is the local artifact and the id is the service's answer.
      attr_accessor :run_id

      def initialize(repository:, from_version:, to_version:, verdict:, why:, commit: nil,
                     worktree: nil, name: nil, requires_ruby: nil, interpreter: nil, image: nil,
                     machine: nil, era: nil, stages: [], applied: [], refused: [], decisions: [],
                     patch: "", baseline: nil, suite: nil, recorded_at: nil, brief: nil,
                     repairs: [], checks: [], commits: [], accepted_decisions: [], app_update: nil,
                     toolchain: nil, project: nil, changes: [], expected: [], fired_rules: [])
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
        # The memory the rung was walked with (`Brief`). Nil for a refusal that never got as far as
        # asking, and that is a different fact from a brief the corpus answered with nothing.
        @brief = brief
        # The repairs this step performed (`Repair::Outcome`): the baseline's and the move's. Kept
        # apart from the patch because the patch is what the rung *is*, and a repair is what made it
        # pass — the distinction the corpus's reports are filed on.
        @repairs = repairs
        # **The rest of the application's gate**, as `Checks::Result` values. The suite is not in
        # this list: it is `baseline`/`suite`, and the PR renders it as the first check.
        @checks = checks
        # **The concern-sized commits this step made**, in order. The tree's HEAD is the delivered
        # head, and this list is what lets the PR say which commit is which concern instead of one
        # "as this tool made it" commit a reviewer has to read whole.
        @commits = commits
        # The accepted decisions the tree was walked with (`Project#decisions`), rendered in the PR
        # as question/answer/why rather than as a list of line patches.
        @accepted_decisions = accepted_decisions
        # What `app:update` did: adopted files, conflicts, policy skips and the framework-default
        # state. Its own field because a reviewer asks about it separately from "what changed".
        @app_update = app_update
        # The application's declared build facts. The run quotes them beside the interpreter that
        # actually executed it, so a Ruby the declaration names and a Ruby the matrix chose are
        # visibly two answers rather than one.
        @toolchain = toolchain
        # **The declaration the walk read, quoted into the record.** The project profile is a
        # reviewable artifact even when it lives on the walker's volume: a PR that carries the
        # profile it was walked from can be checked against the application without opening a
        # second system, which is the whole point of making the profile data.
        @project = project
        # **The rung's documented changes, as the plan gave them.** A failed step is filed
        # against the change it names (`Filing`), and the change's component, subject and
        # replacement live in the plan rather than in the failure's prose — so the record
        # carries them, and the report can join the corpus without guessing from a traceback.
        @changes = changes
        # **The rules the project declared that could apply here, and the ones that did.**
        # `expected` is every accepted `expect` rule in force on this rung; `fired_rules` is
        # the subset that actually did something (a skip, an applied rewrite, or an expected
        # failure met). The run body sends their decision ids in its existing `decisions`
        # field, which is how the service retires a rule a failed run falsified.
        @expected = expected
        @fired_rules = fired_rules
        @run_id = nil
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
      # observation uninterpretable (a probe that could not be made is not
      # evidence about anything; see `docs/design-notes.md`).
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
          "brief" => @brief&.to_h,
          "repairs" => @repairs.map(&:to_h),
          "checks" => @checks.map(&:to_h),
          "commits" => @commits,
          "accepted_decisions" => @accepted_decisions.map(&:to_h),
          "app_update" => @app_update,
          "toolchain" => @toolchain,
          "project" => @project,
          "run_id" => @run_id,
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
                                                     "source" => change.source,
                                                     "component" => change.component,
                                                     "change_key" => change.change_key } },
          "changes" => @changes,
          "expected" => @expected,
          "fired_rules" => @fired_rules,
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

      # **The inverse of `to_h`, so a run can be replayed without re-walking it.** A dry-run
      # review of a stored record needs the same objects the PR renderer reads; rebuilding them
      # from the JSON is what makes "replay the three applications" a command over their records
      # rather than a second walk.
      def self.from_h(hash)
        raise ArgumentError, "a record is an object, not #{hash.class}" unless hash.is_a?(Hash)

        hash = normalize(hash)
        %w[repository from_version to_version verdict].each do |field|
          if hash[field].to_s.strip.empty?
            raise ArgumentError, "the record has no #{field}, so there is nothing to preview"
          end
        end
        unless [PASSED, FAILED, REFUSED, UNVERIFIED].include?(hash["verdict"].to_s)
          raise ArgumentError, "the record's verdict is #{hash["verdict"].to_s.inspect}; known: " \
                               "#{PASSED}, #{FAILED}, #{REFUSED}, #{UNVERIFIED}"
        end
        %w[app_update toolchain project].each do |field|
          value = hash[field]
          unless value.nil? || value.is_a?(Hash)
            raise ArgumentError, "the record's #{field} is not an object"
          end
        end

        stages = commands_from(hash["stages"])
        # **The stage list is the fallback for the two commands a preview reads most.** A record
        # written before the dedicated fields, or a service envelope whose commands were normalised,
        # still has the baseline and suite among its stages; absence of the field is not absence of
        # the evidence.
        baseline = command_from(hash["baseline"]) || stages.find { |stage| stage.stage == BASELINE }
        suite = command_from(hash["suite"]) || stages.find { |stage| stage.stage == SUITE }
        record = new(
          repository: hash["repository"], commit: hash["commit"], worktree: hash["worktree"],
          from_version: hash["from_version"], to_version: hash["to_version"], name: hash["name"],
          requires_ruby: hash["requires_ruby"], interpreter: hash["interpreter"],
          image: hash["image"], machine: hash["machine"], era: hash["era"],
          stages: stages,
          applied: applied_from(hash["applied"]),
          refused: refusals_from(hash["refused"]),
          decisions: decisions_from(hash["decisions"]),
          patch: hash["patch"].to_s,
          baseline: baseline, suite: suite,
          verdict: hash["verdict"], why: hash["why"], recorded_at: hash["recorded_at"],
          brief: brief_from(hash["brief"]), repairs: repairs_from(hash["repairs"]),
          checks: checks_from(hash["checks"]),
          commits: list_of(hash["commits"], "commits"),
          accepted_decisions: list_of(hash["accepted_decisions"], "accepted_decisions"),
          app_update: hash["app_update"], toolchain: hash["toolchain"],
          project: hash["project"], changes: list_of(hash["changes"], "changes"),
          expected: list_of(hash["expected"], "expected"),
          fired_rules: list_of(hash["fired_rules"], "fired_rules")
        )
        record.run_id = hash["run_id"]
        record
      end

      # **Two shapes, one record.** `step --record` writes the local record (`repository`, `stages`,
      # `baseline`, `suite`); the service's `GET /api/upgrades/runs/{id}` answers a run envelope
      # (`repo_url`, `commands`, `refusals`). A preview should read either, and silently treating the
      # service's shape as an empty local record would render "suite not declared" and "risk: low"
      # over a run that says `failed`. Normalising here is what keeps the two honest.
      def self.normalize(hash)
        return hash unless service_shape?(hash)

        run = hash["run"].is_a?(Hash) ? hash["run"] : hash
        commands = hash["commands"].is_a?(Array) ? hash["commands"] : []
        stages = commands.filter_map { |command| service_command(command) }
        {
          "repository" => run["repo_url"],
          "commit" => run["commit"],
          "from_version" => run["from_version"],
          "to_version" => run["to_version"],
          "verdict" => run["verdict"],
          "why" => run["note"],
          "image" => run["image"],
          "recorded_at" => run["recorded_at"] || run["finished_at"],
          "stages" => stages,
          "baseline" => stages.find { |stage| stage["stage"] == BASELINE },
          "suite" => stages.find { |stage| stage["stage"] == SUITE },
          "refused" => Array(hash["refusals"]).map { |refusal| service_refusal(refusal) },
          "patch" => hash["patch"].to_s
        }
      end

      def self.service_shape?(hash)
        hash.key?("run") || (hash.key?("repo_url") && !hash.key?("repository"))
      end

      def self.service_command(command)
        return nil unless command.is_a?(Hash)

        argv = command["argv"] || command["command"]
        argv = argv.join(" ") if argv.is_a?(Array)
        output = [command["stdout_tail"], command["stderr_tail"]].compact.reject(&:empty?).join("\n")
        {
          "stage" => command["stage"], "command" => argv.to_s, "display" => argv.to_s,
          "ran" => !command["exit_code"].nil?, "exit_code" => command["exit_code"],
          "seconds" => command["duration_ms"].to_f / 1000.0, "output_tail" => output
        }
      end

      def self.service_refusal(refusal)
        return {} unless refusal.is_a?(Hash)

        {
          "path" => refusal["path"], "line" => refusal["line"],
          "text" => nil, "found" => nil,
          "reason" => refusal["note"].to_s.empty? ? "recorded by the service" : refusal["note"],
          "subject" => refusal["subject"], "kind" => refusal["kind"],
          "replacement" => refusal["replacement"], "source" => refusal["source"],
          "note" => refusal["note"]
        }
      end

      def self.command_from(hash)
        return nil if hash.nil?
        return hash if hash.is_a?(Command)
        raise ArgumentError, "a stage is not an object" unless hash.is_a?(Hash)
        raise ArgumentError, "a stage has no name" if hash["stage"].to_s.empty?

        Command.new(stage: hash["stage"], command: hash["command"], display: hash["display"],
          ran: hash["ran"], exit_code: hash["exit_code"],
          seconds: hash["seconds"].nil? ? 0.0 : hash["seconds"].to_f,
          output_tail: hash["output_tail"])
      end

      def self.commands_from(list)
        list_of(list, "stages").map { |item| command_from(item) }
      end

      def self.applied_from(list)
        list_of(list, "applied").map do |edit|
          Applier::Applied.new(path: edit["path"], line: edit["line"], text: edit["text"],
            after: edit["after"], subject: edit["subject"], origin: edit["origin"],
            note: edit["note"])
        end
      end

      def self.refusals_from(list)
        list_of(list, "refused").map do |edit|
          Applier::Refused.new(path: edit["path"], line: edit["line"], text: edit["text"],
            found: edit["found"], reason: edit["reason"], subject: edit["subject"],
            kind: edit["kind"], replacement: edit["replacement"], source: edit["source"],
            note: edit["note"])
        end
      end

      def self.decisions_from(list)
        list_of(list, "decisions").map do |change|
          Decision.new(path: change["path"], line: change["line"], subject: change["subject"],
            reason: change["reason"], kind: change["kind"],
            replacement: change["replacement"], source: change["source"],
            component: change["component"], change_key: change["change_key"])
        end
      end

      def self.checks_from(list)
        return [] if list.nil?
        raise ArgumentError, "the record's checks is not a list" unless list.is_a?(Array)

        list.map do |check|
          next check if check.is_a?(Checks::Result)
          raise ArgumentError, "the record's checks carries an item that is not an object" unless
            check.is_a?(Hash)
          raise ArgumentError, "a check has no status" if check["status"].to_s.empty?

          Checks::Result.new(id: check["id"], name: check["name"], kind: check["kind"],
            command: check["command"], required: check["required"], external: check["external"],
            environment: check["environment"], status: check["status"], ran: check["ran"],
            exit_code: check["exit_code"], seconds: check["seconds"],
            output_tail: check["output_tail"], reason: check["reason"])
        end
      end

      def self.list_of(list, field)
        return [] if list.nil?
        raise ArgumentError, "the record's #{field} is not a list" unless list.is_a?(Array)

        list.each do |item|
          raise ArgumentError, "the record's #{field} carries an item that is not an object" unless
            item.is_a?(Hash)
        end
        list
      end

      def self.brief_from(hash)
        return nil if hash.nil?
        return hash if hash.is_a?(Brief::Result)
        raise ArgumentError, "the record's brief is not an object" unless hash.is_a?(Hash)

        sections = list_of(hash["sections"], "brief.sections").map do |section|
          Brief::Section.new(key: section["key"], title: section["title"],
            question: section["question"], state: section["state"], note: section["note"],
            total: section["total"], items: items_from(section["items"]))
        end
        Brief::Result.new(sections: sections, asked: hash["asked"],
          truncated: hash["truncated"], unavailable: hash["unavailable"])
      end

      def self.items_from(list)
        list_of(list, "brief.items").map do |item|
          Brief::Item.new(id: item["id"], title: item["title"], library: item["library"],
            version: item["version"], status: item["status"], trust: item["trust"],
            rank: item["rank"], match: item["match"], fix: item["fix"],
            change_key: item["change_key"], project: item["project"],
            authority: item["authority"], effects: item["effects"])
        end
      end

      def self.repairs_from(list)
        list_of(list, "repairs").map do |repair|
          Repair::Outcome.new(failure: repair["failure"], suite: repair["suite"],
            attempts: repair["attempts"], files: repair["files"], diff: repair["diff"],
            before_the_move: repair["before_the_move"])
        end
      end

      # Written where an operator asked for it, and only there: the tool keeps no
      # history of its own runs beyond the ledger's one line per move.
      #
      # The stem is readable rather than the raw repository string sanitized: a URL becomes
      # `owner-name`, a declaration's `owner/name` the same, and a local path its basename.
      # The raw form put `https---github.com-...` in front of every file, which is not a name
      # an operator wants to type into `preview`.
      def self.stem(repository, from_version, to_version)
        name = readable_repository(repository)
        "#{name.gsub(/[^A-Za-z0-9._-]/, "-")}-#{from_version}-#{to_version}"
      end

      def self.readable_repository(repository)
        text = repository.to_s
        if text.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          path = URI.parse(text).path.to_s
          parts = path.split("/").reject(&:empty?)
          parts.length >= 2 ? parts.last(2).join("-") : File.basename(path)
        elsif text.start_with?("git@") && text.include?(":")
          path = text.split(":", 2).last
          parts = path.split("/").reject(&:empty?)
          parts.length >= 2 ? parts.last(2).join("-") : File.basename(path)
        elsif text.start_with?("/", ".", "~") || !text.include?("/")
          File.basename(text)
        else
          text.split("/").reject(&:empty?).last(2).join("-")
        end.delete_suffix(".git")
      rescue URI::InvalidURIError
        File.basename(text).delete_suffix(".git")
      end
      private_class_method :readable_repository

      def write(dir)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        stem = Record.stem(@repository, @from_version, @to_version)
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
        # its summary, which is the shape the design notes keep paying for: a `to_s` the tests never call
        # with the input a real run has.
        origins = @applied.select { |edit| edit.respond_to?(:origin) }
          .map { |edit| edit.origin.to_s }.tally
        by_rule = origins.fetch("rule", 0)
        by_companion = origins.fetch("companion", 0)
        lines << "   #{by_rule} of those edit(s) were made by this tool's own rules" if by_rule.positive?
        lines << "   #{by_companion} of those edit(s) were made by a gem's own upgrade" if
          by_companion.positive?
        unless @checks.empty?
          lines << "   checks: #{@checks.map { |check| "#{check.id} #{check.status}" }.join(", ")}"
        end
        lines << "   commits: #{@commits.length} concern(s)" if @commits.any?
        if @fired_rules.any?
          lines << "   rules: #{@fired_rules.map { |rule| "#{rule["kind"]} #{rule["change_key"]}" }.join(", ")}"
        end
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
