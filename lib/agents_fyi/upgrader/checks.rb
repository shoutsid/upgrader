# frozen_string_literal: true

require_relative "tests"
require_relative "record"

module AgentsFyi
  module Upgrader
    # **The application's gate, not this tool's opinion of it.**
    #
    # The first complete walks had one check — the suite — while the applications' own CI also ran
    # packwerk, rubocop, a typechecker and a JavaScript build. A green suite was then reported as a
    # green gate, and the pull request said "what established it" about one command. A check is a
    # declaration in the project (`Project::Check`), and this class runs the local ones and records
    # the external ones without ever calling them green.
    #
    # Three answers, the same three `Tests` keeps: passed, failed, and *nothing was established*.
    # The third is `not_run` here, and it is what a command that is missing or was killed by its
    # deadline is — never a failure, because a check that did not run says nothing about the code.
    #
    # **An external check is not a check this walk performed.** The application's GitHub Actions
    # job runs in the application's own environment, with its own cache, on its own runner; calling
    # it passed because the local suite passed is the exact lie this class exists to remove. The
    # result says `external` and carries the declaration's reason, and the PR renders it as "not run
    # here".
    class Checks
      PASSED = "passed"
      FAILED = "failed"
      NOT_RUN = "not_run"
      EXTERNAL = "external"

      # What one check said. `required` is separate from `status` because a required external check
      # is satisfied by being declared and not run here, while a required local check that did not
      # run leaves the rung unverified.
      Result = Struct.new(
        :id, :name, :kind, :command, :required, :external, :environment, :status, :ran,
        :exit_code, :seconds, :output_tail, :reason,
        keyword_init: true
      ) do
        def passed? = status == PASSED

        def failed? = status == FAILED

        def external? = status == EXTERNAL

        def local? = !external

        # **Only a local check can decide the verdict.** An external check is a fact about where the
        # application's gate runs, and this walk did not run it.
        def blocking_failure? = required && local? && failed?

        def blocking_absence? = required && local? && status == NOT_RUN

        def label = name.to_s.empty? ? id : name

        def to_h
          { "id" => id, "name" => name, "kind" => kind, "command" => command,
            "required" => required, "external" => external, "environment" => environment,
            "status" => status, "ran" => ran, "exit_code" => exit_code, "seconds" => seconds,
            "output_tail" => output_tail, "reason" => reason }.compact
        end
      end

      # Run every declared local check, in declaration order, and carry every external one as a
      # result with its reason. `env` is the application's own environment (the test environment for
      # a Rails suite, the run's bundle, the deployment's values); a check that names `development`
      # gets that environment over it, and `ci` is deliberately left as the application's CI
      # environment — this machine cannot reproduce it.
      def self.run(root:, checks:, machine: nil, env: {}, timeout: 1800, stack: Stacks::Rails,
        out: nil)
        Array(checks).map do |check|
          if check.external?
            Result.new(id: check.id, name: check.name, kind: check.kind, command: nil,
              required: check.required, external: true, environment: check.environment,
              status: EXTERNAL, ran: false, reason: check.reason)
          else
            out&.puts("  check: #{check.id}: #{check.command}")
            result = Tests.run(root, Tests::Suite.new(kind: :check, command: check.command,
              reason: "the project declares this check"), timeout: timeout,
              env: check_env(check, env, stack), machine: machine, stack: stack)
            Result.new(id: check.id, name: check.name, kind: check.kind, command: check.command,
              required: check.required, external: false, environment: check.environment,
              status: status_of(result), ran: result.ran, exit_code: result.exit_code,
              seconds: result.seconds, output_tail: result.output_tail,
              reason: reason_for(result))
          end
        end
      end

      # The check as the run's command list carries it. A local check is a command like any other;
      # an external one has no command, so it is left out of the command list rather than recorded
      # as a command that did not run.
      def self.stage(result)
        return nil unless result.local?

        Record::Command.new(stage: Record::CHECK, command: result.command, ran: result.ran,
          exit_code: result.exit_code, seconds: result.seconds, output_tail: result.output_tail)
      end

      def self.status_of(result)
        return NOT_RUN if result.timed_out || !result.ran
        return PASSED if result.passed

        FAILED
      end

      def self.reason_for(result)
        if result.timed_out
          "timed out and was killed with its process group"
        elsif !result.ran
          "did not run (#{Tests.not_run_reason(result)})"
        elsif result.passed
          nil
        else
          "exited #{result.exit_code}"
        end
      end

      def self.check_env(check, env, stack)
        case check.environment
        when "development" then stack.development_env(env)
        else env
        end
      end

      private_class_method :status_of, :reason_for, :check_env
    end
  end
end
