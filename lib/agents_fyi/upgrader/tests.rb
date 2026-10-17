# frozen_string_literal: true

module AgentsFyi
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
      Result = Struct.new(
        :command, :ran, :passed, :exit_code, :seconds, :output_tail, :timed_out,
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
      KILL_GRACE_SECONDS = 3

      # Read top to bottom, and **the order is the decision**:
      #
      # 1. `bin/rails test` — a Rails 5+ application has a Rakefile as well, and
      #    `bin/rails` is the entry point Rails documents; the `rake test` task prints a
      #    deprecation on Rails 7 and is gone on 8, so a table that checked the Rakefile
      #    first would break the newer application to serve the older one.
      # 2. `bundle exec rspec` — reached only when the first entry did not match, which
      #    is what makes an application that has both `test/` and `spec/` deterministic:
      #    its framework suite is the one that runs.
      # 3. `bundle exec rake test` — for Rails 4 and older, which have no `bin/rails`.
      # **The order is the rule, and it is a decision about applications that carry two
      # suites.** The first real walk's repository has all three shapes at once — a
      # `spec/spec_helper.rb`, a `test/test_helper.rb` from Rails' generators, and a `Rakefile`
      # — and the suite that matters is the spec one (its `Guardfile` watches `spec/`, its
      # `.rspec` asks for colour). A helper file is a deliberate statement that a suite exists;
      # a `test/` directory of generated files is not, so rspec is asked first and the
      # *alternatives* are named in `reason` and travel into the record's baseline stage
      # (`Step#suite_note`). Rails 5+ (`bin/rails test`) is the second shape and rake is the
      # third, which is the order of the Rails versions that run them.
      CANDIDATES = [
        {
          kind: :rspec,
          command: "bundle exec rspec",
          matches: ->(root) do
            File.file?(File.join(root, "spec/spec_helper.rb")) ||
              File.file?(File.join(root, "spec/rails_helper.rb"))
          end,
          reason: "a spec directory with a helper file: this application's suite is rspec"
        },
        {
          kind: :rails,
          command: "bin/rails test",
          matches: ->(root) do
            File.file?(File.join(root, "bin/rails")) &&
              File.file?(File.join(root, "test/test_helper.rb"))
          end,
          reason: "`bin/rails` and `test/test_helper.rb`: a Rails 5 or newer application " \
                  "runs its suite through bin/rails, and `rake test` is the deprecated entry"
        },
        {
          kind: :rake,
          command: "bundle exec rake test",
          matches: ->(root) do
            File.file?(File.join(root, "Rakefile")) && File.directory?(File.join(root, "test"))
          end,
          reason: "a Rakefile and a test directory, with no bin/rails: Rails 4 and older " \
                  "run minitest through the rake task"
        }
      ].freeze

      # The suite to run, or nil when there is none this tool knows how to run. A nil
      # is a *refusal to guess* rather than an absence: a `test/` directory with no
      # Rakefile and no `bin/rails` has a suite, and how to run it is not stated in
      # anything this tool reads — so it is not run, and `no_suite_reason` says what
      # was looked for.
      def self.detect(root)
        base = File.expand_path(root)
        found = CANDIDATES.select { |candidate| candidate[:matches].call(base) }
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
      def self.no_suite_reason(root)
        "no suite this tool knows how to run under #{File.expand_path(root)}: it looked for " \
          "`bin/rails` beside `test/test_helper.rb`, a `spec/spec_helper.rb` or " \
          "`spec/rails_helper.rb`, and a `Rakefile` with a `test` directory. A step whose " \
          "suite cannot be run is `unverified`, never `passed`."
      end

      # The environment a Rails suite has to run under. Named here rather than left to
      # the caller because a suite that runs without it boots in *development*, against
      # the development database, inside a working copy somebody is upgrading — and
      # `RACK_ENV` is included because a Rack application reads that one and not
      # `RAILS_ENV`.
      def self.machine_test_env
        { "RAILS_ENV" => "test", "RACK_ENV" => "test" }
      end

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
      def self.run(root, suite, timeout: 1800, env: {}, tail_bytes: 4000, machine: nil)
        # First, so the rescue below can always measure: a run that fails to start is
        # still a run that has a duration, and the record keeps it.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        command = suite.respond_to?(:command) ? suite.command.to_s : suite.to_s
        environment = (rails_suite?(suite) ? machine_test_env : {}).merge(env)
        argv, process_env = spawn_argv(command, root: root, env: environment, machine: machine)

        reader, writer = IO.pipe
        pid = Process.spawn(
          process_env, *argv,
          chdir: root, pgroup: true, in: File::NULL, out: writer, err: writer
        )
        writer.close

        # Its own process group, so the kill below reaches the workers a Rails suite
        # forks and not only the shell that started it.
        tail = +""
        reader_thread = Thread.new { drain(reader, tail, tail_bytes) }
        waiter = Thread.new { Process.waitpid2(pid) }

        if waiter.join(timeout)
          status = waiter.value.last
          reader_thread.join(2)
          close(reader)
          finished(command: command, status: status, tail: tail, tail_bytes: tail_bytes,
            seconds: elapsed(started), timed_out: false)
        else
          kill_group(pid)
          waiter.join(KILL_GRACE_SECONDS + 2)
          reader_thread.join(1)
          close(reader)
          Result.new(
            command: command, ran: false, passed: false, exit_code: nil,
            seconds: elapsed(started), output_tail: bounded(tail, tail_bytes),
            timed_out: true
          )
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
          seconds: elapsed(started), output_tail: "#{e.class}: #{e.message}", timed_out: false
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

      def self.rails_suite?(suite)
        %i[rails rake].include?(suite.respond_to?(:kind) ? suite.kind : nil)
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
      def self.drain(reader, tail, tail_bytes)
        while (chunk = reader.read(65_536))
          tail << chunk
          tail.replace(tail.byteslice(-tail_bytes, tail_bytes)) if tail.bytesize > tail_bytes
        end
      rescue IOError, Errno::EBADF
        # The pipe was closed under this thread, which is what happens when a run is
        # killed and nothing is left holding the write end.
      end

      # Termination first, so a suite that can shut down cleanly does; the whole group
      # after a grace, because a suite that traps the signal would otherwise hold the
      # cycle for ever. `Errno::ESRCH` means it was already gone, which is the answer
      # this wants.
      def self.kill_group(pid)
        signal_group(pid, "TERM")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE_SECONDS
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
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

      def self.finished(command:, status:, tail:, tail_bytes:, seconds:, timed_out:)
        code = status.exitstatus
        # A signalled process has no exit status, and a suite that was killed
        # established nothing about the application — the same third answer a timeout
        # is, reached by a different route.
        ran = !code.nil? && code != NOT_FOUND
        Result.new(
          command: command, ran: ran, passed: ran && code.zero?, exit_code: code,
          seconds: seconds, output_tail: bounded(tail, tail_bytes), timed_out: timed_out
        )
      end

      # A suite can print bytes that are not UTF-8, and this text is written into a
      # JSON record afterwards: scrubbing here is what keeps a stray byte in a
      # test's output from being the reason a step cannot be recorded.
      def self.bounded(tail, tail_bytes)
        text = tail.bytesize > tail_bytes ? tail.byteslice(-tail_bytes, tail_bytes) : tail
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
      end

      def self.close(io)
        io.close unless io.closed?
      rescue IOError
        nil
      end

      def self.elapsed(started)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      end
    end
  end
end
