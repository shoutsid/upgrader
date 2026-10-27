# frozen_string_literal: true

require "open3"

module Agents
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

      # **A resolver's message is evidence, and the block that names the cause sits in its middle.** The
      # excerpt exists because a Rails suite prints megabytes and its middle is noise; a `bundle update`'s
      # output is the opposite — it prints a handful of "Bundler could not find compatible versions for gem
      # X" blocks and *each* of them is a candidate cause, with the real one neither first nor last.
      # Measured twice on the 6.0 rung: the `rack`, `sprockets`, `globalid` and `ffi` blocks a reader saw
      # were every one of them satisfiable, and the block that actually failed the resolve (`zeitwerk
      # (~> 2.1, >= 2.1.8) … ruby (>= 3.2)`, and before it `bootsnap … ruby (>= 2.3)`) had been dropped from
      # the middle of the record — so the cause had to be found by replaying the resolve by hand. 64 KB
      # still bounds it (a resolve's whole message is a few kilobytes) and it stops the record being a place
      # a cause can hide.
      RESOLVER_BYTES = 64_000

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
      #
      # **`timeout` is the half that is easy to leave out, and leaving it out cost a walk.** A pipeline
      # command whose container could not reach rubygems sat in `bundle update` for nine minutes and would
      # have sat there for the hour a hand-run step allows, because nothing bounded it: `--step-timeout`
      # bounds a *suite* and the corpus client bounds an HTTP call, and this is neither. A command killed at
      # its bound established nothing about the application, which is the same third answer a missing
      # program is — so it is reported the way `Tests` reports a killed suite rather than as a failure.
      def self.run(argv, stage:, chdir:, env: {}, stdin: File::NULL, timeout: nil,
                   excerpt_bytes: TAIL_BYTES, display: nil)
        started = clock
        status, text, timed_out = spawn_with_deadline(
          argv, chdir: chdir, env: env, stdin: stdin, timeout: timeout,
          excerpt: Excerpt.new(bytes: excerpt_bytes)
        )
        Record::Command.new(
          stage: stage, command: argv.join(" "), display: (display || argv).join(" "),
          ran: !timed_out,
          exit_code: status && status.exitstatus, seconds: elapsed(started),
          output_tail: timed_out ? killed_at_the_bound(argv, timeout, text) : text
        )
      rescue Errno::ENOENT => e
        # The program itself is missing — no `bundle`, no `bin/rails`. Nothing was
        # established, which is not the same as the command failing.
        Record::Command.new(
          stage: stage, command: argv.join(" "), display: (display || argv).join(" "),
          ran: false, exit_code: nil,
          seconds: elapsed(started), output_tail: "#{e.class}: #{e.message}"
        )
      end

      # How long a killed child's process group gets to shut down before the group is killed outright.
      KILL_GRACE_SECONDS = 3

      # **How long a pipeline command may run, and it exists to stop the *unbounded* case rather than a slow
      # one.** A `bundle install` on a cold cache is minutes and a resolve that reaches rubygems is slower, so
      # the number is generous; what it catches is a container that cannot reach the network at all, which held
      # one walk in `bundle update` until somebody noticed. `UPGRADER_COMMAND_TIMEOUT` is the knob.
      DEFAULT_COMMAND_TIMEOUT = 900
      ENV_TIMEOUT = "UPGRADER_COMMAND_TIMEOUT"

      # **The one place a child is spawned.** `Tests` grew this first — a suite needs a deadline, a kill that
      # reaches the workers it forks, and both ends of its output — and `Shell.run` had none of it, which is
      # the drift this module exists to prevent. Both callers get the same answer now: `[status, text,
      # timed_out]`, with `status` nil when the deadline passed.
      #
      # Its own process group is load-bearing: a Rails suite forks workers and a `docker exec` may leave
      # children, and a kill aimed at the process alone leaves them holding the pipe.
      # `analysis` is a second, larger excerpt for a caller that has to *read* the output rather
      # than record it — a suite's failure list is longer than the record's bound, and the two
      # readers want different answers from the same stream.
      def self.spawn_with_deadline(argv, chdir:, env: {}, stdin: File::NULL, timeout: nil, excerpt: nil,
                                   analysis: nil)
        excerpt ||= Excerpt.new
        reader, writer = IO.pipe
        pid = Process.spawn(env, *argv, chdir: chdir, pgroup: true, in: stdin, out: writer, err: writer)
        writer.close

        reading = Thread.new { drain(reader, excerpt, analysis) }
        waiting = Thread.new { Process.waitpid2(pid) }
        if waiting.join(timeout)
          reading.join(2)
          close(reader)
          [waiting.value.last, excerpt.to_s, false]
        else
          kill_group(pid)
          waiting.join(KILL_GRACE_SECONDS + 2)
          reading.join(1)
          close(reader)
          [nil, excerpt.to_s, true]
        end
      end

      # Reads the child's output on a thread of its own and keeps only the two ends of it. Both halves are
      # load-bearing: a pipe holds 64 KB, so a command that prints more than that blocks for ever waiting for
      # a reader that only arrives after it exits; and the excerpt is bounded because this text is recorded.
      def self.drain(reader, excerpt, analysis = nil)
        while (chunk = reader.read(65_536))
          excerpt << chunk
          analysis << chunk unless analysis.nil?
        end
      rescue IOError, Errno::EBADF
        # The pipe was closed under this thread, which is what happens when a run is killed and nothing is
        # left holding the write end.
      end

      # Termination first, so a child that can shut down cleanly does; the whole group after a grace, because
      # one that traps the signal would otherwise hold the cycle for ever. `Errno::ESRCH` means it was already
      # gone, which is the answer this wants.
      def self.kill_group(pid)
        signal_group(pid, "TERM")
        deadline = clock + KILL_GRACE_SECONDS
        while clock < deadline
          return if group_gone?(pid)

          sleep 0.05
        end
        signal_group(pid, "KILL")
      end

      def self.signal_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def self.group_gone?(pid)
        Process.kill(0, -pid)
        false
      rescue Errno::ESRCH
        true
      end

      def self.close(io)
        io.close unless io.closed?
      rescue IOError
        nil
      end

      # What a killed command's excerpt becomes: the bound is named, and so is the difference between this
      # and a failure. `Tests` says the same thing for a suite in one sentence, and a reader of either should
      # not have to work out which of the two they are looking at.
      def self.killed_at_the_bound(argv, timeout, text)
        note = "#{argv.join(" ")} was killed at its #{timeout}-second bound, so this step is unverified " \
               "rather than failed"
        text.to_s.empty? ? note : "#{text}\n#{note}"
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
