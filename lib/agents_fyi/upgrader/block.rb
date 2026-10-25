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
      # to debug the harness. `rails:update` is the one whose client label is not its kind.
      STAGE_KINDS = {
        Record::PREFLIGHT => "preflight",
        Record::PIN => "pin",
        Record::RAILS_UPDATE => "app_update",
        Record::SUITE => "suite",
        Record::BOOT => "boot",
        Record::CHECK => "check",
        Record::REPAIR => "repair"
      }.freeze

      MAX_EVIDENCE = 8 * 1024

      class << self
        # One record, one list of blocks. `project` is the walk's declared slug; `target_id` and
        # `run_id` are optional because a hand-run `step` knows the repository but not always the
        # queue row. The service fills what it can from the project and leaves the rest alone.
        def from_record(record, project:, target_id: nil, run_id: nil)
          project = project.respond_to?(:slug) ? project.slug.to_s : project.to_s
          return [] if project.empty?

          blocks = []
          Array(record.decisions).each do |change|
            next if change.respond_to?(:checked?) && change.checked?

            blocks << decision_block(record, change, project: project, target_id: target_id,
              run_id: run_id)
          end

          conflicts(record).each do |path|
            blocks << block(
              record, project: project, target_id: target_id, run_id: run_id,
              block_kind: "app_update", subject: "app:update conflict at #{path}",
              question: "`app:update` left #{path} as a conflict. Which version should this " \
                        "application keep, and what in the new one does it need?",
              context: { "file" => path, "stage" => Record::RAILS_UPDATE },
              evidence: { "stage" => Record::RAILS_UPDATE,
                          "failure" => "app:update did not adopt #{path}" },
              change_key: nil
            )
          end

          failed_stages(record).each do |stage|
            kind = STAGE_KINDS[stage.stage.to_s]
            next if kind.nil?

            key, key_source = key_for(stage, record)
            blocks << block(
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

          blocked_checks(record).each do |check|
            blocks << block(
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
          when Record::RAILS_UPDATE
            "`app:update` stopped while moving to Rails #{record.to_version}. What should this " \
              "application keep from the update?"
          when Record::SUITE
            "The suite was green before this rung and red after it. Which change broke it, and " \
              "what is the smallest repair?"
          when Record::BOOT
            "The application did not boot on Rails #{record.to_version}. What does it need " \
              "before the next attempt?"
          when Record::PREFLIGHT
            "The Gemfile could not be prepared for this move. Which line needs a person's " \
              "decision?"
          when Record::CHECK
            "A check in the application's gate did not pass. Which side is wrong: the code, the " \
              "check, or the rung?"
          when Record::REPAIR
            "The repair attempt on Rails #{record.to_version} did not turn the gate green. What " \
              "should the next attempt try?"
          else
            "The walk stopped at #{stage.stage}. What should it do next?"
          end
        end

        def subject_for(stage, record)
          case stage.stage.to_s
          when Record::PIN then "pin Rails #{record.to_version}"
          when Record::RAILS_UPDATE then "app:update at #{record.to_version}"
          when Record::SUITE then "suite at #{record.to_version}"
          when Record::BOOT then "boot at #{record.to_version}"
          when Record::PREFLIGHT then "Gemfile for Rails #{record.to_version}"
          when Record::CHECK then "check #{stage.stage} at #{record.to_version}"
          when Record::REPAIR then "repair at #{record.to_version}"
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

        def key_for(stage, record)
          case stage.stage.to_s
          when Record::PIN then ["ruby|rails|rails", "project"]
          when Record::PREFLIGHT then ["ruby|rails|preflight", "project"]
          when Record::RAILS_UPDATE then ["ruby|rails|app_update", "project"]
          else nil
          end
        end

        def failed_stages(record)
          last = Array(record.stages).group_by { |stage| stage.stage.to_s }
            .transform_values(&:last)
          last.values.reject do |stage|
            # A check is richer in `checks` than in the command list: the check's own label and
            # its declaration are what a person answers, so the command is not a second block.
            stage.nil? || stage.stage.to_s == Record::CHECK ||
              (stage.stage.to_s == Record::RAILS_UPDATE && conflicts(record).any?) ||
              !stage.respond_to?(:ran) || !stage.ran ||
              stage.exit_code.nil? || stage.exit_code.to_i.zero?
          end
        end

        def blocked_checks(record)
          Array(record.checks).select do |check|
            check.respond_to?(:blocking_failure?) ? check.blocking_failure? : false
          end
        end

        def conflicts(record)
          app_update = record.respond_to?(:app_update) ? record.app_update : nil
          return [] unless app_update.is_a?(Hash)

          Array(app_update["conflicts"]).map(&:to_s).reject(&:empty?).uniq
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

        def dedupe(blocks)
          seen = {}
          blocks.each_with_object([]) do |row, out|
            key = [row["block_kind"], row["subject"], row["change_key"]]
            next if seen[key]

            seen[key] = true
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
