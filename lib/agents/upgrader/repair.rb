# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"

require_relative "model_limits"
require_relative "sealed"

module Agents
  module Upgrader
    # The one place a model changes somebody's application, and the reason it is bounded.
    #
    # A step has a shape that makes repair a *measurable* act rather than a hope: the suite
    # was green before the move and red after it, so the failure is attributable, the brief
    # is concrete, and the verdict afterwards is the suite's own. That is the whole reason
    # this loop can exist at all — repairing a rung that was red before the move would be
    # unmeasurable, and this class refuses that case in its caller (`Step#repair`).
    #
    # Four rules carry it, and each is a way an autonomous repair goes wrong:
    #
    # * **The model edits files; the harness runs the suite.** The application executes on an
    #   era interpreter inside a container (Ruby 2.1 for a Rails 4.0.0.rc1 application), so a
    #   shell in the agent's hand is a shell that cannot run the thing it is reasoning about —
    #   and every attempt to try burns the budget. The agent gets read and edit; the suite is
    #   run between attempts by the caller.
    # * **Off unless a number says otherwise.** `UPGRADER_REPAIR_ATTEMPTS` is the switch, and
    #   zero is the library's default: a step run by hand must not spend model calls because
    #   a file was left in a directory. The deployment sets the number, which is the same
    #   posture as publishing.
    # * **Every attempt is evidence.** The command, the exit code, the seconds, the agent's
    #   own closing words, and the files it touched — a repair nobody can audit is a change
    #   nobody can review, and the record is the pull request's other half.
    # * **A timeout is a kill, not a wait.** One attempt is a model call with a tool loop in
    #   it; an agent that hangs must not hold a walk for ever, which is the same rule the
    #   miner's installs and suites are held to.
    class Repair
      # The switch, the budget, and the agent. Named here and read by no other file.
      ENV_ATTEMPTS = "UPGRADER_REPAIR_ATTEMPTS"
      ENV_TIMEOUT = "UPGRADER_REPAIR_TIMEOUT"
      ENV_MODEL = "UPGRADER_REPAIR_MODEL"
      ENV_AGENT = "UPGRADER_REPAIR_AGENT"
      ENV_BINARY = "UPGRADER_REPAIR_BINARY"
      # **Where the agent's own event stream is kept.** The record is a summary; a model that
      # read the wrong file, looped on a tool, or died with the provider's reset in a JSON error
      # cannot be understood from a 60-line tail. The stream is opencode's native JSON events,
      # written whole beside the config, and the session id names the same run in
      # `opencode export`. `UPGRADER_REPAIR_STREAMS` moves it for a deployment that collects
      # artifacts elsewhere.
      ENV_STREAMS = "UPGRADER_REPAIR_STREAMS"

      # Off, and ten minutes per attempt when it is not: one attempt is a model call with a
      # tool loop around it, and a rung's suite is measured in minutes rather than seconds.
      DEFAULT_ATTEMPTS = 0
      DEFAULT_TIMEOUT = 600

      # The agent this loop runs, declared in the config it writes. Named rather than left to
      # the default because `opencode run` falls back to its `build` agent — which has a
      # shell — when the name is unknown, and a shell is what this loop removes.
      AGENT = "repair"

      # The name of the config document, and **the reason it is not written into the
      # worktree**: measured on the first live repair, where opencode answered `Agent not
      # found: "repair"` in 1.3 seconds. A step's working copy is a `git worktree` of
      # somebody's repository, so the project root opencode resolves is the repository the
      # worktree points at — and the `opencode.json` this class wrote beside the application
      # was never read. `OPENCODE_CONFIG` names the file outright instead
      # (`opencode debug config` reads it from there, verified), and the file lives in this
      # client's own home: no file in the application's tree, and none to clean up.
      CONFIG = "opencode.json"

      # One attempt, as the record shows it. **`ran` and `timed_out` are separate facts, and
      # the loop turns on the first**: an agent that could not be started never touched the
      # tree, so asking again asks the same nothing, while one killed at the deadline spent the
      # whole budget and may have left a patch behind — the first live attempt here ran fifteen
      # minutes and was recorded as "did not run", which stopped the loop before the suite ever
      # looked at what it had changed. An attempt that timed out is measured like any other.
      Attempt = Struct.new(:number, :command, :ran, :timed_out, :exit_code, :seconds, :output_tail,
        :changed, :limited, :limit_until, :stream_path, :stream_log, :session,
        :event_count, :tool_count, :error_count, :tokens, :cost, keyword_init: true) do
        def ok? = ran && !timed_out && !exit_code.nil? && exit_code.zero?
        def limited? = limited == true

        # The line the record and the operator both read. It names the stream and the opencode
        # session, because those are the two facts that turn "the model failed" into something
        # a person can open and finish reading.
        def stream_sentence
          return "" if stream_path.to_s.empty?

          parts = []
          parts << "session #{session}" unless session.to_s.empty?
          parts << "#{event_count} event(s)"
          parts << "#{tool_count} tool call(s)" if tool_count.to_i.positive?
          parts << "#{error_count} error(s)" if error_count.to_i.positive?
          parts << "#{tokens} token(s)" if tokens.to_i.positive?
          parts << format("$%.6f", cost) if cost.to_f.positive?
          "stream #{stream_path}#{parts.empty? ? "" : " (#{parts.join(", ")})"}"
        end
      end

      # **What a repair did, kept while it is still knowable.** The record is written from the final
      # state, where the suite is green: what the failure *said*, and which files the repair changed
      # to answer it, exist only while the loop runs. It travels in the record and becomes a report
      # (`Filing.repair_report_for`), because a repair that lives only in a log is the failure
      # the design notes name.
      # `gate` names what was red and then green — the suite for a run's repair, `the boot` for a
      # load the application's own code could not satisfy. It is a word rather than a boolean
      # because the report's sentences need to read correctly for both, and a report that called a
      # failed `bin/rails runner` "the suite" is a lie a reader would have to notice for themselves.
      Outcome = Struct.new(:failure, :suite, :attempts, :files, :diff, :before_the_move, :gate,
        keyword_init: true) do
        def to_h
          { "failure" => failure, "suite" => suite, "attempts" => attempts, "files" => files,
            "diff" => diff, "before_the_move" => before_the_move, "gate" => gate }
        end
      end

      # **A mechanical repair is a repair, and the record says so.** The suite-repair path derives
      # its edits from the application's own route table and writes them through the same applier,
      # so there is no model's attempt to describe; what it has is the evidence that makes a repair
      # worth anything — the failure the suite printed before it and the suite that was green after
      # it. It travels in the same `Outcome` and becomes a corpus report by the same door
      # (`Filing.file_repairs`). Without this the walk's *most* trustworthy repairs, the ones no
      # model made, were the only ones the corpus never saw.
      def self.mechanical_outcome(applied:, failure:, suite:, before_the_move: false, gate: nil)
        edits = Array(applied)
        return nil if edits.empty?

        Outcome.new(failure: failure, suite: suite, attempts: 1,
          files: edits.map(&:path).uniq, diff: diff_for(edits),
          before_the_move: before_the_move, gate: gate)
      end

      # The edits as a diff a reader can check. **Recomputed from the applied edits rather than read
      # out of git**, because the caller checkpoints the repair before the suite is run again — a
      # `git diff` after that is empty, and the repair's own change is the one thing a reviewer has
      # to see. It is a rendering, not a patch a tool applies: each edit is one line replaced by
      # what was written.
      # **A successful repair becomes a proposal as whole files, not as a diff.** ADR 0012's
      # write-back needs effects a service can store and a later rung can apply, and the one shape
      # that is exact for both a mechanical repair and a model's is the file the repair left: a
      # `file` effect carries its content, and a path that no longer exists is a `delete`. A diff
      # would have to be parsed into `find`/`replace` pairs, and a hunk's context lines mean the
      # find a parser derives may match somewhere the repair never touched — an effect that applies
      # to the wrong line is worse than no proposal. The cost is stated in the ADR: whole-file
      # content is project-only and cannot be promoted, which is why a repair is a proposal here
      # and a rule only when its shape is one somebody writes down.
      #
      # The bound is the request body's: a proposal is one request. A repair that touched more
      # files than a body can carry is not proposed and says so, rather than being sent in part.
      # 48 KiB rather than the old 96: the decision route's body is 64 KiB, so a larger proposal
      # was refused by the service after the model had spent the call.
      MAX_PROPOSAL_FILES = 20
      MAX_PROPOSAL_BYTES = 48 * 1024

      def self.effects_for(files:, root:)
        paths = Array(files).map(&:to_s).reject(&:empty?).uniq
        return [[], "the repair names no file"] if paths.empty?
        if paths.size > MAX_PROPOSAL_FILES
          return [[], "the repair touched #{paths.size} files, more than #{MAX_PROPOSAL_FILES}"]
        end

        base = File.expand_path(root.to_s)
        base_real = Sealed.resolved(base)
        effects = []
        total = 0
        paths.each do |path|
          # **Sealed, not `expand_path`.** A repair can name a symlink, and the old check followed
          # it: a file the model "edited" could have been a link out of the worktree. The rule the
          # applier uses is the rule the proposal uses.
          full, unsafe = Sealed.path(base, path, root_real: base_real)
          return [[], unsafe] if full.nil?

          if File.directory?(full)
            return [[], "#{path} is a directory"]
          elsif File.file?(full)
            content = begin
              File.read(full, encoding: "utf-8")
            rescue StandardError => e
              return [[], "#{path} could not be read: #{e.message}"]
            end
            total += content.bytesize
            if total > MAX_PROPOSAL_BYTES
              return [[], "the repair's files exceed #{MAX_PROPOSAL_BYTES} bytes"]
            end

            effects << { "kind" => "file",
                         "payload" => { "path" => path, "content" => content },
                         "applies_when" => {}, "phase" => "post" }
          else
            # Absent is a deletion the repair made, which is a fact about the tree rather than a
            # read that failed.
            effects << { "kind" => "delete", "payload" => { "path" => path },
                         "applies_when" => {}, "phase" => "post" }
          end
        end
        [effects, nil]
      end

      def self.diff_for(edits)
        Array(edits).group_by(&:path).map do |path, group|
          ["--- a/#{path}", "+++ b/#{path}", *group.map { |edit| hunk_for(edit) }].join("\n")
        end.join("\n")
      end

      def self.hunk_for(edit)
        line = edit.line.to_i
        removed = edit.text.to_s.split("\n", -1).map { |text| "-#{text}" }
        added = edit.after.to_s.split("\n", -1).map { |text| "+#{text}" }
        ["@@ -#{line} +#{line} @@", *removed, *added].join("\n")
      end

      Result = Struct.new(:attempts, :repaired, keyword_init: true) do
        def to_s
          return "no attempt was made" if attempts.empty?

          "#{attempts.size} attempt(s), #{repaired ? "repaired" : "not repaired"}"
        end
      end

      # The budget, or nil when this process does not repair at all. Read once per step; the
      # default is off for the reason the class documents.
      #
      # **`UPGRADER_REPAIR_MODEL` names one model or a chain of them, and the chain is what a
      # free tier needs.** Measured here: the free variant of a model ran one attempt to the
      # 600-second deadline (it was working — reading the patch, the views, the controller and
      # the specs — and simply did not finish) and the next attempt answered
      # `Rate limit exceeded. Please try again later.` in two seconds, which spent the budget
      # against a provider rather than against the application. A comma- or space-separated list
      # is read left to right, one model per attempt, so `free,paid` is "try the free one, then
      # the one that answers" — and each attempt's command in the record carries the model it
      # actually ran with.
      def self.budget(env = ENV)
        attempts = env[ENV_ATTEMPTS].to_s.to_i
        return nil if attempts <= 0

        { attempts: attempts,
          timeout: (env[ENV_TIMEOUT].to_s.empty? ? DEFAULT_TIMEOUT : env[ENV_TIMEOUT].to_i),
          models: env[ENV_MODEL].to_s.split(/[,\s]+/).reject(&:empty?),
          agent: env[ENV_AGENT].to_s.empty? ? AGENT : env[ENV_AGENT],
          binary: env[ENV_BINARY].to_s.empty? ? "opencode" : env[ENV_BINARY] }
      end

      # The project config one attempt runs under: the agent, and nothing it may do beyond
      # reading and editing this tree. `tools` is deny-first, because a capability opencode
      # adds tomorrow must not arrive enabled.
      def self.document(model:, agent: AGENT)
        {
          "$schema" => "https://opencode.ai/config.json",
          "autoupdate" => false,
          "snapshot" => false,
          "model" => model.to_s.empty? ? nil : model,
          "agent" => {
            agent => {
              "mode" => "primary",
              "description" => "Repairs one rung of a Rails upgrade, with this directory's failure as its brief.",
              "tools" => { "*" => false, "read" => true, "edit" => true, "write" => true,
                           "glob" => true, "grep" => true, "list" => true }
            }
          }
        }.compact
      end

      def initialize(root:, evidence:, budget:, env: {}, out: nil, runner: nil, rerun: nil,
                     on_attempt: nil, before_the_move: false, config_dir: nil, home: nil,
                     stream_dir: nil)
        @root = root
        @evidence = evidence
        @attempts = budget.fetch(:attempts)
        @timeout = budget.fetch(:timeout)
        @models = Array(budget.fetch(:models)).map(&:to_s).reject(&:empty?)
        @agent = budget.fetch(:agent)
        @binary = budget.fetch(:binary)
        @env = env
        @out = out
        # The agent's process, injectable so the suite can drive this loop's *shape* — an
        # attempt ran, a suite came back red, another attempt followed — without a model.
        @runner = runner
        # The suite, again, after each attempt. A callable because running a suite is the
        # caller's knowledge (the plan, the bundle, the machine) and this class's subject is
        # the loop.
        @rerun = rerun
        # Where an attempt is recorded, called as it happens rather than at the end: a loop
        # killed mid-flight must leave the evidence it had.
        @on_attempt = on_attempt
        # **Whose failure this is.** A suite that went red *after* the move is the move's; a
        # suite that was already red when the step arrived is the application's — an rc-era
        # config the framework since requires, a spec that reads a file nobody has — and the
        # brief has to say which, because the model's first question is "did I do this?".
        @before_the_move = before_the_move
        @config_dir = config_dir.to_s
        # **The agent's home, and it is the client's own directory rather than the user's.**
        # The deployment runs this container with a read-only root and a home under it,
        # so opencode's first attempt to write `~/.local` answered `EROFS: read-only file
        # system` and every repair failed before the model saw the tree. The writable home
        # is the directory the client already owns — the one the config lives in — and it
        # is also where a credential belongs: a token in an image layer is a token in
        # every container that image starts.
        @home = home.to_s
        # **The stream belongs to the agent's own directory, not the application's tree.** The
        # config already lives under `repair/` in the client's home; the raw event stream sits
        # beside it, so a walk never writes an artifact into somebody's repository.
        @stream_dir = stream_dir.to_s
        @stream_dir = default_stream_dir if @stream_dir.empty?
        # **A limited model is removed before the first attempt.** The provider's reset is a
        # fact about the next step as much as this one, and `ModelLimits` keeps it in the
        # client's home. A chain of `free,paid` therefore starts at `paid` while the free tier
        # is spent, and returns to `free` when the recorded time has passed.
        @limits = ModelLimits.new(home: @home, env: @env)
        @model_index = 0
        @skipped_models = []
        @models = @models.reject do |model|
          deadline = @limits.limited_until(model)
          next false if deadline.nil?

          @skipped_models << [model, deadline]
          @out.puts("  repair: #{model} is limited until #{deadline.utc.iso8601}; " \
                    "using the next model") if @out
          true
        end
      end

      def run
        # **Every model being limited is not an attempt.** The next step's reset is a clock, and
        # spending a model call to re-learn it is the cost this record exists to avoid. The
        # earliest reset is named so an operator can see when the free tier returns.
        if @models.empty? && @skipped_models.any?
          earliest = @skipped_models.min_by { |_model, deadline| deadline }.last
          @out.puts("  repair: every model is limited (earliest reset " \
                    "#{earliest.utc.iso8601}); no attempt") if @out
          return Result.new(attempts: [], repaired: false)
        end

        attempts = []
        failure = @evidence[:output_tail].to_s
        repaired = false
        @attempts.times do |index|
          model = model_for
          break if model.nil?

          attempt = attempt(index + 1, failure, model)
          attempts << attempt
          @on_attempt&.call(attempt)
          @out.puts("  repair: attempt #{attempt.number} — #{describe(attempt)}") if @out
          # **A limited model is evidence about the provider, not about the application.** It
          # changes no file, so the suite is not run against it; the next model gets the same
          # failure the free one was asked about.
          if attempt.limited?
            @models.delete_at(@model_index) if @models[@model_index] == model
            if @models.empty?
              @out.puts("  repair: no model is left; the earliest reset is " \
                        "#{attempt.limit_until.utc.iso8601}") if @out
              break
            end
            next
          end
          advance_model
          # **Only a start that never happened ends the loop.** A timed-out attempt ran; the
          # suite measures its patch like any other attempt's, and the next one is briefed with
          # what the suite said about it.
          break unless attempt.ran

          suite = @rerun&.call
          break if suite.nil?

          if suite.ok?
            repaired = true
            break
          end
          failure = suite.output_tail.to_s
        end
        Result.new(attempts: attempts, repaired: repaired)
      end

      private

      def attempt(number, failure, model)
        prompt = prompt_for(failure)
        before = changed_files
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        exit_code, stdout, stderr, outcome = run_agent(prompt, model)
        # **The whole stream is kept before anything reads a summary of it.** The event file is
        # the model's own account of what it did — the session, every tool call and its output,
        # every provider error and the token count — and the summary below is only the part a
        # record can hold. A failure that is not in the summary is still in the stream.
        stream = write_stream(number, model, stdout, stderr, outcome)
        summary = stream[:summary]
        raw = [stdout, stderr].reject { |part| part.to_s.empty? }.join("\n")
        # **A failed call is read for the provider's own sentence.** A successful call's answer
        # is about the application, even if it happens to mention a rate limit in prose.
        limit = if model.to_s.empty? || (exit_code.to_i.zero? && outcome != :timed_out)
          nil
        else
          @limits.record(model: model, output: raw, timed_out: outcome == :timed_out,
            exit_code: exit_code)
        end
        if limit
          summary = "#{summary}\n[repair] #{model} limited until #{limit.until_time.utc.iso8601}: " \
                    "#{limit.reason}"
          @out.puts("  repair: #{model} is limited until #{limit.until_time.utc.iso8601} " \
                    "(#{limit.reason}); switching to the next model") if @out
        end
        Attempt.new(
          number: number, command: command_label(prompt, model), ran: outcome != :not_started,
          timed_out: outcome == :timed_out, exit_code: exit_code,
          seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          output_tail: tail(summary), changed: changed_files - before,
          limited: !limit.nil?, limit_until: limit&.until_time,
          stream_path: stream[:path], stream_log: stream[:log_path], session: stream[:session],
          event_count: stream[:events], tool_count: stream[:tools], error_count: stream[:errors],
          tokens: stream[:tokens], cost: stream[:cost]
        )
      end

      # **The current model in the chain, and the last one for everything after it.** A chain
      # shorter than the budget repeats its final model rather than running with none: an attempt
      # with no model is opencode's own default, which is the model this environment turned out
      # not to have a key for. `nil` means the chain was spent by limits, not that it was empty.
      def model_for
        return "" if @models.empty? && @skipped_models.empty?
        return nil if @models.empty?

        @models[[@model_index, @models.size - 1].min]
      end

      def advance_model
        @model_index = [@model_index + 1, @models.size - 1].min
      end

      # The document, written once per attempt (the model may be pinned per run, so it is not
      # memoised across instances) and named to the agent through `OPENCODE_CONFIG`.
      def config_path(model)
        dir = @config_dir.empty? ? File.join(Dir.tmpdir, "agents-repair") : @config_dir
        FileUtils.mkdir_p(dir)
        path = File.join(dir, CONFIG)
        File.write(path, "#{JSON.pretty_generate(self.class.document(model: model, agent: @agent))}\n")
        path
      end

      # **The model process gets an allowlist, not the walker's environment.** The walker holds the
      # corpus key and the application's own suite environment; a prompt-injected repository (or a
      # model that reads `/proc/self/environ`) would carry both to the provider and into a proposal.
      # Only the variables `opencode` needs to find its config and its home cross the boundary.
      AGENT_ENV = %w[HOME PATH LANG LC_ALL LC_CTYPE TMPDIR TEMP TMP XDG_CONFIG_HOME
        XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR NODE_OPTIONS SHELL].freeze

      def run_agent(prompt, model)
        # **No `--standalone`, because the flag is gone from the client this runs.** The
        # argument was accepted by an older `opencode run` and is a usage error in the
        # version the image installs, which printed the help and exited before the model
        # ever saw the tree — an attempt that "ran" in the record and changed nothing, for
        # ever. The test that pinned the argv now pins the version that answers.
        #
        # **`--dir`, because the agent's shell is not the project root it reads.** `chdir`
        # starts the process in the worktree, but opencode resolves its project from the
        # server's directory: a live repair read and edited `/app` — this image's own
        # source — while the record said "no file changed" and the tree was untouched.
        # `--dir` is the flag that makes the worktree the project.
        argv = [@binary, "run", "--dir", @root, "--agent", @agent]
        argv += ["--model", model] unless model.empty?
        # **`--format json` is opencode's own event stream, not a rendering of it.** Each line is
        # the session, the tool calls with their inputs and outputs, the model's text, the provider
        # errors and the step's token count; `--print-logs` adds the client's own log lines on
        # stderr. The stream is written whole beside the config and the record keeps a summary, so
        # a failure can be read rather than guessed at.
        argv += ["--format", "json", "--print-logs", "--log-level", "INFO"]
        argv << prompt
        # **`to_h`, because the live caller hands this `ENV`.** `ENV` answers `[]`, `each` and
        # `to_h` but *not* `merge`, and its class is `Object` — so the failure read
        # `undefined method 'merge' for #<Object:0x...>`, which names neither the environment
        # nor the method's real subject. Every test had passed a Hash, which is why the first
        # live repair was where this was found.
        env = @env.to_h.slice(*AGENT_ENV)
        env["OPENCODE_CONFIG"] = config_path(model)
        env["HOME"] = @home unless @home.empty?
        answer = @runner ? @runner.call(argv, chdir: @root, timeout: @timeout, env: env) : collect(argv, env)
        # An injected runner answers `[exit_code, output]` or `[exit_code, output, outcome]`, the
        # way the first tests wrote it, and a real one answers stdout and stderr apart. What the
        # answer means is decided here rather than by every fake: no exit code and no outcome is
        # a start that never happened.
        exit_code, stdout, stderr, outcome =
          case Array(answer).length
          when 0, 1 then [nil, "", "", nil]
          when 2 then [answer[0], answer[1], "", nil]
          when 3 then [answer[0], answer[1], "", answer[2]]
          else [answer[0], answer[1], answer[2], answer[3]]
          end
        [exit_code, stdout.to_s, stderr.to_s,
          outcome || (exit_code.nil? ? :not_started : :ran)]
      end

      # `[exit_code, stdout, stderr, outcome]`, where the outcome is `:ran`, `:timed_out` or
      # `:not_started`. **A killed attempt is not a failed start**: the process existed and its
      # edits are in the tree, so the caller measures them rather than discarding them — and a
      # process killed by something other than this deadline is still one that ran.
      def collect(argv, env)
        stdout = +""
        stderr = +""
        status = nil
        # **The process gets its own group, because the agent is a process tree.** A bare
        # `opencode` call spawns a node child that owns the model connection and the file handles;
        # a TERM to the parent alone left the group alive and the suite's block still reading its
        # pipe, which is how one repair attempt held a walk for more than ten minutes after its
        # deadline. `pgroup: true` makes the child the group leader, and the timeout kills the
        # group rather than hoping the parent forwards it.
        Open3.popen3(env, *argv, chdir: @root, pgroup: true) do |stdin, out, err, wait|
          stdin.close
          readers = [
            Thread.new { out.each_line { |line| stdout << line } },
            Thread.new { err.each_line { |line| stderr << line } }
          ]
          begin
            Timeout.timeout(@timeout) { status = wait.value }
          rescue Timeout::Error
            terminate(wait.pid)
            stderr << "\nthe repair agent was killed after #{@timeout}s"
            join_readers(readers)
            return [nil, stdout, stderr, :timed_out]
          end
          join_readers(readers)
        end
        [status.exitstatus, stdout, stderr, :ran]
      rescue Errno::ENOENT => e
        [nil, "", "the repair agent could not be started: #{e.message}", :not_started]
      end

      # A reader blocked on a pipe whose process was killed is allowed to finish; it is not the
      # attempt's result and a thread that outlives it would hold the walk's memory.
      def join_readers(readers)
        readers.each do |reader|
          reader.join(2)
        rescue StandardError
          nil
        end
      end

      # **A polite signal and then a hard one.** The agent may ignore TERM while it is in a model
      # call; the KILL is what guarantees the deadline is a deadline. Both target the negative pid,
      # which is the process group `pgroup: true` created.
      def terminate(pid)
        begin
          Process.kill("TERM", -pid)
        rescue Errno::ESRCH
          nil
        end
        sleep 0.5
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def command_label(prompt, model)
        "#{@binary} run --dir #{@root} --agent #{@agent}" \
          "#{model.to_s.empty? ? "" : " --model #{model}"} " \
          "(prompt: #{prompt.bytesize} bytes)"
      end

      def describe(attempt)
        sentence = if !attempt.ran
          "did not run (#{attempt.output_tail.lines.first.to_s.strip})"
        elsif attempt.limited?
          "limited until #{attempt.limit_until.utc.iso8601} — " \
            "#{attempt.output_tail.lines.last.to_s.strip}"
        elsif attempt.timed_out
          "timed out after #{attempt.seconds.round(1)}s"
        else
          "exit #{attempt.exit_code} in #{attempt.seconds.round(1)}s" \
            "#{attempt.changed.empty? ? ", no file changed" : ", #{attempt.changed.size} file(s) changed"}"
        end
        stream = attempt.stream_sentence
        stream.empty? ? sentence : "#{sentence} — #{stream}"
      end

      def tail(output)
        text = output.to_s
        lines = text.lines
        lines.length > 60 ? lines.last(60).join : text
      end

      def default_stream_dir
        explicit = @env[ENV_STREAMS].to_s.strip
        return explicit unless explicit.empty?

        base = @home.empty? ? Dir.tmpdir : @home
        File.join(base, "repair", "streams")
      end

      # **The stream is written before the summary is parsed, and a failure to write it is not a
      # failure to repair.** The attempt's result is the suite's; losing the artifact must not turn
      # a measurable attempt into a refused one, so the summary falls back to the raw text and the
      # error travels in the stream's place.
      def write_stream(number, model, stdout, stderr, _outcome)
        FileUtils.mkdir_p(@stream_dir)
        stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
        stem = "#{stamp}-repair-#{number}-#{safe_name(model.to_s.empty? ? "default" : model)}"
        path = File.join(@stream_dir, "#{stem}.jsonl")
        log_path = File.join(@stream_dir, "#{stem}.log")
        File.binwrite(path, stdout.to_s)
        File.binwrite(log_path, stderr.to_s)
        parsed = parse_stream(stdout.to_s)
        log_lines = stderr.to_s.lines.last(10).map { |line| "[log] #{line.strip}" }
        parsed[:summary] = [parsed[:summary], *log_lines].reject(&:empty?).join("\n")
        parsed.merge(path: path, log_path: log_path, bytes: File.size(path),
          log_bytes: File.size(log_path), error: nil)
      rescue SystemCallError => e
        { summary: [stdout.to_s, stderr.to_s].reject(&:empty?).join("\n"), path: nil,
          log_path: nil, session: nil, events: 0, tools: 0, errors: 0, tokens: 0, cost: 0.0,
          error: "the event stream could not be written: #{e.message}" }
      end

      def safe_name(value)
        value.to_s.gsub(/[^A-Za-z0-9_.-]+/, "-")[0, 80]
      end

      # **The native event stream, read for the record rather than rendered as prose.** A text
      # event is the model's sentence, a tool event is what it did and what came back, and a
      # step-finish carries the tokens and cost; the raw line for an event this build does not
      # know is kept as its type, because a new opencode event must be visible rather than
      # silently dropped.
      def parse_stream(text)
        events = 0
        tools = 0
        errors = 0
        tokens = 0
        cost = 0.0
        session = nil
        lines = []
        text.to_s.each_line do |line|
          line = line.strip
          next if line.empty?

          events += 1
          event = begin
            JSON.parse(line)
          rescue JSON::ParserError
            lines << line
            next
          end
          session ||= event["sessionID"]
          part = event["part"].is_a?(Hash) ? event["part"] : {}
          case part["type"].to_s
          when "text"
            body = part["text"].to_s.strip
            lines << body unless body.empty?
          when "tool"
            tools += 1
            lines << tool_line(part)
          when "step-finish"
            total = part.dig("tokens", "total").to_i
            tokens += total
            cost += part["cost"].to_f
            lines << "[step] #{part["reason"]} · #{total} token(s) · " \
              "$#{format("%.6f", part["cost"].to_f)}"
          when "error"
            errors += 1
            lines << "[error] #{event_error(part)}"
          when "step-start"
            lines << "[step] started"
          else
            # **The type is the summary; the raw line is the stream.** A `step_start` event
            # carries a whole part document and would spend the summary on JSON that the file
            # already holds; an unknown event still says it happened so a new opencode event is
            # visible rather than silently dropped.
            label = part["type"] || event["type"]
            lines << "[#{label}]" unless label.to_s.empty?
          end
        end
        { summary: lines.last(60).join("\n"), session: session, events: events, tools: tools,
          errors: errors, tokens: tokens, cost: cost }
      end

      def tool_line(part)
        state = part["state"].is_a?(Hash) ? part["state"] : {}
        input = state["input"].is_a?(Hash) ? state["input"] : {}
        detail = input["filePath"] || input["path"] || input["pattern"] || input["command"] ||
          input["description"]
        output = state["output"].to_s.strip.gsub(/\s+/, " ")
        detail = detail.to_s.strip[0, 200]
        "[tool] #{part["tool"]}#{detail.empty? ? "" : " #{detail}"}" \
          "#{output.empty? ? "" : " -> #{output[0, 300]}"}"
      end

      def event_error(part)
        error = part["error"] || part["message"] || part["text"] || part
        text = error.is_a?(Hash) ? (error["message"] || error["data"] || error.to_json) : error.to_s
        text.to_s.gsub(/\s+/, " ")[0, 500]
      end

      # Everything the worktree has changed since its base commit, as a sorted list. Both
      # halves are needed: an edit to a tracked file is a `diff`, and a file an agent created
      # is `status --porcelain` only.
      def changed_files
        porcelain, status = Open3.capture2e("git", "-C", @root, "status", "--porcelain")
        return [] unless status&.success?

        Open3.capture2e("git", "-C", @root, "add", "--intent-to-add", "--all")
        names, _listing = Open3.capture2e("git", "-C", @root, "diff", "--name-only")
        tracked = names.to_s.split("\n")
        untracked = porcelain.to_s.split("\n").map { |line| line[3..].to_s }
        (tracked + untracked).map(&:strip).reject(&:empty?).uniq.sort
      end

      # **The brief.** Composed from the step's own record, because a model told "the suite
      # failed, fix it" writes a guess; a model told what the move changed, what the move
      # refused, what needs a decision and the suite's own words writes a patch about this
      # failure. The rules at the end are the ones an agent left alone gets wrong: editing
      # the test, hand-editing the lockfile, and trying to run the suite it cannot run.
      def prompt_for(failure)
        e = @evidence
        applied = Array(e[:applied]).first(30)
        refused = Array(e[:refused]).first(20)
        decisions = Array(e[:decisions]).first(30)

        lines = []
        lines << "You are repairing one step of an automated Rails upgrade. You are in a git"
        lines << "worktree of #{e[:repository]} and the move is Rails #{e[:from_version]} -> #{e[:to_version]}."
        if @before_the_move
          lines << "**The application's test suite is RED *before* any of this move's changes.**"
          lines << "Nothing has been moved yet: the failure is the application's own, and the step"
          lines << "cannot measure anything until the suite is green. Fix the application — the"
          lines << "usual causes are a configuration the framework now requires, a spec that reads"
          lines << "something nobody has, and a gem the application declares but does not load."
        else
          lines << "The application's test suite was GREEN before this move and is RED now."
        end
        lines << ""
        lines << "The suite command is: #{e[:suite_command]}"
        lines << "It runs under #{e[:interpreter]}#{e[:image].to_s.empty? ? "" : " (#{e[:image]})"}, which you"
        lines << "cannot run from your shell — the harness runs it after you finish, and tries again"
        lines << "with your patch. Do not try to run it yourself. You can read, search and edit files;"
        lines << "there is no shell, so a command like `ls` or `find` is not available either."
        lines << ""
        unless applied.empty?
          lines << "What the move has changed so far (from its own record):"
          applied.each do |edit|
            lines << "- #{edit.path}:#{edit.line}: `#{edit.text.to_s.strip}` -> `#{edit.after.to_s.strip}`"
          end
          lines << ""
        end
        unless refused.empty?
          lines << "Edits the move refused, because the line it read had moved (nothing was written):"
          refused.each { |edit| lines << "- #{edit.path}:#{edit.line}: #{edit.reason}" }
          lines << ""
        end
        unless decisions.empty?
          lines << "Changes the move would not make on its own, at the lines this application has:"
          lines << "they are candidates, and one of them may be the failure."
          decisions.each do |decision|
            where = decision.path.to_s.empty? ? "" : "#{decision.path}:#{decision.line} — "
            lines << "- #{where}#{decision.subject} (#{decision.kind}): #{decision.reason}"
          end
          lines << ""
        end
        # **What the corpus already knows, joined change by change.** The brief is not a list of
        # search hits: the plan said which report is which documented change, which rules are in
        # force and which reports joined nothing, so the model can start from an executed answer
        # rather than re-deriving the same fix. Only the non-empty sections travel, and only the
        # first few items of each, because the prompt is a brief and not a corpus dump.
        brief = e[:brief]
        sections = brief.respond_to?(:sections) ? brief.sections.reject(&:empty?) : []
        unless sections.empty?
          lines << "What this corpus already knew about this rung (the review brief):"
          sections.first(4).each do |section|
            lines << "- #{section.title}: #{section.question}"
            section.items.first(3).each do |item|
              detail = +"  - #{item.title}"
              detail << " (#{item.change_key})" unless item.change_key.to_s.empty?
              detail << " — #{item.status}" unless item.status.to_s.empty?
              detail << " · #{item.authority} rule" unless item.authority.to_s.empty?
              detail << " · fix: #{item.fix}" unless item.fix.to_s.empty?
              lines << detail
            end
            lines << "  - …and #{section.total - section.items.first(3).length} more" if
              section.total.to_i > 3
          end
          lines << ""
        end
        # **The most specific thing in the brief.** These are changes this tool *has a rule for* and
        # would not touch — a value whose end the rule cannot see, a line that is not only the call —
        # so the model is being told where a mechanical attempt already stopped, which is a better
        # starting point than any list of possibilities.
        unapplied = Array(e[:unapplied_rules]).uniq
        unless unapplied.empty?
          lines << "This tool has a rule for these changes and would not touch the line — the shape is"
          lines << "known and the value is not, which is the closest thing to a starting point here:"
          unapplied.each { |subject| lines << "- #{subject}" }
          lines << ""
        end
        # And the changes this rung carried that this application does not use at all, as a count:
        # they are not work, and a brief that listed them would send the model looking for call
        # sites that do not exist.
        carried = e[:carried].to_i
        if carried.positive?
          lines << "#{carried} further change(s) this rung carried are not in this application at all,"
          lines << "so there is nothing to find for them."
          lines << ""
        end
        lines << "The failure (the tail of the suite's own output):"
        lines << "```"
        lines << failure.to_s.lines.last(80).join
        lines << "```"
        lines << ""
        lines << "Rules, and they are not negotiable:"
        if @before_the_move
          lines << "- Make the suite green without changing what it asserts. Do not edit the tests"
          lines << "  to make them pass: a change that weakens a test is not a repair, and the record"
          lines << "  travels to a reviewer who reads the diff."
        else
          lines << "- Fix the application for Rails #{e[:to_version]}. Do not edit the tests to make them"
          lines << "  pass: a change that weakens a test is not a repair, and the record travels to a"
          lines << "  reviewer who reads the diff."
        end
        lines << "- Do not hand-edit Gemfile.lock."
        lines << "- Keep the change small. This is one rung of a ladder, reviewed on its own."
        lines << "- Stop when you are done."
        lines.join("\n")
      end
    end
  end
end
