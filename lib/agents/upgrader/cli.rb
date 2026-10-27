# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"

module Agents
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
      # The modes that read or write the corpus. `prune` and `preview` are local, and `help` is not
      # a mode.
      NEEDS_API = %w[plan preflight step serve decisions].freeze

      EXIT_FAILED = 1
      EXIT_REFUSED = 2

      # **There is no default service.** A walker that quietly talks to the deployment its author
      # ran is answering from a corpus its caller did not choose, which is the same failure
      # `UPGRADER_TO` refuses to have: the deployment names the service (`--api`, `AGENTS_URL`)
      # and a caller that names none is told so.
      API_ENV = "AGENTS_URL"

      # The project a mode walks when none is named on the command line. The deployment sets it, for
      # the reason `UPGRADER_TO` is set there: which application is being walked is a fact about the
      # deployment, not about the engine.
      PROJECT_ENV = "UPGRADER_PROJECT"
      DEFAULT_HOME = "~/.cache/agents-upgrader"

      USAGE = <<~TEXT
        agents-upgrader — move a Rails application one release at a time, using the
        ladder this service publishes

        Usage:
          agents-upgrader --version
          agents-upgrader plan  --repo PATH|URL [--ref REF] [--to VERSION] [--api URL]
                                    [--project SLUG]
          agents-upgrader preflight --repo PATH|URL [--ref REF] [--api URL]
                                    [--record DIR]
          agents-upgrader step  --repo PATH|URL [--ref REF] [--to VERSION] [--api URL]
                                    [--record DIR] [--work DIR] [--force] [--publish]
                                    [--suite-env FILE]
          agents-upgrader serve [--project SLUG] [--repos OWNER/NAME[@REF] ...]
                                    [--to VERSION] [--api URL]
                                    [--home DIR] [--heartbeat FILE] [--interval SECONDS]
                                    [--step-timeout SECONDS] [--cycles N] [--walk]
                                    [--rungs N] [--force] [--publish] [--suite-env FILE]
                                    [--record DIR]
          agents-upgrader republish [--home DIR]
          agents-upgrader preview --from FILE [--base-ref REF] [--report-base URL]
          agents-upgrader prune [--home DIR]
          agents-upgrader decisions list|show|propose|withdraw|resolution
                                    [--api URL] [--project SLUG] [--id ID]
                                    [--state STATE] [--block-kind KIND]
                                    [--change-key KEY] [--effects FILE]
                                    [--choice TEXT] [--proposed-by NAME]
                                    [--answer-id ID] [--from VERSION] [--to VERSION]

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
          preview render the review brief a stored record would publish, without a
                  checkout, a token or a push. This is the dry-run seam: the record is
                  the evidence, and a reviewer reads the same body the pull request would
                  carry.
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
          decisions
                  the questions the walk could not answer: `list`, `show`, `propose`,
                  `withdraw` and `resolution`. A proposal is not an acceptance — a person
                  accepts in the site admin or the project's portal, and this client has no
                  command that would make that act a formality.

        Exit status:
          0  a plan was printed, a step ran and passed, or the loop stopped cleanly
          2  a refusal — the ladder will not plan this move, or the tool will not guess
             a target. The sentence says which.
          1  a real failure — no Gemfile.lock, an unreachable service, git, a step
             whose suite was green before it and failed after, or an `unverified` step
             (nothing was established about the move)
      TEXT

      def initialize(argv, out: $stdout, err: $stderr, env: ENV, corpus: nil, inspector: Open3,
                     step_class: Step)
        @argv = argv
        @out = out
        @err = err
        @env = env
        @corpus = corpus
        # **The process environment reaches the step**, and that is a fix rather than a detail: a `step`
        # built without it read `UPGRADER_COMMAND_TIMEOUT` (and every other knob the step owns) as *absent*,
        # so the bound the run was started with was the default and a walk asked for two minutes got fifteen.
        # `step_class` is a seam for the same reason `inspector` is — the suite asserts what *would* be built.
        @step_class = step_class
        # What `prune` asks the daemon with. Injectable for the same reason every other seam
        # is: the suite asserts the command that *would* run rather than running one.
        @inspector = inspector
      end

      def run
        options = parse
        return usage_error(options[:error]) if options[:error]
        return help if options[:help]
        return version if options[:version]
        return usage_error("no command given") unless options[:command]
        begin
          # **A decision filter is not a declaration.** `--project` on the decision surface names
          # a corpus project, which this container may not have a file for; loading it would make
          # "show me this project's questions" a usage refusal about a local profile.
          @project = options[:command] == "decisions" ? nil : load_project(options)
        rescue Project::Invalid => e
          return usage_error("the project declaration is not usable: #{e.message}")
        end
        apply_project(options)
        # A mode that asks the service without one named is a usage refusal rather than a failed
        # request: there is nowhere to send it.
        if NEEDS_API.include?(options[:command]) && options[:api].empty? && @corpus.nil?
          return usage_error("`#{options[:command]}` needs the service: pass --api URL or set #{API_ENV}")
        end

        case options[:command]
        when "plan" then plan(options)
        when "preflight" then preflight(options)
        when "step" then step(options)
        when "serve" then serve(options)
        when "republish" then republish(options)
        when "preview" then preview(options)
        when "prune" then prune(options)
        when "decisions" then decisions(options)
        else
          usage_error(
            "unknown command `#{options[:command]}` — the modes that exist are `plan`, " \
            "`preflight`, `step`, `serve`, `republish`, `preview`, `prune` and `decisions`"
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

      # The declaration the operator named. A project is *data*, so a declaration that does not parse
      # is a usage refusal: the walk has no opinion about an application it cannot read.
      def load_project(options)
        slug = options[:project].to_s.strip
        slug.empty? ? nil : Project.find(slug)
      end

      # **A declaration supplies the defaults; a flag overrides one.** The walk's repository, the ref
      # it starts from and the release it moves to are properties of the application, so an operator
      # who names a project should not have to repeat them — and a flag named beside it still wins,
      # which is how "walk this project from *this* ref" is said.
      def apply_project(options)
        return if @project.nil?

        # The normalized URL, so a declaration's `owner/name` and the queue's URL are one repository
        # to `plan`, `step` and `serve` alike.
        options[:repo] = @project.repository if options[:repo].to_s.empty?
        options[:ref] = @project.base_ref if options[:ref].to_s.empty? && !@project.base_ref.to_s.empty?
        options[:to] = @project.to if options[:to].to_s.empty?
      end

      # The corpus a mode asks. One place, so an injected corpus (the suite's) is the one every mode
      # sees and no mode can reach a service the caller did not name.
      def corpus_for(options) = @corpus || Corpus.new(base: options[:api])

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

        corpus = corpus_for(options)
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
      # The lockfile's own `RUBY VERSION`, or nil — never an exception. A tree whose lockfile
      # cannot be read is exactly the tree a preflight is for, and failing the mode on it would
      # refuse the repair because of the damage.
      def lockfile_for(root)
        Lockfile.read(root)
      rescue Lockfile::Missing, Lockfile::Unreadable
        nil
      end

      def preflight(options)
        return usage_error("preflight needs --repo PATH|URL") unless options[:repo]

        source = Source.worktree(options[:repo], ref: options[:ref], home: options[:home],
          run: run_id, reuse: false)
        # The interpreter is read from the lockfile here, because this mode is asked about a
        # repository rather than about a rung: `RUBY VERSION` is what the application last
        # succeeded against, which is the closest thing to "the Ruby this move will run on" that
        # a caller with no machine can name. **No rung is passed**, and that is deliberate: this
        # mode's job is the Gemfile an old application cannot install at all, and a move scoped to
        # a rung is not that. An entry whose condition needs the rung is therefore unapplied and
        # the record says so — which is the honest half of a mode that was not told the target.
        result = Preflight.new(root: source.root,
          corpus: corpus_for(options),
          ruby: lockfile_for(source.root)&.locked_ruby).run
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
      # than the record following the exit status. **`unverified` is a failure here**:
      # the step ran, but nothing established that the move worked — no interpreter
      # installed the bundle, the suite could not run, or the baseline was red. The JSON
      # distinguishes it from `failed`, so a caller that reads the record gets the
      # nuance, and a caller that only reads the exit code is not told that measuring
      # nothing was a pass.
      # **The containers a killed run left behind.** `step` and `serve` remove their own when
      # they end, and a process that is killed runs no `ensure` at all — so a container from a
      # crash or a `SIGKILL` keeps running until something looks. This is that look, and the
      # same pass runs before any container starts.
      # **Rewrite the bodies of delivered pull requests from their records.** A maintenance pass
      # rather than a walk: it reads the ledger's delivered entries, rebuilds each step's record and
      # publishes again, so a body composed by an older publisher is replaced. No branch is moved.
      def republish(options)
        corpus = options[:api].to_s.empty? ? nil : corpus_for(options)
        Republish.new(home: options[:home], token: ENV[Publish::ENV_TOKEN], out: @out,
          report_base: ENV["UPGRADER_PUBLIC_URL"], corpus: corpus).call
        EXIT_OK
      end

      # **A record is enough to review a rung.** The preview reads the JSON `step --record` wrote
      # (or the record a service kept) and prints the body a pull request would carry. It touches
      # no repository and no service; a bad file is a usage refusal rather than a crash.
      def preview(options)
        return usage_error("preview needs --from FILE") if options[:from].to_s.empty?

        base = options[:base_ref].to_s.empty? ? options[:ref] : options[:base_ref]
        report_base = options[:report_base].to_s.empty? ? @env["UPGRADER_PUBLIC_URL"] : options[:report_base]
        @out.puts(Preview.from_file(options[:from], base_ref: base, report_base: report_base))
        EXIT_OK
      rescue SystemCallError, JSON::ParserError, ArgumentError, TypeError => e
        @err.puts("failed: the record could not be read: #{e.message}")
        EXIT_FAILED
      end

      # **The decision surface, without an accept command.** A walker or an agent can read a
      # question, propose effects, withdraw its own proposal and read the project's resolution;
      # acceptance is a person's act and stays in the site admin or the portal. The subcommand
      # is the first leftover argument (`decisions show <id>`), which is why `parse` treats that
      # command differently from the ones whose leftovers are repositories.
      def decisions(options)
        corpus = corpus_for(options)
        action = options[:decisions_action].to_s
        case action
        when "list"
          print_json(corpus.decisions(project: options[:project], state: options[:state],
            block_kind: options[:block_kind], change_key: options[:change_key],
            limit: options[:limit]))
        when "show"
          id = decision_id(options)
          return usage_error("decisions show needs an id: pass --id ID or `decisions show ID`") if id.empty?

          print_json(corpus.decision(id))
        when "propose"
          id = decision_id(options)
          return usage_error("decisions propose needs an id: pass --id ID or `decisions propose ID`") if id.empty?
          return usage_error("decisions propose needs --effects FILE with a JSON list") if
            options[:effects].to_s.empty?

          effects = JSON.parse(File.read(options[:effects]))
          unless effects.is_a?(Array) && !effects.empty?
            return usage_error("--effects must be a non-empty JSON list of effects")
          end

          payload = {
            "choice" => options[:choice].to_s,
            "proposed_by" => options[:proposed_by].to_s,
            "effects" => effects,
            "provenance" => { "surface" => "cli", "read" => ["the question"] }
          }
          payload["choice"] = "proposed from the CLI" if payload["choice"].empty?
          payload["proposed_by"] = "model:cli" if payload["proposed_by"].empty?
          print_json(corpus.propose_decision(id, payload))
        when "withdraw"
          id = decision_id(options)
          answer = options[:answer_id].to_s
          return usage_error("decisions withdraw needs an id and --answer-id ID") if id.empty? || answer.empty?

          print_json(corpus.withdraw_decision(id, answer))
        when "resolution"
          project = decision_id(options)
          project = options[:project].to_s if project.empty?
          return usage_error("decisions resolution needs a project id or --project SLUG") if project.empty?

          print_json(corpus.resolution(project, from: options[:from], to: options[:to]))
        else
          return usage_error(
            "unknown decisions command `#{action}` — the subcommands are `list`, `show`, " \
            "`propose`, `withdraw` and `resolution`"
          )
        end
        EXIT_OK
      rescue JSON::ParserError => e
        usage_error("--effects is not JSON: #{e.message.to_s.lines.first.to_s.strip}")
      rescue SystemCallError => e
        usage_error("--effects could not be read: #{e.message}")
      end

      def print_json(payload)
        @out.puts(JSON.pretty_generate(payload))
      end

      def decision_id(options) = (options[:id] || options[:decisions_id]).to_s

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

        services = services_for(options)
        begin
          record = @step_class.new(
            repository: options[:repo], ref: options[:ref], to: target(options), api: options[:api],
            home: options[:home], out: @out, work: options[:work], record: options[:record],
            ledger: Ledger.load(File.join(options[:home], "ledger.json")),
            suite_timeout: options[:step_timeout], force: options[:force],
            suite_env: options[:suite_env], services: services, env: @env, project: @project
          ).run
          return step_status(record) unless options[:publish]

          published(record, options)
        ensure
          services&.stop!
        end
      end

      # **The services container belongs to the walk, not to a step.** `rvm` mode runs the
      # application on the host, so its services are a sibling container with published ports
      # that has to outlive every step of the walk — which is what makes the mode fast: a
      # container per step, and per interpreter candidate, was the slowest thing a walk did.
      # The other two modes need none: `docker` puts the services inside the step's own
      # container, and a native step uses whatever the host already has.
      def services_for(options)
        return nil unless rvm_mode?

        Machine::Services.new(home: options[:home], out: @out)
      end

      def rvm_mode?
        %w[rvm host].include?(@env[Step::RUNTIME_ENV].to_s.strip.downcase)
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

        # **The declaration travels with a hand-run publish too.** The record carries the project
        # it was walked under, so a `step --publish` opens the same chained, stacked request the
        # loop would; without it the first rung ignored the declared starting ref and every
        # request targeted the default branch.
        fields = record.project.is_a?(Hash) ? record.project : {}
        delivery = fields["delivery"].is_a?(Hash) ? fields["delivery"] : {}
        result = Publish.new(
          root: record.worktree, repository: options[:repo],
          from_version: record.from_version, to_version: record.to_version,
          record: record, out: @out, token: @env[Publish::ENV_TOKEN],
          base_ref: @project&.base_ref || fields["base_ref"],
          branch_pattern: @project&.delivery&.branch || delivery["branch"],
          chain: (@project ? @project.delivery.chain : delivery["chain"] != false)
        ).call
        @out.puts(result.to_s)
        return step_status(record) if result.published? || result.pushed

        @err.puts("failed: #{result}")
        EXIT_FAILED
      end

      def serve(options)
        services = services_for(options)
        begin
          Serve.new(
            api: options[:api], home: options[:home], heartbeat: options[:heartbeat],
            to: options[:to], repos: options[:repos], interval: options[:interval],
            step_timeout: options[:step_timeout], out: @out, cycles: options[:cycles],
            walk: options[:walk], publish: options[:publish], rungs: options[:rungs],
            force: options[:force], record: options[:record],
            suite_env: options[:suite_env], services: services, env: @env, project: @project
          ).run
        ensure
          services&.stop!
        end
      end

      # 0 ran, 2 refused, 1 the pipeline could not go on or the suite failed after a
      # green baseline. `nil` is a move the ledger had already settled — nothing ran and
      # nothing was wrong.
      # **An unverified step is not a plan.** Nothing was established — no interpreter installed the bundle,
      # the suite could not be run — and a caller that reads that as success has been told the wrong thing.
      # The three values are the contract (0 a plan, 2 a refusal, 1 a failure) and unverified belongs with the
      # failures, because it is about the machine rather than about the move. A real walk found this: an
      # interpreter that could not reach github failed for every era, and the step exited 0.
      def step_status(record)
        return EXIT_OK if record.nil?
        return EXIT_REFUSED if record.refused?
        return EXIT_FAILED if record.failed? || record.unverified?

        EXIT_OK
      end

      # A target is required, and this says why rather than picking one. The ladder
      # lives in the service and nowhere else; a tool that knew "the next release
      # after 4.2 is 5.0" would be a second copy of the ladder, and a second copy is
      # how two answers to one question start disagreeing — which this project has
      # paid for more than once.
      def parse
        argv = @argv.dup
        # A leading flag is not a command. `agents-upgrader --help` was read as an
        # unknown mode named `--help`, because the shift took the flag before OptionParser
        # could claim it — and `plan --help` worked, so only the bare form was wrong.
        command = argv.first&.start_with?("-") ? nil : argv.shift
        options = {
          command: command,
          api: @env[API_ENV].to_s.strip,
          project: @env[PROJECT_ENV].to_s.strip,
          home: File.expand_path(@env["UPGRADER_HOME"].to_s.empty? ? DEFAULT_HOME : @env["UPGRADER_HOME"]),
          interval: 600,
          step_timeout: Step::DEFAULT_SUITE_TIMEOUT
        }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--repo PATH|URL", "the repository to plan: a local path or a git URL") { |v| options[:repo] = v }
          opts.on("--ref REF", "the branch or tag to read; a local plan reads HEAD") { |v| options[:ref] = v }
          opts.on("--to VERSION", "the Rails release the move ends at, e.g. 7.1.0 " \
                  "(default: the top of the service's ladder)") { |v| options[:to] = v }
          opts.on("--api URL", "the service to ask (default $AGENTS_URL)") { |v| options[:api] = v }
          opts.on("--project SLUG", "the declared application to walk (default $UPGRADER_PROJECT)") do |v|
            options[:project] = v
          end
          opts.on("--record DIR", "where `step` writes the patch and the JSON record") { |v| options[:record] = v }
          opts.on("--from FILE", "the record `preview` renders") { |v| options[:from] = v }
          opts.on("--base-ref REF", "the chain base a preview names (default: the repository's)") { |v| options[:base_ref] = v }
          opts.on("--report-base URL", "the public service a preview links reports to") { |v| options[:report_base] = v }
          opts.on("--work DIR", "where `step` puts its working copy and bundle (default $UPGRADER_HOME)") do |v|
            options[:work] = File.expand_path(v)
          end
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
          # Repeatable, for a one-off manual `serve`; the deployment's queue is the ordinary
          # source and the entrypoint no longer passes this. Several may follow one flag: a
          # shell list hands over separate argv items, and they are collected below —
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
          # The decision surface's own flags. `--id` is the question (or project) a subcommand
          # names; a positional after the subcommand works too, which is how `decisions show ID`
          # reads. `--project` is shared with the walk's declaration for `list`/`resolution`.
          opts.on("--id ID", "the decision (or project) a `decisions` subcommand names") { |v| options[:id] = v }
          opts.on("--state STATE", "`decisions list` filter: open, answered, superseded or dismissed") { |v| options[:state] = v }
          opts.on("--block-kind KIND", "`decisions list` filter: route, pin, suite, boot, check, …") { |v| options[:block_kind] = v }
          opts.on("--change-key KEY", "`decisions list` filter by change key") { |v| options[:change_key] = v }
          opts.on("--limit N", Integer, "`decisions list` page size") { |v| options[:limit] = v }
          opts.on("--effects FILE", "`decisions propose`: a JSON list of typed effects") { |v| options[:effects] = v }
          opts.on("--choice TEXT", "`decisions propose`: the answer's label") { |v| options[:choice] = v }
          opts.on("--proposed-by NAME", "`decisions propose`: `model:<name>` or `operator:<uuid>`") { |v| options[:proposed_by] = v }
          opts.on("--answer-id ID", "`decisions withdraw`: the proposal to withdraw") { |v| options[:answer_id] = v }
          opts.on("--version", "print the client version and exit") { options[:version] = true }
          opts.on("-h", "--help", "this text") { options[:help] = true }
        end

        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          options[:error] = "#{e.message}\n\n#{USAGE}"
        end
        if options[:command] == "decisions"
          # The first leftover is the subcommand and the second is its id; neither is a
          # repository. A flag named later still wins, because `--id` is read above.
          options[:decisions_action] = argv.shift
          options[:decisions_id] = argv.shift
        else
          options[:repos] = (options[:repos] || []) + argv unless argv.empty?
        end
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

        payload = (corpus || corpus_for(options)).ladder
        top = payload.is_a?(Hash) ? payload["top"].to_s : ""
        raise Corpus::Unreachable, "the ladder read carried no `top`" if top.empty?

        top
      end

      def help
        @out.puts(USAGE)
        EXIT_OK
      end

      def version
        @out.puts(Agents::Upgrader::VERSION)
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
