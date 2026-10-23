# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"

module AgentsFyi
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
        :changed, keyword_init: true) do
        def ok? = ran && !timed_out && !exit_code.nil? && exit_code.zero?
      end

      # **What a repair did, kept while it is still knowable.** The record is written from the final
      # state, where the suite is green: what the failure *said*, and which files the repair changed
      # to answer it, exist only while the loop runs. It travels in the record and becomes a report
      # (`Filing.repair_report_for`), because a repair that lives only in a log is the failure
      # the design notes name.
      Outcome = Struct.new(:failure, :suite, :attempts, :files, :diff, :before_the_move,
        keyword_init: true) do
        def to_h
          { "failure" => failure, "suite" => suite, "attempts" => attempts, "files" => files,
            "diff" => diff, "before_the_move" => before_the_move }
        end
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
                     on_attempt: nil, before_the_move: false, config_dir: nil, home: nil)
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
      end

      def run
        attempts = []
        failure = @evidence[:output_tail].to_s
        repaired = false
        @attempts.times do |index|
          attempt = attempt(index + 1, failure)
          attempts << attempt
          @on_attempt&.call(attempt)
          @out.puts("  repair: attempt #{attempt.number} — #{describe(attempt)}") if @out
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

      def attempt(number, failure)
        prompt = prompt_for(failure)
        model = model_for(number)
        before = changed_files
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        exit_code, output, outcome = run_agent(prompt, model)
        Attempt.new(
          number: number, command: command_label(prompt, model), ran: outcome != :not_started,
          timed_out: outcome == :timed_out, exit_code: exit_code,
          seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          output_tail: tail(output), changed: changed_files - before
        )
      end

      # **The Nth model for the Nth attempt, and the last one for everything after it.** A chain
      # shorter than the budget repeats its final model rather than running with none: an attempt
      # with no model is opencode's own default, which is the model this environment turned out
      # not to have a key for.
      def model_for(number)
        return "" if @models.empty?

        @models[[number - 1, @models.size - 1].min]
      end

      # The document, written once per attempt (the model may be pinned per run, so it is not
      # memoised across instances) and named to the agent through `OPENCODE_CONFIG`.
      def config_path(model)
        dir = @config_dir.empty? ? File.join(Dir.tmpdir, "agents-fyi-repair") : @config_dir
        FileUtils.mkdir_p(dir)
        path = File.join(dir, CONFIG)
        File.write(path, "#{JSON.pretty_generate(self.class.document(model: model, agent: @agent))}\n")
        path
      end

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
        argv << prompt
        # **`to_h`, because the live caller hands this `ENV`.** `ENV` answers `[]`, `each` and
        # `to_h` but *not* `merge`, and its class is `Object` — so the failure read
        # `undefined method 'merge' for #<Object:0x...>`, which names neither the environment
        # nor the method's real subject. Every test had passed a Hash, which is why the first
        # live repair was where this was found.
        env = @env.to_h.merge("OPENCODE_CONFIG" => config_path(model))
        env["HOME"] = @home unless @home.empty?
        answer = @runner ? @runner.call(argv, chdir: @root, timeout: @timeout, env: env) : collect(argv, env)
        exit_code, output, outcome = answer
        # An injected runner answers `[exit_code, output]`, the way the first tests wrote it;
        # what that means is decided here rather than by every fake: no exit code and no
        # outcome is a start that never happened.
        [exit_code, output, outcome || (exit_code.nil? ? :not_started : :ran)]
      end

      # `[exit_code, output, outcome]`, where the outcome is `:ran`, `:timed_out` or
      # `:not_started`. **A killed attempt is not a failed start**: the process existed and its
      # edits are in the tree, so the caller measures them rather than discarding them — and a
      # process killed by something other than this deadline is still one that ran.
      def collect(argv, env)
        output = +""
        status = nil
        Open3.popen2e(env, *argv, chdir: @root) do |stdin, stream, wait|
          stdin.close
          begin
            Timeout.timeout(@timeout) { stream.each_line { |line| output << line } }
          rescue Timeout::Error
            begin
              Process.kill("TERM", wait.pid)
            rescue Errno::ESRCH
              nil
            end
            return [nil, output + "\nthe repair agent was killed after #{@timeout}s", :timed_out]
          end
          status = wait.value
        end
        [status.exitstatus, output, :ran]
      rescue Errno::ENOENT => e
        [nil, "the repair agent could not be started: #{e.message}", :not_started]
      end

      def command_label(prompt, model)
        "#{@binary} run --dir #{@root} --agent #{@agent}" \
          "#{model.to_s.empty? ? "" : " --model #{model}"} " \
          "(prompt: #{prompt.bytesize} bytes)"
      end

      def describe(attempt)
        return "did not run (#{attempt.output_tail.lines.first.to_s.strip})" unless attempt.ran
        return "timed out after #{attempt.seconds.round(1)}s" if attempt.timed_out

        "exit #{attempt.exit_code} in #{attempt.seconds.round(1)}s" \
          "#{attempt.changed.empty? ? ", no file changed" : ", #{attempt.changed.size} file(s) changed"}"
      end

      def tail(output)
        text = output.to_s
        lines = text.lines
        lines.length > 60 ? lines.last(60).join : text
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
