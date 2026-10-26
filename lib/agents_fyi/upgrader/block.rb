# frozen_string_literal: true

require_relative "record"

module AgentsFyi
  module Upgrader
    # **The walk's stop, as a question the service can keep.**
    #
    # A step's record already says what it could not do: a manual change in `decisions`, a
    # failing stage in `stages`, a conflict `app:update` left, a check that did not pass. None of
    # those is a *work item* until it becomes a question, and ADR 0012 makes it one. This module
    # is deliberately pure: no ledger, no network, no clock. The caller posts what it returns and
    # the service owns the identity, the dedupe key and the lifecycle.
    #
    # **One failed stop is one question, and it is the earliest cause rather than every symptom.** The
    # stages after the first failure fail because of it, the plan's manual changes were not
    # reached, and `app:update` conflicts are the walker's own policy outcome (it always keeps the
    # application's file). Posting all of them is how one unresolvable gem became twenty questions
    # on diaspora and one generator refusal became seventy-three on rails-modular-monolith: every
    # row was true, none was the thing to answer. The walk retries after the cause is answered and
    # the next stop gets its own question then.
    #
    # **`checked` changes are not blocks.** A change the rung carries and this application does
    # not use is a review row, not a question; asking it would fill the operator's queue with
    # work nobody can do. That filter is the same one `Record#to_s` already applies, and it is
    # here rather than in the caller because a second copy is how the two counts drift.
    #
    # **A key is declared, never guessed.** The record's own `change_key` is the only
    # documented key, because the plan put it there. A routing verdict that names a gem can
    # carry a project-scoped key (`ruby|<gem>|<gem>`), and a scan's manual change can carry one
    # for Rails; a suite or boot failure names no library, so its key is nil. A guessed key
    # would join a report to the wrong change, which is worse than a question the promoter
    # cannot use.
    module Block
      # The stage names this client records, mapped to the service's `block_kind` vocabulary.
      # A stage not here is not a stop a person answers: `bundle`, `services` and the other
      # machine stages are the walk's own failures, and a block for one would ask an operator
      # to debug the harness. `rails:update` is absent because it is a generator that is
      # recorded beside the run rather than gated; a blocking check is its own structure and is
      # turned into a block by `check_block`.
      STAGE_KINDS = {
        Record::PREFLIGHT => "preflight",
        Record::PIN => "pin",
        Record::SUITE => "suite",
        Record::BOOT => "boot"
      }.freeze

      # **The stages that can be the cause.** `rails:update` and `repair` are deliberately absent:
      # the first is a generator that is recorded beside the run rather than gated (`Record`'s
      # `REQUIRED` says why), and a failed repair attempt is evidence for the suite or boot failure
      # that follows it, not a stop of its own.
      ROOT_STAGES = [Record::PREFLIGHT, Record::PIN, Record::SUITE, Record::BOOT].freeze

      MAX_EVIDENCE = 8 * 1024

      class << self
        # One record, one list of blocks. `project` is the walk's declared slug; `target_id` and
        # `run_id` are optional because a hand-run `step` knows the repository but not always the
        # queue row. The service fills what it can from the project and leaves the rest alone.
        def from_record(record, project:, target_id: nil, run_id: nil)
          project = project.respond_to?(:slug) ? project.slug.to_s : project.to_s
          return [] if project.empty?

          # **A red baseline is an environment fact, not a question.** A suite that was already
          # red says nothing about the move (`Record.verdict` calls it unverified), and the next
          # attempt is a rerun rather than an answer. Ohana's missing browser became a suite
          # question and parked the target until somebody dismissed and requeued it by hand; the
          # browser is fixed, and this rule is what keeps the next missing service from doing the
          # same.
          return [] if record.respond_to?(:baseline) && record.baseline && !record.baseline.ok?

          blocks = []
          # **The earliest failure is the stop; everything after it is a consequence.** A decision
          # (a scan's manual change, a routing verdict) is not the cause of a failed move — the
          # run had already recorded it and walked on. A conflict is the walker's own policy, not
          # the application's mistake. Only when the record names no failed command and no check
          # does the manual work become the question.
          if (stage = root_stage(record))
            stop = stage_block(record, stage, project: project, target_id: target_id,
              run_id: run_id)
            blocks << stop if stop
          elsif (check = blocking_check(record))
            blocks << check_block(record, check, project: project, target_id: target_id,
              run_id: run_id)
          elsif unaskable_failure?(record)
            # A required stage that is not a decision (`services`, `prepare`) stopped the run. It
            # is a fact about the machine or the repository, and a question would ask a person to
            # debug the harness.
            return []
          else
            Array(record.decisions).each do |change|
              next if change.respond_to?(:checked?) && change.checked?

              blocks << decision_block(record, change, project: project, target_id: target_id,
                run_id: run_id)
            end
          end

          dedupe(blocks)
        end

        private

        def decision_block(record, change, project:, target_id:, run_id:)
          route = change.path.to_s == "Gemfile.lock"
          kind = route ? "route" : "scan_manual"
          key, key_source = key_for_change(change, route: route)
          where = [change.path, change.line].compact.reject { |part| part.to_s.empty? }.join(":")
          block(
            record, project: project, target_id: target_id, run_id: run_id,
            block_kind: kind,
            subject: [change.subject, change.path].compact.reject { |part| part.to_s.empty? }
              .join(" at "),
            question: question_for_change(change),
            context: { "file" => change.path, "line" => change.line,
                       "component" => change.component }.compact,
            evidence: { "failure" => change.reason.to_s,
                        "change_kind" => change.kind,
                        "replacement" => change.replacement,
                        "source" => change.source,
                        "where" => where }.compact,
            change_key: key, change_key_source: key_source
          )
        end

        def question_for_change(change)
          reason = change.reason.to_s.strip
          subject = change.subject.to_s.strip
          if reason.empty?
            "The walk met `#{subject}` and has no mechanical rule for it. What should this " \
              "application do?"
          else
            "The walk met `#{subject}` and stopped: #{reason} What should this application do?"
          end
        end

        def question_for(stage, record)
          case stage.stage.to_s
          when Record::PIN
            "The Rails #{record.to_version} pin could not be resolved. Which gem held it, and " \
              "should the walk move that gem, replace it, or stop here?"
          when Record::SUITE
            "The suite was green before this rung and red after it. Which change broke it, and " \
              "what is the smallest repair?"
          when Record::BOOT
            "The application did not boot on Rails #{record.to_version}. What does it need " \
              "before the next attempt?"
          when Record::PREFLIGHT
            "The Gemfile could not be prepared for this move. Which line needs a person's " \
              "decision?"
          else
            "The walk stopped at #{stage.stage}. What should it do next?"
          end
        end

        def subject_for(stage, record)
          case stage.stage.to_s
          when Record::PIN then "pin Rails #{record.to_version}"
          when Record::SUITE then "suite at #{record.to_version}"
          when Record::BOOT then "boot at #{record.to_version}"
          when Record::PREFLIGHT then "Gemfile for Rails #{record.to_version}"
          else "#{stage.stage} at #{record.to_version}"
          end
        end

        # Only the record's own key is documented. Everything else here is a project-scoped key,
        # and only where the record genuinely names a library or a file: a suite failure has no
        # library, so it has no key and cannot be promoted.
        def key_for_change(change, route:)
          key = change.change_key.to_s.strip
          return [key, "documented"] unless key.empty?

          subject = normalize(change.subject)
          if route
            library = subject.split(/\s+/).first.to_s
            return [nil, nil] if library.empty?

            return ["ruby|#{library}|#{library}", "project"]
          end
          return [nil, nil] if subject.empty?

          ["ruby|rails|#{subject}", "project"]
        end

        def key_for(stage, _record)
          case stage.stage.to_s
          when Record::PIN then ["ruby|rails|rails", "project"]
          when Record::PREFLIGHT then ["ruby|rails|preflight", "project"]
          end
        end

        # The last attempt of every stage that ran and failed, in the order the pipeline first
        # reached them. A stage that ran more than once is judged by its last attempt, the same
        # rule `Record.failed_stages` uses for the verdict.
        def failed_stages(record)
          last = Array(record.stages).group_by { |stage| stage.stage.to_s }
            .transform_values(&:last)
          last.values.reject do |stage|
            # A check is richer in `checks` than in the command list: the check's own label and
            # its declaration are what a person answers, so the command is not a second block.
            stage.nil? || stage.stage.to_s == Record::CHECK ||
              !stage.respond_to?(:ran) || !stage.ran ||
              stage.exit_code.nil? || stage.exit_code.to_i.zero?
          end
        end

        def root_stage(record)
          failed_stages(record).find { |stage| ROOT_STAGES.include?(stage.stage.to_s) }
        end

        # A required stage that failed but is not a stop a person answers (`services`, `prepare`).
        # `Record.failed_stages` names exactly the required ones, so anything it returns here is
        # outside `ROOT_STAGES` — this is not a second list of stages.
        def unaskable_failure?(record)
          !Record.failed_stages(record.stages).empty?
        end

        def stage_block(record, stage, project:, target_id:, run_id:)
          kind = STAGE_KINDS[stage.stage.to_s]
          return nil if kind.nil?

          key, key_source = key_for(stage, record)
          block(
            record, project: project, target_id: target_id, run_id: run_id,
            block_kind: kind,
            subject: subject_for(stage, record),
            question: question_for(stage, record),
            context: { "stage" => stage.stage.to_s, "command" => stage.command.to_s },
            evidence: { "stage" => stage.stage.to_s, "command" => stage.command.to_s,
                        "failure" => clipped(stage.output_tail),
                        "exit_code" => stage.exit_code },
            change_key: key, change_key_source: key_source
          )
        end

        def check_block(record, check, project:, target_id:, run_id:)
          block(
            record, project: project, target_id: target_id, run_id: run_id,
            block_kind: "check", subject: "check #{check.label}",
            question: "The application's `#{check.label}` check failed on this rung. What " \
                      "should change: the application, the check, or the move?",
            context: { "stage" => Record::CHECK, "check" => check.id.to_s },
            evidence: { "stage" => Record::CHECK, "command" => check.command.to_s,
                        "failure" => clipped(check.output_tail),
                        "exit_code" => check.exit_code },
            change_key: nil
          )
        end

        def blocking_check(record)
          Array(record.checks).find do |check|
            check.respond_to?(:blocking_failure?) ? check.blocking_failure? : false
          end
        end

        def block(record, project:, target_id:, run_id:, block_kind:, subject:, question:,
          context:, evidence:, change_key:, change_key_source: nil)
          {
            "project" => project,
            "target_id" => target_id,
            "run_id" => run_id,
            "change_key" => change_key,
            "change_key_source" => change_key_source,
            "rung_from" => record.from_version,
            "rung_to" => record.to_version,
            "block_kind" => block_kind,
            "subject" => subject.to_s.strip[0, 300],
            "question" => question.to_s.strip[0, 4_000],
            "context" => context.compact,
            "evidence" => evidence.compact,
            "options" => [],
            "source" => "walker"
          }.compact
        end

        # **A route's identity is its change key, not the sentence the plan happened to use.** Two
        # writers can name one change differently — the plan's subject and the routing's verdict —
        # and the subject-keyed dedupe kept both. A key is the identity the service's questions already
        # use; a row with no key falls back to its subject.
        def dedupe(blocks)
          seen = {}
          blocks.each_with_object([]) do |row, out|
            key = row["change_key"].to_s
            identity = key.empty? ? [row["block_kind"], row["subject"]] : [row["block_kind"], key]
            next if seen[identity]

            seen[identity] = true
            out << row
          end
        end

        def normalize(value)
          value.to_s.strip.downcase.gsub(/\s+/, " ").tr("|", "/")
        end

        def clipped(value)
          text = value.to_s
          text.bytesize <= MAX_EVIDENCE ? text : "#{text.byteslice(0, MAX_EVIDENCE)}…"
        end
      end
    end
  end
end
