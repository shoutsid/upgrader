# frozen_string_literal: true

require "fileutils"
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

    # One step of a move, executed on a working copy this tool owns.
    #
    # The pipeline is, in its order, and the two stages that make the rest mean anything are
    # the first two: a **worktree** the caller's files are not in, and a **baseline** run of
    # the unmodified copy. Without the baseline, "the upgrade broke the suite" and "the suite
    # was already red" are one sentence, and the second files a report blaming a release for a
    # pre-existing breakage.
    #
    # Everything external is injectable — the runner, the corpus, the applier, the
    # suite detector, the source resolver — because a step that installs a bundle and
    # boots an application is not a thing a unit test can do, and the parts that
    # decide (the verdict, the pin rewrite, which files `app:update` may keep) are
    # exactly the parts that must be tested.
    class Step
      # One step, never a walk: `--to` names where the operator wants to end up, and this
      # executes the *first* rung towards it. — one minor release at a time, never skipped.
      DEFAULT_SUITE_TIMEOUT = 1800

      # What a scan will carry. The service bounds a request body and an application's
      # source is not a payload, so the walk sends the files a plan is about — and says
      # in the record when it stopped, rather than sending a slice and calling it done.
      SCAN_SUFFIXES = %w[.rb .rake .erb .yml .ru].freeze
      SCAN_SKIP = %w[.git vendor node_modules tmp log public/assets storage coverage].freeze
      MAX_SCAN_FILES = 240
      MAX_SCAN_BYTES = 262_144

      # Whether this run goes into the shared corpus: the run record the queue and the
      # coverage figure are built from, and — for a failure — a report filed through
      # precheck. Off by default, and `serve` is what turns it on. The reason is that a
      # person who runs `step` by hand asked what a move costs, not to write into a
      # corpus other operators read; the loop is the thing that owns an account, a cycle
      # and the decision to walk somebody's application at all.
      def initialize(
        repository:, to:, ref: nil, api: nil, home:, out: $stdout,
        work: nil, record: nil, ledger: nil, suite_timeout: DEFAULT_SUITE_TIMEOUT,
        runner: Shell, corpus: nil, source: Source, tests: Tests, applier: Applier,
        contribute: false, reuse: false
      )
        @repository = repository
        @to = to
        @ref = ref
        @api = api
        @home = home
        @out = out
        @work = work
        @record_dir = record
        @ledger = ledger
        @suite_timeout = suite_timeout
        @runner = runner
        @corpus = corpus
        @source = source
        @tests = tests
        @applier = applier
        @contribute = contribute
        # Whether this step owns its working copy or shares the loop's. A hand-run step
        # takes a fresh copy per run — two runs of the same move measured in the same
        # directory are two runs whose second one starts from the first one's edits — and
        # a *walk* keeps one tree per repository, because the second rung of a move starts
        # where the first one arrived (`Source.kept`).
        @reuse = reuse
      end

      def run
        stages = []
        @out.puts("step: #{@repository} -> #{@to}") if @out

        prepared = prepare(stages)
        record = prepared if prepared.is_a?(Record)
        return finish(record) if record

        @worktree, @lockfile, pinned = prepared
        @from = pinned.version

        # The plan comes from the service and nowhere else: this tool keeps no copy of
        # the ladder, so a move it cannot ask about is a move it cannot make.
        step = planned(stages)
        return finish(step) if step.is_a?(Record)

        @out.puts("  step: #{step["name"]} (#{step["from_version"]} -> #{step["to_version"]}), " \
                  "requires Ruby #{step["requires_ruby"] || "unstated"}") if @out

        # The ledger, consulted *before* anything runs: a settled move is the whole
        # point of keeping one, and a step costs a bundle resolve and a suite. `nil`
        # means "nothing ran because there was nothing to do", which the loop reports
        # as such rather than as a step that produced a verdict.
        if (entry = settled_entry(step))
          @out.puts("  already settled: #{entry.verdict} — #{entry.note}") if @out
          return nil
        end

        # The application's own bundle, before anything is measured. `bin/rails` cannot
        # find a gem that was never installed, and a "baseline" that fails in a tenth of a
        # second with a bundler stack trace is not a baseline — it is the same shape of
        # mistake as probing a release that was never in the environment (`AGENTS.md`):
        # the measurement could not be made, so nothing is established about the move, and
        # the verdict says that rather than blaming a release for it.
        install = install_bundle(stages)
        return finish(install_record(install, stages)) unless install.ok?

        # The baseline, on the unmodified copy, before anything is written.
        @baseline = baseline(stages)

        @applied, @refused, @decisions = apply(stages, step)

        pin = rewrite(stages, step)
        return finish(pin) if pin.is_a?(Record)

        update(stages)
        boot(stages)
        @suite = suite(stages)

        verdict, why = Record.verdict(baseline: @baseline, suite: @suite, stages: stages)
        finish(build(step, stages, verdict, why))
      end

      private

      # A working copy, and the two facts about the application that decide whether the
      # rest is worth doing.
      #
      # A kept tree is put back to its base commit first, and the reason is the shape of a
      # process that runs for weeks: a cycle killed mid-step — the memory limit, a
      # SIGKILL after the grace period, the machine going away — leaves a tree that is
      # half a move, and the next cycle would otherwise plan from a Gemfile.lock the
      # interrupted step had already rewritten. That is a *skipped rung*, reported as a
      # step that passed. An interrupted step settled nothing, so the tree it was
      # measured in holds nothing either.
      def prepare(stages)
        @worktree = @source.worktree(@repository, ref: @ref, home: @home, run: run_id, reuse: @reuse)
        if @reuse && Checkpoint.dirty?(@worktree.root)
          Checkpoint.reset(@worktree.root)
          @out.puts("  working copy: reset to #{@worktree.commit.to_s[0, 8]} — a step was interrupted here") if @out
        end
        @lockfile = Lockfile.read(@worktree.root)
        pinned = @lockfile.rails
        unless pinned
          return Record.refused(
            repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
            from_version: "unknown", to_version: @to,
            why: "no Rails release is pinned under #{@worktree.root}: neither the meta-gem " \
                 "nor a framework component is in Gemfile.lock, so there is nothing to step from"
          )
        end
        [@worktree, @lockfile, pinned]
      rescue Source::Failed => e
        Record.refused(repository: @repository, from_version: "unknown", to_version: @to, why: e.message)
      rescue Lockfile::Missing, Lockfile::Unreadable => e
        Record.refused(repository: @repository, from_version: "unknown", to_version: @to, why: e.message)
      end

      def settled_entry(step)
        return nil unless @ledger

        keys = { repo: @repository, commit: @worktree.commit,
                 from_version: step["from_version"], to_version: step["to_version"] }
        entry = @ledger.find(**keys)
        return nil unless entry && @ledger.settled?(**keys)

        entry
      end

      def planned(stages)
        stages << command(Record::PREPARE, ["git", "rev-parse", "--short", "HEAD"],
          chdir: @worktree.root)
        corpus = @corpus || Corpus.new(base: @api)
        payload = corpus.upgrade(from: @from, to: @to)
        step = payload.fetch("steps", []).first
        unless step
          return Record.refused(
            repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
            from_version: @from, to_version: @to,
            why: "the service returned no step for #{@from} -> #{@to}: #{payload["next_step"]}"
          )
        end
        step
      rescue Corpus::Refused => e
        # The service's own sentence, kept whole: it says which direction this ladder
        # reads, or which release it has no chapter for, and that is the part that
        # changes what the caller does next.
        Record.refused(repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to, why: e.message)
      rescue Corpus::Unreachable => e
        Record.refused(repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to,
          why: "#{e.message} (a step needs the ladder, so nothing was attempted)")
      end

      # The application's own bundle on the unmodified checkout, recorded like every other
      # command. `bundle install` and not `bundle update`: this is the environment the
      # baseline needs, and resolving a *new* Rails is the pin stage's business.
      def install_bundle(stages)
        @out.puts("  install: bundle install") if @out
        stage = command(Record::BUNDLE, %w[bundle install], chdir: @worktree.root,
          env: @worktree.bundle_env)
        stages << stage
        stage
      end

      # Nothing ran, and the sentence is why: the answer to "why is the baseline red" a
      # reader needs is the bundle's own output, not a verdict about Rails.
      def install_record(install, stages)
        Record.unverified(
          repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: @from, to_version: @to, stages: stages,
          why: "the application's bundle could not be installed (`bundle install` " \
               "#{install.ran ? "exited #{install.exit_code}" : 'did not run'}), so no " \
               "baseline could be taken and nothing is established about this step: " \
               "#{Record.first_line(install.output_tail)}"
        )
      end

      # The suite on the unmodified copy. Its *absence* is a fact about the application and is
      # recorded as one: `nil` here is what makes the verdict `unverified` rather than
      # `passed`, which is's fourth rule.
      def baseline(stages)
        @suite_plan = @tests.detect(@worktree.root)
        unless @suite_plan
          reason = @tests.respond_to?(:no_suite_reason) ? @tests.no_suite_reason(@worktree.root) : "no suite"
          stages << Record::Command.new(stage: Record::BASELINE, command: reason, ran: false,
            exit_code: nil, seconds: 0.0, output_tail: reason)
          return nil
        end
        @out.puts("  baseline: #{@suite_plan.command}") if @out
        run_suite(stages, Record::BASELINE)
      end

      def suite(stages)
        return nil unless @suite_plan

        run_suite(stages, Record::SUITE)
      end

      # Under the run's own bundle. `Tests.run` merges its `RAILS_ENV`/`RACK_ENV` in first
      # and this over it, so a Rails suite gets both and the gems it loads are the ones
      # `bundle install` put in this run's directory — the alternative is a suite that
      # silently runs against whatever the image happens to have.
      def run_suite(stages, stage)
        result = @tests.run(@worktree.root, @suite_plan, timeout: @suite_timeout,
          env: @worktree.bundle_env)
        stages << Record::Command.new(stage: stage, command: @suite_plan.command, ran: result.ran,
          exit_code: result.exit_code, seconds: result.seconds,
          output_tail: result.output_tail)
        stages.last
      end

      # Ask the service which call sites this step needs, then apply the mechanical half. The
      # manual half is a decision for a person and travels in the record as one —'s fifth
      # rule: a refusal is an output.
      def apply(stages, step)
        files = source_files
        if files.empty?
          stages << Record::Command.new(stage: Record::APPLY, command: "no Ruby source found to scan",
            ran: false, exit_code: nil, seconds: 0.0, output_tail: "")
          # The plan's half is still this step's half: a repository with no Ruby source
          # this tool reads has not thereby moved, and the changes no machine may make
          # are exactly the ones a person still has to.
          return [[], [], decisions_for(step, nil)]
        end

        corpus = @corpus || Corpus.new(base: @api)
        scan = corpus.scan(from: step["from_version"], to: step["to_version"], files: files)
        if @out
          @out.puts("  scan: #{scan["counts"].inspect} — #{files.size} file(s) sent")
          # The counts alone read as one thing and mean three: a window whose documented
          # changes are all patterns that match nothing, a window with *no* pattern at all
          # (the service returns before reading a line, so `lines` is 0 beside 35 files),
          # and a scan that found no call site in this application. The service already
          # writes that sentence for a caller, and this client is one — the alternative is
          # a log where "35 files, 0 lines" looks like a read that did nothing.
          found = scan["counts"].to_h.values_at("automatic", "manual").compact.sum(0)
          @out.puts("  scan: nothing to apply here — #{scan["next_step"]}") if found.zero? && scan["next_step"]
        end

        result = @applier.new(@worktree.root).apply(scan["edits"] || [])
        decisions = decisions_for(step, scan)
        stages << Record::Command.new(
          stage: Record::APPLY,
          command: "apply #{scan["edits"].to_a.size} edit(s) to #{files.size} scanned file(s)",
          ran: true, exit_code: 0, seconds: 0.0,
          output_tail: "applied #{result.applied.size}, refused #{result.refused.size}, " \
                       "#{decisions.size} change(s) need a decision"
        )
        [result.applied, result.refused, decisions]
      end

      # Every change this rung carries that no machine may make, located where the
      # application uses it when the scan found it there.
      #
      # Driven by the *plan's* list rather than by the scanner's findings, and that is a bug
      # found by driving a real step rather than by a test: the 7.1 -> 7.2 rung documents
      # `alias_attribute` as `automatic: false`, an application that never mentions it has no
      # call site to find, so the scan's `manual` list was empty and the record read "0
      # need(s) a decision" beside a plan naming one. The refusal list is half the product and
      # the coverage figure is measured from it, so an empty list that means "nothing was
      # found here" while reading as "nothing was carried" is the empty-answer trap with the
      # count raised. A change this application does not use today is still a change this step
      # carried.
      def decisions_for(step, scan)
        found = (scan && scan["manual"] || []).group_by { |entry| entry["subject"].to_s }
        carried = (step["changes"] || []).reject { |change| change["automatic"] }

        located = carried.map { |change| decision(change, found[change["subject"].to_s]&.first) }
        # And a manual call site the plan does not name is a change nobody has written
        # into the ladder, which is the most useful thing a refusal can say. Dropping it
        # because the digest has no row for it would hide exactly that.
        unplanned = found.keys - carried.map { |change| change["subject"].to_s }
        located + unplanned.flat_map { |subject| found[subject].map { |entry| decision(nil, entry) } }
      end

      # One decision, from whichever side named the change — the plan when it did, the
      # scan's own entry otherwise. The reason joins both notes when they are two, in the
      # order a reader wants them: what the guide says the change is, then what this
      # application's line looks like.
      def decision(change, entry)
        Record::Decision.new(
          path: entry && entry["path"], line: entry && entry["line"],
          subject: ((change && change["subject"]) || entry["subject"]).to_s,
          reason: [change && change["note"], entry && entry["note"]]
                  .compact.reject { |note| note.to_s.empty? }.uniq.join(" — "),
          kind: (change && change["kind"]) || (entry && entry["kind"]),
          replacement: (change && change["replacement"]) || (entry && entry["replacement"]),
          source: (change && change["source"]) || (entry && entry["source"])
        )
      end

      # Which files to send. Bounded, and the bound is stated rather than silently
      # applied: a scan that read a slice and reported "nothing found" would be the
      # empty answer that means four things (`/rails/scan`'s own caveat).
      def source_files
        root = @worktree.root
        paths = Dir.glob("**/*", base: root).reject do |path|
          SCAN_SUFFIXES.none? { |suffix| path.end_with?(suffix) } ||
            path.split("/").any? { |part| SCAN_SKIP.include?(part) }
        end.sort

        chosen = []
        bytes = 0
        paths.each do |path|
          break if chosen.size >= MAX_SCAN_FILES
          text = File.read(File.join(root, path)) rescue next
          break if bytes + text.bytesize > MAX_SCAN_BYTES

          bytes += text.bytesize
          chosen << [path, text]
        end
        @out.puts("  scan: #{chosen.size} of #{paths.size} file(s) (#{bytes} bytes)" \
                  "#{chosen.size < paths.size ? " — bounded" : ""}") if @out
        chosen
      end

      # The one edit this tool makes outside the applier, and it is one line. Only the
      # meta-gem is rewritten: an application that pins the framework as components has a
      # different line for each one, and choosing which of them move together is a decision
      # —'s fourth rule. A repository in that shape is refused, with the sentence saying what
      # to do instead.
      def rewrite(stages, step)
        path = File.join(@worktree.root, "Gemfile")
        text = File.read(path)
        updated = rewrite_pin(text, step["to_version"])
        unless updated
          why = "Gemfile does not pin the meta-gem (`gem \"rails\", \"x\"`), so this tool " \
                "will not choose which of the framework's components move: change the pin " \
                "to #{step["to_version"]} yourself and re-run"
          return Record.refused(repository: @repository, commit: @worktree.commit,
            worktree: @worktree.root, from_version: @from,
            to_version: step["to_version"], why: why)
        end

        File.write(path, updated)
        stages << command(Record::PIN, ["bundle", "update", "rails"], chdir: @worktree.root,
          env: @worktree.bundle_env)
        nil
      end

      # Pure, and its own method, because it is the one thing that rewrites a line of
      # somebody's Gemfile and a test can hold it still.
      def rewrite_pin(text, version)
        lines = text.lines
        found = lines.index { |line| line =~ /^\s*gem\s+["']rails["']/ }
        return nil unless found

        line = lines[found]
        if line =~ /^(\s*gem\s+["']rails["']\s*,\s*)(["'])([^"']*)(\2)/
          lines[found] = "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{version}#{Regexp.last_match(4)}\n"
        elsif line =~ /^(\s*gem\s+["']rails["'])(\s*)$/
          lines[found] = "#{Regexp.last_match(1)}, \"#{version}\"\n"
        else
          # A pin this does not understand — `gem "rails", github: ...`, a version
          # inside a group with other arguments — is left alone rather than guessed at.
          return nil
        end
        lines.join
      end

      # `app:update` proposes new files and new versions of files the application
      # already owns, and "take theirs" is how an application loses its configuration.
      # So: run it, keep what is additive, put everything it modified back, and record
      # the conflicts. `config.load_defaults` is never flipped, and that falls out of
      # this rule rather than being a special case — `config/application.rb` is a file
      # the application already owns, so its version stays.
      def update(stages)
        runner = rails_runner
        unless runner
          stages << Record::Command.new(stage: Record::RAILS_UPDATE,
            command: "bin/rails app:update",
            ran: false, exit_code: nil, seconds: 0.0,
            output_tail: "no bin/rails and no Rakefile: nothing to run")
          return
        end

        before = self.class.dirty_paths(@worktree.root)
        stages << command(Record::RAILS_UPDATE, runner + ["app:update"], chdir: @worktree.root,
          env: @worktree.bundle_env)
        @adopted, @conflicts = self.class.adopt_added_only(@worktree.root, before)
      end

      # **The class methods in this file are public, and the `private` markers around them
      # govern instance helpers only** — a bare `private` cannot reach a singleton method,
      # which is what `Lint/IneffectiveAccessModifier` reports. Their callers are outside the
      # class rather than only inside it: the suite drives `Step.dirty_paths`,
      # `Step.adopt_added_only` and `Step.run_payload` directly (`test/step_test.rb`), and
      # `update` and `contribute` call `self.class.…` with an explicit receiver, which a
      # private method refuses. The markers below are what says so.
      public

      # Class methods rather than instance ones: they are the policy, and a policy with
      # a git repository and nothing else is a policy a test can hold still without
      # installing a bundle or booting an application.
      def self.adopt_added_only(root, before)
        adopted = []
        conflicts = []
        dirty_paths(root).each do |path, status|
          next if before.key?(path)
          next if path == "Gemfile" # ours: the pin, deliberately rewritten

          if status == "??"
            adopted << path
          else
            restore(root, path)
            conflicts << path
          end
        end
        [adopted, conflicts]
      end

      # Every path git considers dirty, and how. `--porcelain` because the format is
      # stable and meant for this, and the two-character status is kept because `??`
      # (added) and ` M` (modified) are the distinction the policy turns on.
      #
      # `-uall` is load-bearing rather than a preference. By default git collapses a
      # wholly untracked directory into one entry — `?? config/` — and the policy above
      # reasons about *paths*: a file `app:update` added inside an untracked directory
      # would arrive as the directory, and a file it modified inside one could not be
      # seen as a conflict at all. The default would silently adopt whatever it wrote
      # inside a directory the application had not committed yet.
      def self.dirty_paths(root)
        output, _status = Open3.capture2e("git", "-C", root, "status", "--porcelain", "-uall")
        output.each_line.filter_map do |line|
          path = line[3..].to_s.strip
          next if path.empty?

          [path, line[0, 2].strip.empty? ? "  " : line[0, 2].strip]
        end.to_h
      end

      # The application's version wins. `checkout --` restores from the index, which is
      # HEAD here, and that is also what keeps `config.load_defaults` where the
      # application put it — no special case needed, because `config/application.rb` is
      # a file the application already owns.
      def self.restore(root, path)
        Open3.capture2e("git", "-C", root, "checkout", "--", path)
      end

      # Its only caller is `adopt_added_only`, above. Nothing outside the class names it, so
      # the tightening is real rather than decorative.
      private_class_method :restore

      private

      def rails_runner
        return ["bin/rails"] if File.executable?(File.join(@worktree.root, "bin/rails"))

        return ["bundle", "exec", "rake", "rails:update"] if File.file?(File.join(@worktree.root, "Rakefile"))

        nil
      end

      def boot(stages)
        return unless File.executable?(File.join(@worktree.root, "bin/rails"))

        stages << command(Record::BOOT, ["bin/rails", "runner", "puts Rails.version"],
          chdir: @worktree.root,
          env: @tests.machine_test_env.merge(@worktree.bundle_env))
      end

      # The patch, for a person to apply. Untracked files are included, because
      # `app:update`'s added files are part of what this step did.
      def capture_patch
        Open3.capture2e("git", "-C", @worktree.root, "add", "--intent-to-add", "--all")
        output, _status = Open3.capture2e("git", "-C", @worktree.root, "diff")
        output
      end

      def build(step, stages, verdict, why)
        Record.new(
          repository: @repository, commit: @worktree.commit, worktree: @worktree.root,
          from_version: step["from_version"], to_version: step["to_version"], name: step["name"],
          requires_ruby: step["requires_ruby"], interpreter: interpreter, image: ENV["UPGRADER_IMAGE"],
          stages: stages, applied: @applied, refused: @refused, decisions: @decisions,
          patch: capture_patch, baseline: @baseline, suite: @suite,
          verdict: verdict, why: why
        )
      end

      def interpreter
        "ruby #{RUBY_VERSION}"
      end

      def command(stage, argv, chdir:, env: {}, stdin: File::NULL)
        @runner.run(argv, stage: stage, chdir: chdir, env: env, stdin: stdin)
      end

      # The ledger learns one line per move, and the record goes where an operator
      # asked for it. Both happen here so that a step which cannot finish still
      # settles what it established.
      def finish(record)
        # A refusal is settled too, and it must be: re-deriving it reaches the same
        # refusal. What is *not* recorded is a move whose starting release could not be
        # read — "unknown -> 7.1.0" is not a key about anything, and a ledger entry
        # under it would hide the next attempt behind a key nobody can look up.
        if @ledger && record.from_version != "unknown"
          @ledger.record(repo: record.repository, commit: record.commit,
            from_version: record.from_version, to_version: record.to_version,
            verdict: record.verdict, baseline: record.baseline&.exit_code,
            image: ENV["UPGRADER_IMAGE"], note: record.why)
        end
        contribute(record) if @contribute
        @out.puts(record.to_s) if @out
        record.write(@record_dir) if @record_dir
        record
      end

      # The run, and — if it failed — the report.: a step that fails is evidence with the
      # corpus's own report shape, so it becomes a report by the ordinary path, precheck
      # first, and one that passes is the other half of the record: proof that a crossing was
      # executed inside something real.
      def contribute(record)
        # What counts as a repository is the service's rule and only the service's:
        # `routers/upgrades.py`'s `identity()` canonicalises a URL and deliberately
        # leaves a bare path alone, because an operator may legitimately name a
        # directory on a machine that has it. A second opinion here — "that is not a
        # repository URL, so it is not a queue entry" — would be this tool disagreeing
        # with the only side that owns the answer.
        client = @corpus || Corpus.new(base: @api)
        answer = client.record_run(self.class.run_payload(record))
        run = answer.is_a?(Hash) ? answer["run"] : nil
        @out.puts("  recorded: run #{run && run["id"]} (#{record.verdict})") if @out

        filing = Filing.file(corpus: client, record: record)
        @out.puts("  filed: #{filing.action} — #{filing.reason}") if @out && filing.action != "skipped"
      rescue Corpus::Unreachable, Corpus::Refused => e
        # The record is the product and it exists whether or not the corpus took it, so
        # this does not change the verdict or raise. It is logged with the service's own
        # sentence rather than swallowed: a refusal that will happen every cycle looks
        # exactly like a quiet run from the outside, which is the miner's lesson about a
        # bare `rescue` around a remote call.
        @out.puts("  not recorded: #{e.message}") if @out
      end

      # Public for the reason the policy group above is — `test/step_test.rb` holds this
      # shape still — and `private` is restored below because `run_id`, the last method in
      # this class, is an instance helper.
      public

      # The body `POST /upgrades/runs` takes, built from the record alone. A class method
      # and pure, because it is the whole of what this tool tells the service about a
      # run and a test can hold it still without a corpus.
      def self.run_payload(record)
        {
          "repo_url" => record.repository,
          "commit" => record.commit,
          "from_version" => record.from_version,
          "to_version" => record.to_version,
          "image" => record.image,
          "verdict" => record.verdict,
          # The *suite's* outcome, not the step's: it is what makes "failed after the
          # upgrade" mean something, and it is deliberately a different field.
          "baseline_verdict" => baseline_verdict(record),
          "note" => record.why,
          "patch" => record.patch,
          # A step is one process run; the record carries when it was written and the
          # commands carry their own durations, so a start time invented here would be
          # a second, disagreeing answer to a question already answered.
          "started_at" => nil,
          "finished_at" => record.recorded_at,
          "commands" => record.stages.map { |stage| command_payload(stage) },
          "refusals" => refusal_payloads(record)
        }
      end

      def self.baseline_verdict(record)
        return nil if record.baseline.nil?

        record.baseline.ok? ? "passed" : "failed"
      end

      def self.command_payload(stage)
        {
          "argv" => stage.command,
          "stage" => stage.stage,
          "exit_code" => stage.exit_code,
          "duration_ms" => (stage.seconds.to_f * 1000).round,
          "stdout_tail" => stage.output_tail,
          "stderr_tail" => nil
        }
      end

      # Two kinds of thing a step carried and did not do, kept apart by which side
      # refused: an applier entry is a change this ladder *does* rewrite and whose line
      # did not match, a plan entry is a change the ladder says needs a person. This is
      # the list the automation-coverage figure counts, which is why the subject travels
      # with each one — a count of refusals that cannot name them says how much is left to
      # do and not what.
      #
      # What is *not* sent is this tool's word for which side refused. It used to fill
      # `kind` and `source` with `"applier"` and `"plan"`, and the service reads those two
      # fields as the ladder's own vocabulary — `kind` is "the kind of change, as the
      # ladder names it" and `source` is the chapter of the guide (`Upgrade::Refusal`)
      # — so a refusal arrived describing the wrong thing in a field that meant something
      # else. The distinction is not lost: the service derives it from the subject against
      # the ladder's own rewrites (`upgrades.py`), which is the only side that owns it.
      def self.refusal_payloads(record)
        record.refused.map do |refusal|
          note = refusal.reason.to_s
          note = "#{note}; found: #{refusal.found}" if refusal.found
          {
            "subject" => (refusal.subject || refusal.text.to_s.split(" ").first || refusal.path).to_s,
            "kind" => refusal.kind,
            "replacement" => refusal.replacement,
            "note" => [refusal.note, note].compact.reject { |text| text.to_s.empty? }.uniq.join(" — "),
            "source" => refusal.source,
            "path" => refusal.path,
            "line" => refusal.line
          }
        end + record.decisions.map do |decision|
          {
            "subject" => decision.subject.to_s,
            "kind" => decision.kind,
            "replacement" => decision.replacement,
            "note" => decision.reason,
            "source" => decision.source,
            "path" => decision.path,
            "line" => decision.line
          }
        end
      end

      # Only `run_payload` calls these three, so they are private class methods rather than
      # public ones — the payload's *shape* is the contract, the builders are not.
      private_class_method :baseline_verdict, :command_payload, :refusal_payloads

      private

      def run_id
        @run_id ||= "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{Process.pid}"
      end
    end
  end
end
