# frozen_string_literal: true

require "open3"

module AgentsFyi
  module Upgrader
    # The shell, in one place, so that every command a step runs is recorded the same
    # way and there is exactly one answer to "did it run".
    #
    # Nothing here decides anything: whether a non-zero exit is a failure is the caller's
    # business, because `bundle update` failing and the application's suite failing are
    # different news. What this module guarantees is the *shape* of the record — the command,
    # the exit code, how long it took, and a bounded tail of what it printed — which is what's
    # third rule asks for: every action is a command with an exit code, and no step's success
    # is a judgement.
    #
    # It lives in its own file rather than inside `step.rb` because two things run commands
    # now and neither owns the other: a step discusses with the *machine* it is executing on
    # (`machine.rb`), and the pipeline it drives does as well. A `Shell` that only the step
    # could reach would have made the machine run its own children — two places building a
    # recorded command, which is the drift this module exists to prevent.
    module Shell
      # A command's own output is not a payload; a Rails suite prints megabytes and
      # the record keeps the end of it, where the failure is.
      TAIL_BYTES = 4_000

      # `in:` rather than appending `< /dev/null` to argv: that is shell syntax, and
      # there is no shell here. A command that reads stdin and is given a terminal's
      # would wait for an operator who is not there.
      def self.run(argv, stage:, chdir:, env: {}, stdin: File::NULL)
        started = clock
        output, status = Open3.capture2e(env, *argv, chdir: chdir, in: stdin)
        Record::Command.new(
          stage: stage, command: argv.join(" "), ran: !status.exitstatus.nil?,
          exit_code: status.exitstatus, seconds: elapsed(started), output_tail: tail(output)
        )
      rescue Errno::ENOENT => e
        # The program itself is missing — no `bundle`, no `bin/rails`. Nothing was
        # established, which is not the same as the command failing.
        Record::Command.new(
          stage: stage, command: argv.join(" "), ran: false, exit_code: nil,
          seconds: elapsed(started), output_tail: "#{e.class}: #{e.message}"
        )
      end

      def self.clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.elapsed(started)
        clock - started
      end

      def self.tail(output, bytes: TAIL_BYTES)
        text = output.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        return text if text.bytesize <= bytes

        # From the end, and saying so: a reader has to know the beginning was dropped
        # rather than assume the output started mid-sentence.
        "[...first #{text.bytesize - bytes} byte(s) dropped...]\n#{text.byteslice(-bytes, bytes)}"
      end
    end
  end
end
