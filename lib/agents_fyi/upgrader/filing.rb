# frozen_string_literal: true

require "json"

module AgentsFyi
  module Upgrader
    # A failed step as the report that files it.
    #
    # : an application-level run produces a failure with a release pair, and that is already
    # the corpus's report shape — so a failure becomes a report *by the ordinary path*,
    # precheck first, "so duplicates are the corpus's decision and not the client's".
    #
    #
    # * **The upgrader invents no fix and names no culprit.** It files what the run
    #   established: the move it was making (`from_version` -> `version`), the command that
    #   failed, its exit code, and its output. It does *not* read a stack trace to work out
    #   which gem broke, because a name guessed out of a traceback is a claim the run did
    #   not establish — see `docs/design-notes.md` on character similarity not being evidence. The
    #   library is the component of the change the plan names, or the meta-gem when it names none,
    #   said here rather than inferred from a traceback.
    # * **A refusal is not a failure.** A `refused` step is a fact about the ladder's
    #   coverage, and its home is the run record's refusal list, which is what the coverage
    #   figure is measured from. Filing it as a corpus report would file this tool's own
    #   gaps as somebody's breakage.
    module Filing
      # **The fallback library.** A rung that names a documented change files under that change's
      # ladder component; a failure that names none stays `rails`, because the step's subject is
      # the meta-gem and `version` is the release it was moving to — the pair a caller planning
      # the same upgrade can be found by. Naming a gem the trace mentioned instead would be this
      # tool deciding which of the application's dependencies is at fault, which is exactly the
      # decision it does not make.
      LIBRARY = "rails"

      # Declared, never defaulted. The service's default is PyPI, so a gem filed under it
      # would be compared against the Python corpus — silently, because nothing about the
      # report would look wrong.
      ECOSYSTEM = "ruby"

      # **A framework failure is a platform failure.** The report is about Rails' own change, not
      # about a package the application installed, and `platform` is the corpus's word for that
      # (`Report.subject_kinds`). Filing it as `package` would put a framework break in the same
      # bucket as a gem's release and make the observed half of the ladder read as a gem finding.
      SUBJECT_KIND = "platform"

      # The ladder's four kinds, mapped to the corpus's five. `default_changed` deliberately has no
      # destination: the enum does not declare one (ADR 0011's open item), and a report with a
      # subject and a null kind still joins by its key — the key does not include the kind.
      CHANGE_KINDS = {
        "renamed" => "symbol_renamed",
        "removed" => "symbol_removed",
        "moved" => "symbol_moved"
      }.freeze

      # The ladder's own kinds. A decision effect's refusal carries the *effect* kind (`patch`,
      # `rule`), which is not a change kind and must not become a report's subject.
      LADDER_KINDS = %w[renamed removed moved default_changed config_renamed].freeze

      # Which precheck verdicts are worth filing, and this is the same rule the miner
      # applies in `agents_fyi_miner.corpus.FILABLE` — written twice because the two clients
      # are in different languages and neither can import the other. `duplicate` and
      # `likely_duplicate` mean the corpus already has this and the useful thing to do is
      # verify the report it names; `similar` is filed, because it is the verdict for a
      # finding that is close to something recorded without being close enough to refuse,
      # and a client that stopped at `new` would decline exactly what the duplicate rule has
      # just finished saying is distinct.
      FILABLE = %w[new similar].freeze

      # What the service's models accept for a title and for one text field. Bounded here
      # rather than by truncation at the far end, so what a caller reads is what was sent.
      MAX_TITLE = 300
      MAX_FIELD = 20_000

      # How much of an output becomes the *statement* of the failure, the rest living in
      # `trace`. A runner's first line is the expectation that failed and the second is
      # usually the exception, so a `problem` carrying only the first would hide the error
      # class the corpus indexes; this is a summary and not a second copy of the output.
      HEAD_LINES = 8
      HEAD_CHARS = 2_000

      # The fields the comparison reads, which is narrower than what `POST /api/reports` takes:
      # `environment` and `attempted` cannot change a verdict, so they are dropped from the
      # draft rather than sent and refused. The body dispatched to both is built once, from
      # `report_for`, so the draft and the submission cannot disagree about what happened.
      # **The structured fields are part of the draft too, and they do not change the comparison.**
      # The service's precheck accepts `subject`, `change_kind` and `replacement` and its comparison
      # reads title, library, version, problem, resolution and trace — so sending them makes the
      # draft describe the same report the write will, without moving a `duplicate` or `similar`
      # verdict. A draft that omitted them would still be a truthful comparison, but the two halves
      # of one report would be described by different fields.
      PRECHECK_FIELDS = %w[
        title library version ecosystem subject_kind from_version subject change_kind replacement
        problem trace
      ].freeze

      # What filing did, in a word and a sentence: `filed`, `duplicate` (the corpus already
      # had it), `not_filed` (a precheck verdict that says do not file), or `skipped` (there
      # was nothing to file).
      Result = Struct.new(:action, :verdict, :report_id, :reason, keyword_init: true) do
        def filed? = action == "filed"

        def to_h
          { "action" => action, "verdict" => verdict, "report_id" => report_id, "reason" => reason }
        end
      end

      # The submit body for one failed step, or nil when there is nothing to file.
      #
      # Pure, and that is the point: this is the whole of what the upgrader claims about a
      # failure, so it is a value a test can hold still without a corpus, a network or a
      # Rails application.
      def self.report_for(record:)
        return nil unless record&.failed?

        stage = failing_stage(record: record)
        tail = text(stage&.output_tail, record: record)
        change = change_for(record)
        {
          "title" => title_for(record: record, first: failure_head(stage: stage, tail: tail)),
          # **The change the rung names, when it names one.** The ladder gives a change a
          # component (`activerecord`, `actionpack`, …), and the report's library is that
          # component rather than the meta-gem — the corpus's observed half is read one library
          # per component. A failure that names no change stays `rails`, which is the honest
          # answer and leaves it unclassified rather than guessing a gem out of a traceback.
          "library" => change_library(change),
          # The release the application was moved *to*: the miner's rule, one level up — a
          # caller searches for what they are about to install, and what they are about to
          # install is the release that broke it.
          "version" => record.to_version.to_s,
          "ecosystem" => ECOSYSTEM,
          "subject_kind" => SUBJECT_KIND,
          "from_version" => record.from_version.to_s,
          "subject" => change && change["subject"],
          "change_kind" => change && CHANGE_KINDS[change["kind"].to_s],
          "replacement" => change && change["replacement"],
          "environment" => environment_for(record: record),
          "problem" => problem_for(record: record, stage: stage, head: head_of(tail)),
          # `attempted` is the evidence in the words of what was run, and every clause of it
          # is read off a recorded command rather than composed from what probably happened.
          "attempted" => attempted_for(record: record),
          # The raw output, because every symptom in a trace is indexed and the next caller
          # holding the same traceback is who this report is for. `problem` above is the
          # summary a person reads; this is the text a search matches.
          "trace" => tail
        }
      end

      # **A repair, as a report whose fix is the repair.** The failure is the *problem* — measured
      # before the repair, because that is the failure an application had — and the repair's own diff
      # is the *resolution*. The rung and the suite are the attempt, so a reader can see which move
      # this was and how it was checked.
      #
      # It is filed through the same precheck as a failure: a repair is a claim, and the corpus's
      # duplicate rule is what decides whether it is a new claim or the same one recorded again.
      def self.repair_report_for(record:, outcome:)
        return nil if outcome.nil?

        failure = text(outcome.failure, record: record)
        return nil if failure.strip.empty?

        broken = outcome.before_the_move ? "the baseline" : "the move"
        files = Array(outcome.files)
        gate = outcome.gate.to_s.empty? ? "the suite" : outcome.gate.to_s
        suite = outcome.suite.to_s.empty? ? gate : outcome.suite.to_s
        resolution = +"the repair changed #{files.empty? ? "no file" : files.join(", ")}"
        resolution << ", and #{gate} was green after it."
        resolution << "\n\n```diff\n#{outcome.diff}\n```" unless outcome.diff.to_s.strip.empty?

        change = change_for(record)
        {
          "title" => clip("#{LIBRARY} #{record.to_version}: #{broken} left `#{suite}` red, and a " \
                          "bounded repair made it green — #{Record.first_line(failure)}",
            MAX_TITLE).to_s.rstrip,
          "library" => change_library(change),
          "version" => record.to_version.to_s,
          "ecosystem" => ECOSYSTEM,
          "subject_kind" => SUBJECT_KIND,
          "from_version" => record.from_version.to_s,
          "subject" => change && change["subject"],
          "change_kind" => change && CHANGE_KINDS[change["kind"].to_s],
          "replacement" => change && change["replacement"],
          "environment" => environment_for(record: record),
          "problem" => "A Rails #{record.from_version} -> #{record.to_version} step was measured " \
                       "against this application's own gate: #{broken} (`#{suite}`) was red before " \
                       "the repair, and a bounded repair made it green. Its output began: " \
                       "#{head_of(failure)}",
          "attempted" => "the rung #{record.from_version} -> #{record.to_version} ran #{outcome.attempts} " \
                         "repair attempt(s) in the step's own tree, each followed by `#{suite}` again; " \
                         "the rung's gate is the project's checks plus that suite, never the repair's " \
                         "word. The step carried on after the repair, and its own record is the run " \
                         "this report came from.",
          "trace" => failure,
          "resolution" => resolution
        }
      end

      # One report per repair the step performed. A step that was repaired and passed is the
      # corpus's best shape: a real failure, and the change that resolved it.
      def self.file_repairs(corpus:, record:)
        Array(record&.repairs).filter_map do |outcome|
          payload = repair_report_for(record: record, outcome: outcome)
          next if payload.nil?

          file_payload(corpus: corpus, payload: payload)
        end
      end

      # File one failed step, or say why nothing was written.
      #
      # Every HTTP failure propagates: a run that silently filed nothing would look exactly
      # like a run that found nothing, which is the miner's rule and the reason
      # `Corpus::RateLimited` is a distinct error over there.
      def self.file(corpus:, record:)
        payload = report_for(record: record)
        return Result.new(action: "skipped", reason: skip_reason(record)) if payload.nil?

        # **A failure a rule expected is not a finding.** The rule's `failure` was matched against
        # this run's own output before the run was recorded (`expected_rule`), and the decision id
        # is in the run body's `decisions` list, so the service can retire the rule if the run
        # falsified it. Filing it anyway would file the known failure as new evidence every rung.
        expected = expected_rule(record: record)
        unless expected.nil?
          return Result.new(action: "skipped",
            reason: "expected: `#{expected["change_key"]}` is a known failure of this rung " \
                    "(decision #{expected["decision_id"]}), so it was not filed as a new report")
        end

        file_payload(corpus: corpus, payload: payload)
      end

      # The one path a report takes: precheck, then the write, with the corpus's own verdict deciding
      # which verdicts are worth writing (`FILABLE`) and its duplicate answer at the write read as the
      # corpus already having it.
      def self.file_payload(corpus:, payload:)
        answer = corpus.precheck(precheck_payload(payload))
        verdict = answer.is_a?(Hash) ? answer["verdict"].to_s : ""
        unless FILABLE.include?(verdict)
          return Result.new(
            action: "not_filed", verdict: verdict, report_id: candidate_id(answer),
            reason: not_filed_reason(verdict, answer)
          )
        end

        body = corpus.create_report(payload)
        if body.is_a?(Hash) && body["duplicate"]
          # The precheck said `new` or `similar` and the write collided anyway: two callers
          # can pass the check together, and the corpus's answer at the write is the one
          # that counts. Nothing to retry — the report exists, which is all filing wanted.
          return Result.new(action: "duplicate", verdict: verdict,
            reason: body["detail"].to_s.empty? ? "the corpus already had it" : body["detail"].to_s)
        end

        Result.new(action: "filed", verdict: verdict,
          report_id: (body.is_a?(Hash) ? body["id"] : nil))
      end

      # The draft the comparison reads, derived from the body that would be submitted rather
      # than written a second time: `precheck_payload_for` in the miner exists for the same
      # reason, and two descriptions of one failure is how a caller is told two things.
      def self.precheck_payload(payload)
        payload.each_with_object({}) do |(key, value), draft|
          next unless PRECHECK_FIELDS.include?(key)
          next if value.nil? || value.to_s.empty?

          draft[key] = value
        end
      end

      # **The change the rung names, from the plan the record carries.** A failure's own output is
      # the first place to look: a suite that says `before_filter` is naming the change. A rung that
      # carried exactly one documented change names it too, even when the failure is a stack trace
      # about something else — there is only one change the step could have been about. With several
      # changes and no name in the output, the record's own decisions are the last signal, and a
      # single distinct subject there is the change a person was asked to make. Anything else is
      # genuinely unclassified, and `rails`/nil is the honest answer rather than a guess.
      def self.change_for(record)
        changes = Array(record&.changes).grep(Hash)
        named = failure_text(record).downcase
        mentioned = changes.select do |change|
          subject = change["subject"].to_s
          !subject.empty? && named.include?(subject.downcase)
        end
        return mentioned.max_by { |change| change["subject"].to_s.length } unless mentioned.empty?
        return changes.first if changes.length == 1

        entries = change_entries(record)
        subjects = entries.map { |entry| entry.subject.to_s }.reject(&:empty?).uniq
        candidates = changes.select { |change| subjects.include?(change["subject"].to_s) }
        return candidates.first if candidates.length == 1

        # **A decision or a scan refusal can name a change the plan did not.** The scan starts
        # below the rung, so an earlier rung's change can be located here, and a manual call site
        # the ladder does not document is still a subject the corpus can key a report by. One
        # distinct subject is that change; several are a rung with several questions, and none of
        # them is the change the failure names.
        entry_change(entries) if subjects.length == 1
      end

      # The record's decisions and refusals that name a *ladder change* rather than an effect of
      # one. A rule effect's refusal is about the decision, not about a change the corpus documents.
      def self.change_entries(record)
        (Array(record.decisions) + Array(record.refused)).select do |entry|
          LADDER_KINDS.include?(entry.kind.to_s) ||
            (entry.respond_to?(:component) && !entry.component.to_s.empty?)
        end
      end

      # The change a single decision or refusal names, in the plan's own shape. A decision carries
      # the component and key when it came from the plan; a refusal from the applier carries the
      # ladder's kind and replacement but not the join, so its key is nil and the library falls
      # back to `rails` — the honest answer for a change the plan did not name.
      def self.entry_change(entries)
        entry = Array(entries).find { |candidate| !candidate.subject.to_s.empty? }
        return nil if entry.nil?

        {
          "subject" => entry.subject.to_s,
          "kind" => entry.kind,
          "replacement" => entry.replacement,
          "component" => entry.respond_to?(:component) ? entry.component : nil,
          "change_key" => entry.respond_to?(:change_key) ? entry.change_key : nil
        }
      end

      def self.change_library(change)
        component = change && change["component"].to_s
        component.to_s.empty? ? LIBRARY : component
      end

      # The text an `expect` rule is matched against: the verdict's sentence, the decisive stage's
      # output and every stage's tail. A known failure may be named by the verdict ("the suite was
      # green before this step and failed after it") while its actual message lives in the suite's
      # tail, or the reverse; both are this run's evidence and neither is a different claim.
      def self.failure_text(record)
        parts = [record.why, failing_stage(record: record)&.output_tail,
                 record.baseline&.output_tail, record.suite&.output_tail]
        parts.concat(Array(record.stages).map(&:output_tail))
        parts.compact.map(&:to_s).reject(&:empty?).join("\n")
      end

      # The `expect` rule this run met, or nil. Matching is a case-insensitive substring because
      # the rule's `failure` is a person's statement of the known failure, not a regex: a rule that
      # required the whole output to match would never fire on a suite that adds a timestamp.
      def self.expected_rule(record:)
        return nil if record.nil?

        text = failure_text(record).downcase
        return nil if text.empty?

        rules = Array(record&.expected) + Array(record&.fired_rules)
        rules.find do |rule|
          next false unless rule.is_a?(Hash)

          kind = (rule["kind"] || rule.dig("payload", "kind")).to_s
          next false unless kind == "expect"

          # The client's fired rule carries the mechanism's inner payload; a rule read straight
          # from a declaration carries the service's outer one. Both put `failure` one level down.
          failure = (rule.dig("payload", "failure") ||
                     rule.dig("payload", "payload", "failure")).to_s
          !failure.strip.empty? && text.include?(failure.downcase)
        end
      end

      # The stage that made this a failure, chosen in the same order `Record.verdict`
      # chooses it — a required stage first, then the suite, then the baseline — so the
      # sentence a reader gets from the verdict and the evidence filed here are about the
      # same command. The first half is `Record.failed_stages` rather than a second copy of
      # the rule, because the rule now has a subtlety (a stage that ran more than once is
      # judged by its last attempt) and two copies of a subtlety is how they disagree.
      def self.failing_stage(record:)
        failed = Record.failed_stages(record.stages)
        return failed.first unless failed.empty?

        # The verdict's order: the formatter, then the suite, then the rest of the gate. A check
        # failure with a green suite has no failing stage in `stages` — the check result is its own
        # structure — so it is turned into the command-shaped value the report already knows how to
        # quote. Without this, a lint failure filed the *green baseline* as the problem.
        style = record.stages.find { |stage| stage.stage == Record::STYLE && !stage.ok? }
        return style if style
        return record.suite if record.suite && !record.suite.ok?

        check = Array(record.checks).find(&:blocking_failure?) ||
          Array(record.checks).find(&:blocking_absence?)
        return check_stage(check) if check

        record.baseline
      end

      def self.check_stage(check)
        Record::Command.new(stage: Record::CHECK, command: check.command, display: check.command,
          ran: check.ran, exit_code: check.exit_code, seconds: check.seconds,
          output_tail: check.output_tail)
      end

      def self.title_for(record:, first:)
        head = "#{LIBRARY} #{record.to_version}: a #{record.from_version} -> " \
               "#{record.to_version} upgrade failed"
        return head if first.empty?

        "#{head}: #{first}"[0, MAX_TITLE].to_s.rstrip
      end

      def self.problem_for(record:, stage:, head:)
        lines = ["A Rails #{record.from_version} -> #{record.to_version} step failed in this " \
                 "application#{record.name ? " (#{record.name})" : ''}."]
        lines << if stage.nil?
          "No command in the step reported what failed."
        elsif stage.ran
          "`#{stage.readable}` exited #{stage.exit_code}."
        else
          "`#{stage.readable}` did not run: #{Record.first_line(stage.output_tail)}."
                 end
        lines << "Its output began: #{head}" unless head.empty?
        clip(lines.join(" "), MAX_FIELD)
      end

      def self.head_of(text)
        clip(text.to_s.lines.first(HEAD_LINES).join.strip, HEAD_CHARS)
      end

      # **The line a suite failure is titled by is its first failing example, not the first
      # line it printed.** A suite's excerpt keeps both of its ends, and a Rails 5 run opens
      # with deprecation warnings — measured on the first real walk, where a 4.2.0 -> 5.0.7.2
      # rung that failed eleven controller specs was filed as "… upgrade failed: DEPRECATION
      # WARNING: Accessing mime types via constants is deprecated", which is the title every
      # 5.0 rung in every application would get. The corpus compares reports when it decides a
      # finding is a duplicate, so a title made of noise is also how a *different* failure gets
      # refused as one already recorded. `Failed examples:` is the block that names what broke;
      # a suite printing no such block falls back to its summary line, and anything that is not
      # a suite to its first line, which is what a command's first line always meant.
      def self.failure_head(stage:, tail:)
        text = tail.to_s
        return Record.first_line(text) unless stage&.stage == Record::SUITE

        lines = text.lines.map(&:strip)
        start = lines.index("Failed examples:")
        example = start && lines[(start + 1)..].find { |line| !line.empty? }
        example ||= lines.reverse.find do |line|
          line.match?(/\d+ (?:examples?|runs), .*\b(?:failures?|errors?)\b/)
        end
        example || Record.first_line(text)
      end

      # What this run did, in the order it did it, from the recorded commands alone.
      def self.attempted_for(record:)
        parts = []
        parts << if record.baseline&.ok?
          "The application's suite was green before the step (exit 0)."
        else
          "There was no green suite before the step."
                 end
        ran = record.stages.reject { |stage| stage.stage == Record::BASELINE }.map { |stage| describe(stage) }
        parts << "Then, in order: #{ran.join('; ')}." unless ran.empty?
        parts << "The step applied #{record.applied.size} mechanical edit(s), refused " \
                 "#{record.refused.size}, and left #{record.decisions.size} change(s) needing " \
                 "a person. It ran on a copy this tool made; the repository was not written to."
        clip(parts.join(" "), MAX_FIELD)
      end

      # What a reader is entitled to know before trusting any of the above. The provenance
      # is stated rather than implied, and the thing it states is that the machine which
      # made the change is the machine that checked it — an execution by the author of a
      # finding is not independent reproduction, which is why the corpus's verifiers exist
      # and why this report cannot verify itself.
      def self.environment_for(record:)
        bits = ["upgraded by the agents-fyi upgrader"]
        bits << "on #{record.interpreter}" if record.interpreter
        bits << "in #{record.image}" if record.image
        bits << "at #{record.commit}" if record.commit
        "#{bits.join(' ')}; the application's own suite was the check, and the tool that made " \
          "the change ran it, so this is not an independent reproduction of anything."
      end

      def self.describe(stage)
        return "`#{stage.readable}` did not run (#{Record.first_line(stage.output_tail)})" unless stage.ran

        "`#{stage.readable}` exited #{stage.exit_code}"
      end

      # The same failure met in two checkout directories has to read as the same failure, or
      # the corpus files it twice: the working copy's path is different on every run. It is
      # also the only per-run string a recorded command can carry, which is why this is one
      # substitution rather than a scrub of everything that looks path-ish.
      def self.text(value, record:)
        text = value.to_s
        root = record&.worktree.to_s
        text = text.gsub(root, "<worktree>") unless root.empty?
        clip(text, MAX_FIELD)
      end

      def self.clip(text, limit)
        text.to_s[0, limit].to_s
      end

      # Why nothing was filed, in the words of the verdict that decided it. One sentence per
      # verdict rather than one sentence for all three, because they have different reasons
      # and a reader who is told the wrong one looks in the wrong place: a pass is evidence,
      # an unverified step is an absence of it, and a refusal is this tool's own coverage.
      def self.skip_reason(record)
        return "no record was produced" if record.nil?

        case record.verdict
        when Record::PASSED
          "passed: a step that survived its own suite is evidence for the run record and for " \
            "what the corpus has executed inside this step, and not something broken to report"
        when Record::REFUSED
          "refused: a refusal is a fact about the ladder's coverage, carried in the run's " \
            "refusal list; filing it would report a gap in this tool as somebody's breakage"
        else
          "#{record.verdict}: nothing was established about this step, so there is nothing to report"
        end
      end

      def self.not_filed_reason(verdict, answer)
        advice = answer.is_a?(Hash) ? answer["advice"].to_s : ""
        named = candidate_id(answer)
        sentence = verdict.empty? ? "the precheck answered nothing usable" : "the corpus says #{verdict}"
        sentence += ": #{advice}" unless advice.empty?
        named ? "#{sentence} (report #{named})" : sentence
      end

      def self.candidate_id(answer)
        return nil unless answer.is_a?(Hash)

        candidates = answer["candidates"]
        return nil unless candidates.is_a?(Array) && candidates.first.is_a?(Hash)

        candidates.first["id"]
      end
    end
  end
end
