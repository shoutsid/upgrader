# frozen_string_literal: true

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
          agents-fyi-upgrader plan  --repo PATH|URL [--ref REF] --to VERSION [--api URL]
          agents-fyi-upgrader step  --repo PATH|URL [--ref REF] --to VERSION [--api URL]
                                    [--record DIR] [--work DIR]
          agents-fyi-upgrader serve [--repos OWNER/NAME[@REF] ...] --to VERSION [--api URL]
                                    [--home DIR] [--heartbeat FILE] [--interval SECONDS]
                                    [--step-timeout SECONDS] [--cycles N]

        Modes:
          plan    read the application's Gemfile.lock, ask the service what the move
                  crosses, and print it. Nothing is written to the source.
          step    do the *first* release of that move on a working copy this tool owns:
                  run the application's suite first, as a baseline; apply the changes
                  the service calls mechanical; rewrite the Rails pin; run
                  `app:update` keeping only what it adds; boot it; run the suite again.
                  Prints the record, and writes the patch and the record as JSON with
                  --record. Never writes to --repo.
          serve   the same, one step per repository per cycle, over a durable ledger.

        Exit status:
          0  a plan was printed, a step ran and did not fail the suite, or the loop
             stopped cleanly
          2  a refusal — the ladder will not plan this move, or the tool will not guess
             a target. The sentence says which.
          1  a real failure — no Gemfile.lock, an unreachable service, git, or a step
             whose suite was green before it and failed after
      TEXT

      def initialize(argv, out: $stdout, err: $stderr, env: ENV, corpus: nil)
        @argv = argv
        @out = out
        @err = err
        @env = env
        @corpus = corpus
      end

      def run
        options = parse
        return usage_error(options[:error]) if options[:error]
        return help if options[:help]
        return usage_error("no command given") unless options[:command]

        case options[:command]
        when "plan" then plan(options)
        when "step" then step(options)
        when "serve" then serve(options)
        else
          usage_error(
            "unknown command `#{options[:command]}` — the modes that exist are `plan`, " \
            "`step` and `serve`"
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
        return usage_error(no_target) unless options[:to]

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
        payload = corpus.upgrade(from: pinned.version, to: options[:to])
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

      # One step, on a copy this tool owns. The exit status follows the record rather
      # than the record following the exit status: `unverified` is a success here (the
      # step ran; nothing was able to check it) and the JSON says which it was, because
      # a caller that only reads the exit code cannot be told a nuance it did not ask
      # for — and one that reads the record gets all of it.
      def step(options)
        return usage_error("step needs --repo PATH|URL") unless options[:repo]
        return usage_error(no_target) unless options[:to]

        record = Step.new(
          repository: options[:repo], ref: options[:ref], to: options[:to], api: options[:api],
          home: options[:home], out: @out, work: options[:work], record: options[:record],
          ledger: Ledger.load(File.join(options[:home], "ledger.json")),
          suite_timeout: options[:step_timeout]
        ).run
        step_status(record)
      end

      def serve(options)
        Serve.new(
          api: options[:api], home: options[:home], heartbeat: options[:heartbeat],
          to: options[:to], repos: options[:repos], interval: options[:interval],
          step_timeout: options[:step_timeout], out: @out, cycles: options[:cycles]
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
      def no_target
        "this tool will not guess a target: pass --to VERSION (for example --to 7.1.0). " \
          "A default arrives when the service exposes the top of its ladder; until then " \
          "this tool keeps no copy of the ladder of its own."
      end

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
          opts.on("--to VERSION", "the Rails release the move ends at, e.g. 7.1.0") { |v| options[:to] = v }
          opts.on("--api URL", "the service to ask (default $AGENTS_FYI_URL)") { |v| options[:api] = v }
          opts.on("--record DIR", "where `step` writes the patch and the JSON record") { |v| options[:record] = v }
          opts.on("--work DIR", "where `step` puts its working copy (default $UPGRADER_HOME)") { |v| options[:work] = v }
          opts.on("--home DIR", "this client's own directory: worktrees and the ledger") { |v| options[:home] = File.expand_path(v) }
          opts.on("--heartbeat FILE", "the file `serve` touches every cycle") { |v| options[:heartbeat] = v }
          opts.on("--interval SECONDS", Integer, "how long `serve` waits between cycles") { |v| options[:interval] = v }
          opts.on("--step-timeout SECONDS", Integer, "how long a suite may run") { |v| options[:step_timeout] = v }
          opts.on("--cycles N", Integer, "stop `serve` after N cycles (default: never)") { |v| options[:cycles] = v }
          # Repeatable, and several may follow one flag: the container's entrypoint
          # expands `UPGRADER_REPOS` unquoted, so the shell hands over separate argv
          # items. Those arrive here as leftover arguments and are collected below —
          # OptionParser would otherwise take only the first and read the second as a
          # repository named after the next flag.
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

      def help
        @out.puts(USAGE)
        EXIT_OK
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
