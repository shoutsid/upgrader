# frozen_string_literal: true

require_relative "shell"

# The suite candidates are the stack's, so this file has a load-time dependency on the pack. Said
# here rather than left to the library's require list, because a test that loads this file alone
# (`test/tests_test.rb` does) must still see `Stacks::Rails`.
require "agents/upgrader/stacks"

module Agents
  module Upgrader
    # Does this application have a suite, and what happened when it ran?
    #
    # Two decisions, and both are the difference between a record that means
    # something and one that lies.
    #
    # **Detection is a lookup with a documented order, not an inference.** The table below is
    # read top to bottom and the first match wins, so an application that has both a
    # `Rakefile` and `bin/rails` is run the way Rails 5 and later document rather than the way
    # Rails 4 did. An application that matches no entry is *not* guessed at: it has no suite
    # this tool knows how to run, and the step's verdict is `unverified` —'s fourth rule.
    #
    # **Running a suite has three answers, not two** — it passed, it failed, or it
    # never ran at all (not installed, killed by a signal, timed out). Only the first
    # two are statements about the code. Conflating the third with "failed" is how a
    # pre-existing red suite gets filed as a finding about a release, which is the one
    # mistake this whole product must not make.
    class Tests
      # What to run, and why *this* is the entry a repository gets. `kind` is a Symbol
      # and decides the environment the run happens in (see `machine_test_env`).
      Suite = Struct.new(:kind, :command, :reason, keyword_init: true)

      # What happened. Five fields rather than a boolean, because a caller has to be
      # able to tell a suite that failed (a finding) from one that never started
      # (nothing established) and from one that had to be killed (also nothing).
      # `output_tail` is what the record keeps, and `output` is what the *repair* reads. They are
      # two bounds because they protect two things: the record is sent to the service and written
      # into a pull request, while a repair has to see the whole failure list before it can decide
      # anything. Measured on the biddingapp 6.0 rung: the suite printed about 60 KB of failures,
      # the record's 20 KB excerpt began inside the list, and the parser saw three truncated blocks
      # and none of the template failures — so the mechanism looked broken while the fixtures passed.
      Result = Struct.new(
        :command, :ran, :passed, :exit_code, :seconds, :output_tail, :output, :timed_out,
        keyword_init: true
      )

      # `sh` reports "command not found" as 127 — it is how a missing `bundle` arrives,
      # since every command here goes through a shell. It is treated as *not run*
      # rather than as a suite that failed, which is the distinction the class exists
      # for: a machine without Bundler has established nothing about the application.
      NOT_FOUND = 127

      # How long a suite gets to shut down after its termination signal before the
      # whole group is killed outright. Long enough for a test process to flush what it
      # was writing, short enough that a suite which traps TERM cannot hold a cycle:
      # the alternative is a step that never returns.
      # **The suite candidates are the stack's, not this runner's.** What a suite is called and in what
      # order the shapes are tried is a fact about the framework — the order is argued where the table
      # lives, `Stacks::Rails::SUITES` — and this class only runs what it is handed.
      CANDIDATES = Stacks::Rails.suite_candidates

      # The suite to run, or nil when there is none this tool knows how to run. A nil
      # is a *refusal to guess* rather than an absence: a `test/` directory with no
      # Rakefile and no `bin/rails` has a suite, and how to run it is not stated in
      # anything this tool reads — so it is not run, and `no_suite_reason` says what
      # was looked for.
      def self.detect(root, declared: nil, stack: Stacks::Rails)
        base = File.expand_path(root)
        # **A declared suite wins over detection.** The project's declaration is the operator's
        # statement about its own application, and a suite this tool would have guessed differently
        # is a disagreement worth failing on rather than quietly overriding — the rung says
        # `unverified` with the declared command in the record.
        if declared && !declared.none?
          return Suite.new(kind: declared.kind.to_sym, command: declared.command,
            reason: "the project declares this suite")
        end

        found = stack.suite_candidates.select { |candidate| candidate[:matches].call(base) }
        return nil if found.empty?

        entry = found.first
        others = found.drop(1).map { |other| other[:command] }
        reason = entry[:reason]
        unless others.empty?
          reason = "#{reason}; #{others.join(", ")} could also have been run, and this is the " \
                   "one the repository states for itself"
        end
        Suite.new(kind: entry[:kind], command: entry[:command], reason: reason)
      end

      # What a repository with no suite we can run is told, named for the record. It
      # lists where it looked, because "no suite" without that is indistinguishable
      # from a tool that looked in the wrong place — and it says what the verdict is,
      # because the sentence ends up in the record of a step.
      def self.no_suite_reason(root, stack = Stacks::Rails)
        looked = stack.no_suite_looked_for
        joined = looked.length < 2 ? looked.join : "#{looked[0..-2].join(", ")} and #{looked[-1]}"
        "no suite this tool knows how to run under #{File.expand_path(root)}: it looked for " \
          "#{joined}. A step whose suite cannot be run is `unverified`, never `passed`."
      end

      # The environment a suite of this kind has to run under, from the stack pack that knows the
      # framework. Named by the pack rather than by this runner because a suite that runs without
      # it boots in a different environment from the one the walk is measuring.
      def self.machine_test_env(stack = Stacks::Rails) = stack.test_env

      # Run it, and say which of the three answers it was.
      #
      # `env` is merged over the test environment for a Rails suite and over nothing
      # for anything else, so a caller can override a key deliberately and cannot
      # accidentally run a Rails suite without `RAILS_ENV`. The output is kept as a
      # *tail* (`tail_bytes`): a suite can print hundreds of megabytes, this text goes
      # into a durable record, and the last screen of output is what a reader needs.
      #
      # `machine` is where the suite runs — this process, or an era container the step
      # owns (`Machine`). The command is *stated* by the application (`bundle exec rspec`)
      # and the machine wraps it: a container run reaches the suite through `sh -lc`, and
      # the environment travels as `-e` flags rather than being inherited, because the
      # walker's own environment names paths on the host. `nil` is the native machine, kept
      # so a caller that has no machine does not have to say so twice.
      # **A suite's excerpt is five times a command's, and it is the tail only.** Four kilobytes is
      # one failure message with its backtrace; a Rails suite prints the messages between the
      # load-time noise and the summary, so a two-ended bound keeps the noise and the list of
      # failing examples and drops the reasons. Measured on the 6.0 rung: the record named six
      # failing examples and not one exception, because the head was thirty lines of deprecation
      # warnings and the tail was the summary. A *command* is the opposite — a Ruby exception's
      # first lines are its class and message — which is why `Shell.run` keeps both ends and this
      # does not. **Twenty kilobytes is the record's bound, not the failure list's**: a red suite's
      # blocks are longer than that (measured: about 60 KB for six template failures), which is why
      # the repair reads `output` and only the record reads this.
      SUITE_EXCERPT_HEAD_SHARE = 0.0
      SUITE_EXCERPT_BYTES = 20_000

      # **What the repair reads, and why it is not the record's bound.** RSpec prints its failure
      # blocks before the summary, and a block that arrives without its header is not a failure the
      # parser can repair. The full capture is bounded for the same reason the tail is — a suite may
      # print hundreds of megabytes — but a megabyte is a hundred failures, and both ends are kept
      # so a suite that starts with warnings still has its failure list in the middle.
      SUITE_ANALYSIS_BYTES = 1_000_000
      SUITE_ANALYSIS_HEAD_SHARE = 0.5

      def self.run(root, suite, timeout: 1800, env: {}, tail_bytes: SUITE_EXCERPT_BYTES, machine: nil,
        stack: Stacks::Rails, analysis_bytes: SUITE_ANALYSIS_BYTES, stream: nil)
        # First, so the rescue below can always measure: a run that fails to start is
        # still a run that has a duration, and the record keeps it.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        command = suite.respond_to?(:command) ? suite.command.to_s : suite.to_s
        kind = suite.respond_to?(:kind) ? suite.kind : nil
        environment = stack.suite_env(kind).merge(env)
        argv, process_env = spawn_argv(command, root: root, env: environment, machine: machine)
        analysis = Shell::Excerpt.new(bytes: analysis_bytes, head_share: SUITE_ANALYSIS_HEAD_SHARE)

        # **The child is `Shell`'s**, the same one a pipeline command goes through: one place decides how a
        # process group is killed and how much of an output is kept, and `Shell`'s docstring says why — two
        # places building a recorded command is the drift that module exists to prevent. What stays here is
        # what is *suite*-specific: the command string, what the exit code means, and the excerpt's size.
        # **The stream is the whole suite, not the 1MB analysis.** The analysis is for the
        # failure parser; the stream is for the person reading a run whose failure the parser
        # could not name. The file is closed here, after the spawn has drained its pipe.
        file = Shell.open_stream(stream)
        begin
          status, text, timed_out = Shell.spawn_with_deadline(
            argv, chdir: root, env: process_env, timeout: timeout,
            excerpt: Shell::Excerpt.new(bytes: tail_bytes, head_share: SUITE_EXCERPT_HEAD_SHARE),
            analysis: analysis, stream: file
          )
        ensure
          if file
            file.flush
            file.close
          end
        end
        if timed_out
          Result.new(
            command: command, ran: false, passed: false, exit_code: nil,
            seconds: elapsed(started), output_tail: text, output: analysis.to_s, timed_out: true
          )
        else
          finished(command: command, status: status, text: text, seconds: elapsed(started),
            output: analysis.to_s)
        end
      rescue Errno::ENOENT => e
        # The command does not exist on this machine at all — no `bundle`, no
        # `bin/rails`. Nothing was established about the application, which is not the
        # same as the suite failing.
        #
        # Reported as `NOT_FOUND` rather than as a missing exit code, because a
        # one-word command is exec'd while one with spaces goes through `sh` — so the
        # same absence arrives here or as the 127 `sh` reports, and a reader has no
        # use for telling those apart. Both say "this command, or the `bundle` it
        # needs, is not installed here", and neither says anything about the code.
        Result.new(
          command: command.to_s, ran: false, passed: false, exit_code: NOT_FOUND,
          seconds: elapsed(started), output_tail: "#{e.class}: #{e.message}",
          output: "#{e.class}: #{e.message}", timed_out: false
        )
      end

      # One line for the durable record. Every branch says what it means for the step
      # as well as what happened, because this is the sentence a reader has to be able
      # to act on — and the two "nothing was established" branches are the ones that
      # must not read as a failure.
      def self.summary(result)
        seconds = format("%.1f", result.seconds.to_f)
        if result.timed_out
          "`#{result.command}` timed out after #{seconds}s and was killed with its process " \
            "group, so this step is unverified rather than failed"
        elsif !result.ran
          "`#{result.command}` did not run (#{not_run_reason(result)}), so this step is " \
            "unverified rather than failed"
        elsif result.passed
          "`#{result.command}` passed in #{seconds}s"
        else
          "`#{result.command}` failed in #{seconds}s (exit #{result.exit_code})"
        end
      end

      def self.not_run_reason(result)
        if result.exit_code == NOT_FOUND
          "exit #{NOT_FOUND}: the command, or the `bundle` it needs, is not installed here"
        else
          "it was killed by a signal before it finished"
        end
      end

      # [argv, process_env] for `Process.spawn`, through the machine when there is one.
      # Its own method because it is the one place the *shape* of a spawn is decided: every
      # other line in `run` would read the same for a suite on this host and a suite in a
      # container, and that is the difference this parameter exists to hold.
      def self.spawn_argv(command, root:, env:, machine:)
        return [[command], env] if machine.nil?

        machine.script(command, chdir: root, env: env)
      end

      # Reads the child's output on a thread of its own and keeps only the last
      # `tail_bytes` of it. Both halves are load-bearing: a pipe holds 64 KB, so a
      # suite that prints more than that blocks for ever waiting for a reader that only
      # arrives after it exits; and the tail is bounded because this text is recorded.
      # Termination first, so a suite that can shut down cleanly does; the whole group
      # after a grace, because a suite that traps the signal would otherwise hold the
      # cycle for ever. `Errno::ESRCH` means it was already gone, which is the answer
      # this wants.
      # The text arrives already bounded — the excerpt's own `to_s` is the bound, and its two ends were kept
      # while the output streamed — so this only decides what the exit code *means*.
      def self.finished(command:, status:, text:, seconds:, output: nil)
        code = status.exitstatus
        # A signalled process has no exit status, and a suite that was killed
        # established nothing about the application — the same third answer a timeout
        # is, reached by a different route.
        ran = !code.nil? && code != NOT_FOUND
        Result.new(
          command: command, ran: ran, passed: ran && code.zero?, exit_code: code,
          seconds: seconds, output_tail: text, output: output || text, timed_out: false
        )
      end

      # A suite can print bytes that are not UTF-8, and this text is written into a
      # JSON record afterwards: scrubbing here is what keeps a stray byte in a
      # test's output from being the reason a step cannot be recorded.
      # The excerpt's own `to_s` is the bound: the two ends were kept while the output
      # streamed and the middle was counted as it went.
      def self.elapsed(started)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      end
    end
  end
end
