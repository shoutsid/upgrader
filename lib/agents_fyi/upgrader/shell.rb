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
      # A command's own output is not a payload; a Rails suite prints megabytes and the
      # record keeps a bounded *excerpt* of it.
      TAIL_BYTES = 4_000

      # **How much of the excerpt is the head, and why it is not zero.** A Ruby failure's
      # *first* lines carry the exception's class and message and its *last* lines carry the
      # frames nearest the failure (or, for a suite, its summary) — so a tail-only bound keeps
      # the least useful half of a stack trace. Measured on the first real walk: every failing
      # command's record showed frames and no error, and the error was in the part that had
      # been dropped. The middle of a long output is where the noise is.
      HEAD_SHARE = 0.4

      # The two ends of an output, kept while it streams. A suite can print hundreds of
      # megabytes, so the middle is dropped *as it flows* rather than after the fact — and
      # what was dropped is counted, so the record says how much it did not keep instead of
      # leaving a reader to assume the output ended.
      #
      # `bytes` bounds the *content*; the marker that says what was dropped is the record's
      # own annotation and is not counted against it (a bound that had to make room for its
      # own explanation would drop output to pay for it).
      class Excerpt
        def initialize(bytes: TAIL_BYTES, head_share: HEAD_SHARE)
          @head_bytes = (bytes * head_share).to_i
          @tail_bytes = bytes - @head_bytes
          @head = +""
          @tail = +""
          @dropped = 0
        end

        def <<(chunk)
          text = chunk.to_s.dup.force_encoding(Encoding::BINARY)
          room = @head_bytes - @head.bytesize
          if room.positive?
            @head << text.byteslice(0, room)
            text = text.byteslice(room, text.bytesize - room).to_s
          end
          @tail << text
          if @tail.bytesize > @tail_bytes
            excess = @tail.bytesize - @tail_bytes
            @dropped += excess
            @tail.replace(@tail.byteslice(excess, @tail_bytes))
          end
          self
        end

        def to_s
          text = @dropped.zero? ? "#{@head}#{@tail}" : "#{@head}\n[...#{@dropped} byte(s) dropped from the middle...]\n#{@tail}"
          text.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
        end
      end

      # `in:` rather than appending `< /dev/null` to argv: that is shell syntax, and
      # there is no shell here. A command that reads stdin and is given a terminal's
      # would wait for an operator who is not there.
      def self.run(argv, stage:, chdir:, env: {}, stdin: File::NULL)
        started = clock
        output, status = Open3.capture2e(env, *argv, chdir: chdir, in: stdin)
        Record::Command.new(
          stage: stage, command: argv.join(" "), ran: !status.exitstatus.nil?,
          exit_code: status.exitstatus, seconds: elapsed(started), output_tail: excerpt(output)
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

      # The excerpt of an output that is already in hand. `Excerpt` is the streaming form and
      # this is the whole-text one; both keep the same two ends.
      def self.excerpt(output, bytes: TAIL_BYTES)
        (Excerpt.new(bytes: bytes) << output).to_s
      end
    end
  end
end
