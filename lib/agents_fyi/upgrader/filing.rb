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
    #   not establish — see `AGENTS.md` on character similarity not being evidence. The
    #   library is the subject the step was about, said here rather than inferred.
    # * **A refusal is not a failure.** A `refused` step is a fact about the ladder's
    #   coverage, and its home is the run record's refusal list, which is what the coverage
    #   figure is measured from. Filing it as a corpus report would file this tool's own
    #   gaps as somebody's breakage.
    module Filing
      # What the report is about. `rails` because the step's subject is the meta-gem and
      # `version` is the release it was being moved to — the pair a caller planning the same
      # upgrade can be found by. Naming a gem the trace mentioned instead would be this tool
      # deciding which of the application's dependencies is at fault, which is exactly the
      # decision it does not make.
      LIBRARY = "rails"

      # Declared, never defaulted. The service's default is PyPI, so a gem filed under it
      # would be compared against the Python corpus — silently, because nothing about the
      # report would look wrong.
      ECOSYSTEM = "ruby"

      # The subject is a library, so the kind is the miner's: a package with a release.
      SUBJECT_KIND = "package"

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

      # The fields the comparison reads, which is narrower than what `POST /reports` takes:
      # `environment` and `attempted` cannot change a verdict, so they are dropped from the
      # draft rather than sent and refused. The body dispatched to both is built once, from
      # `report_for`, so the draft and the submission cannot disagree about what happened.
      PRECHECK_FIELDS = %w[
        title library version ecosystem subject_kind from_version problem trace
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
        {
          "title" => title_for(record: record, first: Record.first_line(tail)),
          "library" => LIBRARY,
          # The release the application was moved *to*: the miner's rule, one level up — a
          # caller searches for what they are about to install, and what they are about to
          # install is the release that broke it.
          "version" => record.to_version.to_s,
          "ecosystem" => ECOSYSTEM,
          "subject_kind" => SUBJECT_KIND,
          "from_version" => record.from_version.to_s,
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

      # File one failed step, or say why nothing was written.
      #
      # Every HTTP failure propagates: a run that silently filed nothing would look exactly
      # like a run that found nothing, which is the miner's rule and the reason
      # `Corpus::RateLimited` is a distinct error over there.
      def self.file(corpus:, record:)
        payload = report_for(record: record)
        return Result.new(action: "skipped", reason: skip_reason(record)) if payload.nil?

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

      # The stage that made this a failure, chosen in the same order `Record.verdict`
      # chooses it — a required stage first, then the suite, then the baseline — so the
      # sentence a reader gets from the verdict and the evidence filed here are about the
      # same command. The first half is `Record.failed_stages` rather than a second copy of
      # the rule, because the rule now has a subtlety (a stage that ran more than once is
      # judged by its last attempt) and two copies of a subtlety is how they disagree.
      def self.failing_stage(record:)
        failed = Record.failed_stages(record.stages)
        return failed.first unless failed.empty?
        return record.suite if record.suite && !record.suite.ok?

        record.baseline
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
          "`#{stage.command}` exited #{stage.exit_code}."
        else
          "`#{stage.command}` did not run: #{Record.first_line(stage.output_tail)}."
                 end
        lines << "Its output began: #{head}" unless head.empty?
        clip(lines.join(" "), MAX_FIELD)
      end

      def self.head_of(text)
        clip(text.to_s.lines.first(HEAD_LINES).join.strip, HEAD_CHARS)
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
        return "`#{stage.command}` did not run (#{Record.first_line(stage.output_tail)})" unless stage.ran

        "`#{stage.command}` exited #{stage.exit_code}"
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
