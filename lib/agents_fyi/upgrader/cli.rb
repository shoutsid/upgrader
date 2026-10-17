# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"

module AgentsFyi
  module Upgrader
    # The one command, and what its exit status means.
    #
    # Three codes, and the distinction is the contract rather than tidiness: a caller
    # — a person, a CI job, later the service's own record of a run — has to be able
    # to tell "this repository cannot be planned" from "this move is refused",
    # because the first is a fact about the repository and the second is a fact about
    # the ladder. Collapsing them into 1 is how a refusal gets read as a crash.
    #
    # `out`, `err`, `env` and `corpus` are injectable so the tests can drive the
    # whole command — including its exit codes — without a network, a git repository
    # or a second port.
    class CLI
      EXIT_OK = 0
      EXIT_FAILED = 1
      EXIT_REFUSED = 2

      DEFAULT_API = "https://agents.shoutsid.fyi"
      DEFAULT_HOME = "~/.cache/agents-fyi-upgrader"

      USAGE = <<~TEXT
        agents-fyi-upgrader — move a Rails application one release at a time, using the
        ladder this service publishes

        Usage:
          agents-fyi-upgrader plan  --repo PATH|URL [--ref REF] [--to VERSION] [--api URL]
          agents-fyi-upgrader preflight --repo PATH|URL [--ref REF] [--api URL]
                                    [--record DIR]
          agents-fyi-upgrader step  --repo PATH|URL [--ref REF] [--to VERSION] [--api URL]
                                    [--record DIR] [--work DIR] [--force] [--publish]
                                    [--suite-env FILE]
          agents-fyi-upgrader serve [--repos OWNER/NAME[@REF] ...] [--to VERSION] [--api URL]
                                    [--home DIR] [--heartbeat FILE] [--interval SECONDS]
                                    [--step-timeout SECONDS] [--cycles N] [--walk]
                                    [--rungs N] [--publish] [--suite-env FILE]
          agents-fyi-upgrader prune [--home DIR]

        Modes:
          plan    read the application's Gemfile.lock, ask the service what the move
                  crosses, and print it. Nothing is written to the source.
          preflight
                  the moves an old Gemfile needs before it can be installed at all: a
                  `git://` remote GitHub stopped accepting in 2022, a fork that no longer
                  exists, a pin that cannot sit beside the framework — from the service's
                  gem-migrations digest. Writes into a working copy this tool owns and
                  prints what it did; `step` runs the same preflight before it installs.
          step    do the *first* release of that move on a working copy this tool owns:
                  run the application's suite first, as a baseline; apply the changes
                  the service calls mechanical; rewrite the Rails pin; run
                  `app:update` keeping only what it adds; boot it; run the suite again.
                  Prints the record, and writes the patch and the record as JSON with
                  --record. Never writes to --repo.
          prune   remove what finished and killed runs left behind: the step containers a
                  killed run kept running (a process that is *killed* runs no cleanup at
                  all, so its container keeps its services and its memory) and the bundle
                  a run installed, which is per-run by design and 150 MB each. `step` and
                  `serve` run the same pass before they start one of their own.
          serve   the same, one step per repository per cycle, over a durable ledger.
                  With `--walk` it chains rungs within a cycle (up to `--rungs`) and reads an
                  empty `--to` as the top of the service's ladder; with `--publish` it pushes
                  a branch per passed rung and opens a pull request chained to the rung
                  before it.

        Exit status:
          0  a plan was printed, a step ran and did not fail the suite, or the loop
             stopped cleanly
          2  a refusal — the ladder will not plan this move, or the tool will not guess
             a target. The sentence says which.
          1  a real failure — no Gemfile.lock, an unreachable service, git, or a step
             whose suite was green before it and failed after
      TEXT

      def initialize(argv, out: $stdout, err: $stderr, env: ENV, corpus: nil, inspector: Open3)
        @argv = argv
        @out = out
        @err = err
        @env = env
        @corpus = corpus
        # What `prune` asks the daemon with. Injectable for the same reason every other seam
        # is: the suite asserts the command that *would* run rather than running one.
        @inspector = inspector
      end

      def run
        options = parse
        return usage_error(options[:error]) if options[:error]
        return help if options[:help]
        return usage_error("no command given") unless options[:command]

        case options[:command]
        when "plan" then plan(options)
        when "preflight" then preflight(options)
        when "step" then step(options)
        when "serve" then serve(options)
        when "prune" then prune(options)
        else
          usage_error(
            "unknown command `#{options[:command]}` — the modes that exist are `plan`, " \
            "`preflight`, `step`, `serve` and `prune`"
          )
        end
      rescue Corpus::Refused => e
        @err.puts("refused: #{e.message}")
        EXIT_REFUSED
      rescue Corpus::Unreachable, Lockfile::Missing, Lockfile::Unreadable, Source::Failed => e
        @err.puts("failed: #{e.message}")
        EXIT_FAILED
      end

      private

      def plan(options)
        return usage_error("plan needs --repo PATH|URL") unless options[:repo]

        source = Source.resolve(options[:repo], ref: options[:ref], home: options[:home])
        lockfile = Lockfile.read(source.root)
        pinned = lockfile.rails
        unless pinned
          return failure(
            "no Rails release is pinned under #{source.root}: neither the meta-gem nor any " \
            "framework component is in Gemfile.lock, so there is nothing to plan against"
          )
        end

        corpus = @corpus || Corpus.new(base: options[:api])
        payload = corpus.upgrade(from: pinned.version, to: target(options, corpus))
        @out.puts(
          Plan.new(
            payload: payload,
            repository: source.description,
            commit: source.commit,
            lockfile: lockfile
          ).to_s
        )
        EXIT_OK
      end

      # One working copy, preflighted: the repairs an old Gemfile needs before anything can
      # be installed at all. `step` runs the same preflight as its first move; this mode
      # exists because that half of a walk is worth being able to look at on its own —
      # it is the half that cannot be established by installing anything.
      #
      # The service's digest is read, and a service that does not answer it is a *narrowed*
      # preflight rather than a failure: the general repairs are facts about a protocol,
      # and the record says which half was skipped.
      def preflight(options)
        return usage_error("preflight needs --repo PATH|URL") unless options[:repo]

        source = Source.worktree(options[:repo], ref: options[:ref], home: options[:home],
          run: run_id, reuse: false)
        result = Preflight.new(root: source.root,
          corpus: @corpus || Corpus.new(base: options[:api])).run
        @out.puts(result.to_s)
        if options[:record]
          FileUtils.mkdir_p(options[:record])
          File.write(File.join(options[:record], "preflight.json"),
            "#{JSON.pretty_generate(result.to_h)}\n")
        end
        EXIT_OK
      rescue Preflight::NotAnApplication => e
        failure(e.message)
      end

      # One step, on a copy this tool owns. The exit status follows the record rather
      # than the record following the exit status: `unverified` is a success here (the
      # step ran; nothing was able to check it) and the JSON says which it was, because
      # a caller that only reads the exit code cannot be told a nuance it did not ask
      # for — and one that reads the record gets all of it.
      # **The containers a killed run left behind.** `step` and `serve` remove their own when
      # they end, and a process that is killed runs no `ensure` at all — so a container from a
      # crash or a `SIGKILL` keeps running until something looks. This is that look, and the
      # same pass runs before any container starts.
      def prune(options)
        containers = Machine::Container.reap!(out: @out, inspector: @inspector)
        bundles = Source.prune_bundles(home: options[:home], out: @out)
        if containers.empty? && bundles.empty?
          @out.puts("nothing to prune: no step container outlived its process and no run " \
                    "left a bundle behind")
        end
        EXIT_OK
      end

      def step(options)
        return usage_error("step needs --repo PATH|URL") unless options[:repo]

        record = Step.new(
          repository: options[:repo], ref: options[:ref], to: target(options), api: options[:api],
          home: options[:home], out: @out, work: options[:work], record: options[:record],
          ledger: Ledger.load(File.join(options[:home], "ledger.json")),
          suite_timeout: options[:step_timeout], force: options[:force],
          suite_env: options[:suite_env]
        ).run
        return step_status(record) unless options[:publish]

        published(record, options)
      end

      # The delivery half of a walk: a branch per passed rung and a pull request chained to
      # the rung before it. A step that did not pass is not published — the sentence says
      # so, and the exit status stays the *step's*, because "the ladder refused this move"
      # and "the branch could not be pushed" are different news for whoever is reading.
      def published(record, options)
        if record.nil?
          @out.puts("publish: nothing to publish — the ledger had already settled this move")
          return EXIT_OK
        end
        unless record.passed?
          @out.puts("publish: skipped — the step's verdict is #{record.verdict}, and a branch " \
                    "is a claim that this rung works")
          return step_status(record)
        end

        result = Publish.new(
          root: record.worktree, repository: options[:repo],
          from_version: record.from_version, to_version: record.to_version,
          record: record, out: @out, token: @env[Publish::ENV_TOKEN]
        ).call
        @out.puts(result.to_s)
        return step_status(record) if result.published? || result.pushed

        @err.puts("failed: #{result}")
        EXIT_FAILED
      end

      def serve(options)
        Serve.new(
          api: options[:api], home: options[:home], heartbeat: options[:heartbeat],
          to: options[:to], repos: options[:repos], interval: options[:interval],
          step_timeout: options[:step_timeout], out: @out, cycles: options[:cycles],
          walk: options[:walk], publish: options[:publish], rungs: options[:rungs],
          suite_env: options[:suite_env]
        ).run
      end

      # 0 ran, 2 refused, 1 the pipeline could not go on or the suite failed after a
      # green baseline. `nil` is a move the ledger had already settled — nothing ran and
      # nothing was wrong.
      def step_status(record)
        return EXIT_OK if record.nil?
        return EXIT_REFUSED if record.refused?
        return EXIT_FAILED if record.failed?

        EXIT_OK
      end

      # A target is required, and this says why rather than picking one. The ladder
      # lives in the service and nowhere else; a tool that knew "the next release
      # after 4.2 is 5.0" would be a second copy of the ladder, and a second copy is
      # how two answers to one question start disagreeing — which this project has
      # paid for more than once.
      def parse
        argv = @argv.dup
        # A leading flag is not a command. `agents-fyi-upgrader --help` was read as an
        # unknown mode named `--help`, because the shift took the flag before OptionParser
        # could claim it — and `plan --help` worked, so only the bare form was wrong.
        command = argv.first&.start_with?("-") ? nil : argv.shift
        options = {
          command: command,
          api: @env["AGENTS_FYI_URL"].to_s.empty? ? DEFAULT_API : @env["AGENTS_FYI_URL"],
          home: File.expand_path(@env["UPGRADER_HOME"].to_s.empty? ? DEFAULT_HOME : @env["UPGRADER_HOME"]),
          interval: 600,
          step_timeout: Step::DEFAULT_SUITE_TIMEOUT
        }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--repo PATH|URL", "the repository to plan: a local path or a git URL") { |v| options[:repo] = v }
          opts.on("--ref REF", "the branch, tag or commit to read (URLs only)") { |v| options[:ref] = v }
          opts.on("--to VERSION", "the Rails release the move ends at, e.g. 7.1.0 " \
                  "(default: the top of the service's ladder)") { |v| options[:to] = v }
          opts.on("--api URL", "the service to ask (default $AGENTS_FYI_URL)") { |v| options[:api] = v }
          opts.on("--record DIR", "where `step` writes the patch and the JSON record") { |v| options[:record] = v }
          opts.on("--work DIR", "where `step` puts its working copy (default $UPGRADER_HOME)") { |v| options[:work] = v }
          opts.on("--home DIR", "this client's own directory: worktrees and the ledger") { |v| options[:home] = File.expand_path(v) }
          opts.on("--heartbeat FILE", "the file `serve` touches every cycle") { |v| options[:heartbeat] = v }
          opts.on("--interval SECONDS", Integer, "how long `serve` waits between cycles") { |v| options[:interval] = v }
          opts.on("--step-timeout SECONDS", Integer, "how long a suite may run") { |v| options[:step_timeout] = v }
          opts.on("--suite-env FILE", "KEY=VALUE lines merged into every command that runs the " \
                                      "application — for a repository whose secrets are not in " \
                                      "it (a git-ignored `config/application.yml`, a `.env`)") { |v| options[:suite_env] = v }
          opts.on("--publish", "push a branch and open (or update) a pull request for a " \
                               "passed step, chained to the previous rung's branch " \
                               "(needs $#{Publish::ENV_TOKEN})") { |v| options[:publish] = v }
          # Repeatable, and several may follow one flag: the container's entrypoint
          # expands `UPGRADER_REPOS` unquoted, so the shell hands over separate argv
          # items. Those arrive here as leftover arguments and are collected below —
          # OptionParser would otherwise take only the first and read the second as a
          # repository named after the next flag.
          # **Four flags the usage text named before the parser did.** `--cycles`, `--walk`,
          # `--rungs` and `--force` were documented (and the deployment's entrypoint passes
          # two of them) while `parse` had no option for any of them, so `serve --walk` read
          # as "no walk" and a bounded run never bounded. Found by reading the parser against
          # the usage text after a `--force` that would not parse; `cli_test.rb` now drives
          # every flag the text names through the parser, which is the test that would have
          # caught it the first time.
          opts.on("--cycles N", Integer, "stop `serve` after N cycles (default: never)") { |v| options[:cycles] = v }
          opts.on("--walk", "chain rungs within a cycle, and read an empty --to as the top " \
                            "of the service's ladder") { |v| options[:walk] = v }
          opts.on("--rungs N", Integer, "how many rungs `--walk` chains in one cycle " \
                                        "(default #{Serve::DEFAULT_RUNGS_PER_CYCLE})") { |v| options[:rungs] = v }
          opts.on("--force", "walk a move even though the ledger has settled it — the " \
                             "ledger is a memory, not a lock") { |v| options[:force] = v }
          opts.on("--repos OWNER/NAME[@REF]", "a repository for `serve` to walk") do |v|
            (options[:repos] ||= []).concat(v.split(","))
          end
          opts.on("-h", "--help", "this text") { options[:help] = true }
        end

        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          options[:error] = "#{e.message}\n\n#{USAGE}"
        end
        options[:repos] = (options[:repos] || []) + argv unless argv.empty?
        options
      end

      # The target a mode works to: the one the caller named, or the top of the service's
      # own ladder.
      #
      # Naming one is still the caller's choice to make — `serve` deliberately idles
      # without one, because a deployment that has not decided where it is going must not
      # start walking somebody's application — but `plan` and `step` are asked by a person
      # who may not know what the newest release this ladder carries is, and "to what?" is
      # a question the service answers better than this tool. It answers it *decisively*:
      # the top is a fact the service publishes, not a guess about Rails' release order,
      # and `no_target`'s promise ("a default arrives when the service exposes the top of
      # its ladder") is what this is.
      def target(options, corpus = nil)
        return options[:to] if options[:to]

        payload = (corpus || @corpus || Corpus.new(base: options[:api])).ladder
        top = payload.is_a?(Hash) ? payload["top"].to_s : ""
        raise Corpus::Unreachable, "the ladder read carried no `top`" if top.empty?

        top
      end

      def help
        @out.puts(USAGE)
        EXIT_OK
      end

      # One name per invocation, so two working copies from one process cannot collide —
      # the shape `Step#run_id` has, repeated here because `preflight` is a mode of its
      # own and a copy it makes is not a step's.
      def run_id
        @run_id ||= "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{Process.pid}"
      end

      def usage_error(message)
        @err.puts("refused: #{message}")
        EXIT_REFUSED
      end

      def failure(message)
        @err.puts("failed: #{message}")
        EXIT_FAILED
      end
    end
  end
end
