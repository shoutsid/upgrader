# frozen_string_literal: true

require "fileutils"
require "time"

module AgentsFyi
  module Upgrader
    # The service: one step per repository per cycle, over a durable ledger.
    #
    # It is the miner's shape because it has the miner's problem — a process that runs
    # for weeks and must never spend a cycle re-deriving what it already settled — and
    # it differs in the one way that matters: a cycle here is hours long (a bundle
    # resolve, an `app:update`, the application's own suite), so a step that is
    # interrupted is a step that settled nothing and is simply retried. That falls out
    # of the ledger rather than needing code: only a finished step is recorded.
    #
    # Three consequences are load-bearing and all three are why this is a class and not
    # a `while true`:
    #
    # * **The heartbeat is touched once a cycle**, and it is what the container's
    #   healthcheck reads. A process that is up and stuck is the failure a healthcheck
    #   exists to catch, and "up" says nothing about it.
    # * **A signal stops the loop between steps**, not in the middle of one: the ledger
    #   is saved and the container exits, and whatever was in flight is retried at the
    #   next start. A stop request that slept through a ten-minute interval would be a
    #   container the runtime SIGKILLs for no reason.
    # * **The step is a class this loop is handed** rather than one it constructs. Not
    #   for elegance: every one of the behaviours above is about a process that has been
    #   running for hours, and a loop that could only be exercised by cloning a
    #   repository and installing a Rails bundle is a loop whose restart, heartbeat and
    #   stop behaviour have never once been run.
    class Serve
      # How many targets one queue read asks for.
      #
      # Bounded, and the bound is refreshed by doing the work rather than by asking for
      # everything: a target stops being offered once a run has been recorded against it. The
      # number is also a reminder from the miner's own history — a client that asks for more
      # than the service will serve gets a refusal rather than a longer list, and a refusal
      # read as "no queue" is how the queue this service computes went unused for as long as
      # it did. expects the *service* to own the order, so this asks for a slice of it and
      # comes back.
      DEFAULT_QUEUE_LIMIT = 100

      # How many rungs `--walk` chains in one cycle. A budget rather than "until the top":
      # one rung is a bundle install and a test suite, and a cycle that never returned would
      # leave the heartbeat untouched for a day — which is the failure the heartbeat is for.
      DEFAULT_RUNGS_PER_CYCLE = 3

      # The first retry delay for a rung that did not pass, doubled while the same rung keeps not
      # passing and capped at the interval. Thirty seconds rather than the interval because the
      # usual reason a rung does not pass is one somebody has just changed something for — and ten
      # minutes of waiting is a window in which nobody can tell whether the change worked.
      BACKOFF_FLOOR = 30

      # `contribute` is passed through to every step, and the default is the difference
      # between this class and `step` run by hand: the loop owns an operator's account and
      # the decision to walk somebody's application at all, so a run made here is the one
      # that goes into the corpus — the run record the queue and the coverage figure are
      # built from, and a report for a failure. A person asking what a move costs is not
      # asking to write into a corpus other operators read, so `step` leaves it off.
      def initialize(api:, home:, heartbeat:, to: nil, repos: [], interval: 600,
                     step_timeout: 3600, out: $stdout, ledger: nil, cycles: nil,
                     corpus: nil, step_class: Step, queue_limit: DEFAULT_QUEUE_LIMIT,
                     contribute: true, walk: false, publish: false, rungs: nil,
                     publish_class: Publish, suite_env: nil, services: nil, env: ENV,
                     environment: Environment,
                     force: false, record: nil, project: nil, control: nil)
        @api = api
        @home = home
        @to = to
        # The environment the steps are built with, for the same reason the CLI passes one: a knob the loop
        # reads and the step does not is a knob that does nothing.
        @env = env
        # `walk` is the difference between a loop that takes one rung per cycle and one that
        # walks a repository to its target in a cycle: it chains rungs while they pass, up to
        # `rungs` (a budget, because one rung can take half an hour and a cycle that never
        # returned would hold the ledger uncommitted for a day). With it, an empty `--to` is
        # read as "the top of the service's ladder" — the read that exists for exactly this —
        # instead of the deliberate idle an empty target means without it.
        @walk = walk
        # The services a host-run walk talks to, one container for the whole loop (see
        # `Machine::Services`): a step must not own it, because the next step needs it too.
        @services = services
        @publish = publish
        # **The project this loop walks, declared rather than named.** From it come the target
        # release, the starting ref, the suite, the services and the branch namespace; without one
        # every one of those is a command-line flag (the design notes call this the adapter).
        @project = project
        # **`force` reaches the step, because the step is where the ledger's "settled" answer is read.**
        # The loop has no opinion about it of its own, and a flag the loop swallowed would look like it
        # had walked a rung it never touched — measured, `serve --walk --force` printed "already settled:
        # passed" and ran nothing, which reads as a walk that finished rather than one that was skipped.
        @force = force
        # **Where each step writes its patch and its JSON record.** The option was advertised and thrown
        # away: `serve --record DIR` accepted the argument and passed nothing, so a walk's evidence
        # lived only in the corpus — and a record the corpus answers `duplicate` for (which is what
        # every one of the lighthouse's failed 5.1 runs got) was stored nowhere. A step's record is
        # named for the move it made (`<repo>-<from>-<to>.json`), so a walk of several rungs writes one
        # file each rather than overwriting the one before it.
        @record = record
        # **The site admin's stop switch.** A file in the projects volume both containers already
        # mount; `nil` builds the reader for this home, and the suite injects a fake so the stop
        # path is driven without a deployment. A loop started by hand reads the same file, which
        # is deliberate: a person running `serve` against a stopped deployment should be told so
        # rather than walking past a switch somebody meant.
        @control = control || Control.new(home: @home)
        @rungs = rungs || DEFAULT_RUNGS_PER_CYCLE
        # Injectable so the suite can drive "a passed rung is published" without a token, a
        # remote or a network — the class itself is `publish_test.rb`'s subject.
        @publish_class = publish_class
        # The read-only projection the site admin's walk view joins: delivery facts beside the progress
        # file, because the ledger itself is deliberately not mounted into the service.
        @deliveries = Deliveries.new(home: @home, out: @out)
        # The host facts the service cannot query: the era matrix, the images the daemon has, and the
        # volume's room. `nil` disables the feed (the suite's loop has no daemon).
        @environment = environment&.new(home: @home, out: @out)
        # The effective project catalogue, for the site admin's Projects page: the built-ins live in
        # this image and the site admin cannot read them.
        @projects_feed = ProjectsFeed.new(home: @home, out: @out)
        # The deployment's own values for the applications it walks, passed to every step this
        # loop makes (see `Step#read_env_file` for the shape and the reason).
        @suite_env = suite_env
        @heartbeat = heartbeat || File.join(home, "heartbeat")
        # `Array(...)` rather than the parameter's own default, and it is not cosmetic:
        # `repos:` defaults to `[]` so a caller may leave it out, but the CLI passes the
        # `--repo` flag's value, which is `nil` when nobody named a repository — and a
        # default does not apply to a key that *is* present. `nil` and `[]` mean the same
        # thing here (no repositories named), so they are one value before any reader sees
        # them. Found in the deployment rather than here: its container crash-looped on
        # `nil.empty?` at startup with no repository list and no target, which is exactly
        # the configuration a loop waiting for a queue has.
        @repos = Array(repos)
        @interval = interval
        @step_timeout = step_timeout
        @out = out
        # **What the loop is doing, where the operator's site admin can read it.** The step announces
        # its own stages; this is what the loop itself announces — the interval between cycles,
        # which is otherwise indistinguishable from a step that has stopped moving.
        @progress = Progress.new(home: home, out: out)
        @ledger = ledger
        @cycles = cycles
        # Built here rather than lazily, and defaulted rather than required, because the
        # CLI constructs this object without one: a loop that only knows how to read a
        # queue when a test handed it a corpus is a loop whose queue path has never run.
        @corpus = corpus || Corpus.new(base: @api)
        @step_class = step_class
        @queue_limit = queue_limit
        @contribute = contribute
        # The queue row id, by repository, for the target lease. A declaration-driven walk has no
        # queue row and therefore no lease; the row's own id is the only thing the claim names.
        @target_ids = {}
        @stop = false
      end

      def run
        @ledger ||= Ledger.load(File.join(@home, "ledger.json"))
        install_traps

        # The one line that tells an operator whether the volume is still there. A lost
        # `miner_cache`-style volume resets a service to "nothing examined" while the
        # container looks completely healthy, so the count is printed before any work.
        @out.puts("serve: #{@ledger.size} move(s) already settled; #{work_from}")
        # The target is required here for the same reason `plan` requires it: the ladder
        # is the service's and this tool keeps no copy, so a loop that picked "the next
        # release" would be deciding which rung the operator meant.
        if @to.to_s.empty? && !@walk
          @out.puts("serve: no target (deployment-wide); account projects supply their own, " \
                    "and queue rows without one are skipped — set UPGRADER_TO or `--walk` " \
                    "for the rows that do not carry one")
        end

        # One reading before the first cycle, so an operator who opens the page while the loop is
        # planning sees the environment rather than an empty panel, and one after each cycle.
        @environment&.write
        @projects_feed.write

        cycle = 0
        pause = 0
        until @stop
          cycle += 1
          # The moment this cycle began, for the wake marker's comparison: a queue write that
          # lands after the feed read must still shorten the wait that follows.
          @cycle_started_at = Time.now
          outcome = cycle_outcome
          @environment&.write
          @projects_feed.write
          touch
          break if @cycles && cycle >= @cycles

          pause = delay_for(outcome, previous: pause)
          nap(pause, outcome)
        end

        @ledger.save!
        # **A stopped loop has nothing in flight, and says so.** The file is what the site admin's Now
        # panel reads, a step clears it when it finishes, and a *loop* that stops between steps — the
        # end of a walk, or an operator's SIGTERM — left its last one behind, so the panel went on
        # saying "running this" until `STALLED_SECONDS` (twenty minutes) caught up. Measured on this
        # deployment: the walk finished at 17:45 and the file still read a step at 17:52 with nothing
        # running. A stopped loop is not a stalled one, and the honest answer is the empty file.
        @progress.clear
        @out.puts("serve: stopped after #{cycle} cycle(s) with #{@ledger.size} move(s) settled")
        0
      end

      private

      # Where this cycle's work comes from, said once at startup so an operator can tell
      # a deployment that names its own repositories from one that is being given them.
      def work_from
        return "#{@repos.size} repository(ies) to walk" unless @repos.empty?
        return "the project's own repository (#{@project.repo})" unless @project.nil? || @project.repo.to_s.empty?

        "the work list comes from the service's queue"
      end

      # **A stop is answered between commands, and the loop then waits rather than exits.**
      # Exiting would hand the container to `restart: unless-stopped`, which starts it again into
      # the same stop — a crash loop that looks healthy from the outside. Waiting keeps one
      # process, one heartbeat and one place the resume is read.
      def cycle_outcome
        return hold("nothing will be walked while the site admin's stop is in force") if @control.stopped?

        walk
      rescue Control::Stopped => e
        hold(e.message)
      end

      # The loop's stopped state, written where the site admin reads it. The heartbeat keeps
      # moving because the container is alive and healthy; what stopped is the walking, and the
      # progress note is the sentence that says so.
      def hold(note)
        return :stopped if @stop

        @out.puts("serve: #{note} — waiting for the walker control to resume")
        @progress.cycle(note: "stopped — #{note}")
        touch
        until @stop || !@control.stopped?
          sleep 5
          touch
        end
        @out.puts("serve: the walker control is running again") unless @stop
        :stopped
      end

      def walk
        # **The project feed is read once per cycle, not once per process.** The service advances
        # a project's `from_version` when a rung passes; a walker that kept the first read for
        # ever would keep planning from a release it had already left.
        refresh_account_projects!
        # **A settled rung is not a delivered one.** Delivery is retried before this cycle asks for
        # work, because a passed rung whose branch or pull request never arrived is already paid for
        # — re-walking it would spend the rung again — and a delivery that failed in a previous cycle
        # is exactly what the ledger now remembers. This runs even when there is nothing to walk: the
        # debt is about a rung that already passed.
        undelivered = publish_configured? ? retry_delivery : []

        # **A delivery debt blocks the repository, not just the publish.** A failed publish is
        # retried above; if it is still absent, walking the next checkpoint would base its branch
        # on a branch that never arrived. The queue is filtered so another repository can still
        # make progress while this one waits for its delivery.
        available = work.reject do |spec|
          repository, = self.class.split(spec)
          undelivered.include?(Repository.name(repository))
        end
        if available.empty? && undelivered.any?
          @out.puts("serve: #{undelivered.uniq.join(", ")} still have an undelivered checkpoint; " \
                    "no path is walked until delivery succeeds")
          return :blocked
        end

        outcomes = available.map { |spec| walk_spec(spec) }
        return :blocked if outcomes.include?(:blocked)

        outcomes.include?(:worked) ? :worked : :idle
      end

      def walk_spec(spec)
        repository, ref = self.class.split(spec)
        # **A declaration accepted while the cycle is running is still a declaration.** The feed was
        # read when the cycle began, and an answer accepted after that read was not in the object
        # this spec would otherwise use — measured on a project whose retry was planned from the
        # feed read a moment before its accepted answer committed, so the step asked again for a
        # decision the service already had. The read is per target rather than per step: a target
        # is where a queue row is priced, and a feed read between two targets is cheap next to the
        # step that follows it.
        refresh_account_projects!
        # **The queue names the repository; the declaration says how to walk it.** A loop can serve
        # several applications without being told which file belongs to which row, because the
        # declaration's own repository is the join.
        project = project_for(repository)
        # **A queue row with no ref starts where its declaration says**, not on the repository's
        # default branch. The target row carries the repository and (when the operator named one) a
        # ref; the starting ref is an application fact, so a declaration's `base_ref` is the answer
        # for a row that did not choose one. Without this the loop would clone `master` while the
        # declaration says the walk starts at `agents-fyi/baseline`.
        if ref.to_s.empty? && project && !project.base_ref.to_s.empty?
          ref = project.base_ref
        end
        target_id = @target_ids[Repository.name(repository)]
        return walk_repository(repository, ref, project: project, target_id: target_id) if @walk

        record = run_one(repository, ref, project: project, target_id: target_id)
        return :idle if record.nil?
        return :blocked unless record.passed?

        if publish_wanted?(project) && !publish(record, project: project)
          return :blocked
        end
        :worked
      end

      # The declaration for a repository: the one this loop was started with when it matches, and
      # otherwise the one whose repository does. No declaration is not an error — a queue row can
      # name a repository nobody has declared, and the engine then uses the stack's defaults, which
      # is the shape this tool had before declarations existed.
      def project_for(repository)
        if @project && Repository.name(@project.repository) == Repository.name(repository)
          # **The declaration is re-read between checkpoints, because a checkpoint moves in the
          # file the site admin writes.** A hand-started loop holds the object it was given; a
          # declaration that has not changed is returned as the same object, so callers that key
          # on identity (and the tests that assert it) keep working.
          return reload_declaration(@project) || @project
        end

        account_project = account_projects.find do |project|
          Repository.name(project.repository) == Repository.name(repository)
        end
        return account_project if account_project

        Project.find_by_repository(repository)
      end

      # A declaration this loop was started with, re-read from its own file when the file has moved.
      # The comparison is the declaration's own hash, so an unchanged file yields the same object and
      # a site-admin edit (a new `next_checkpoint`, a new suite) is the one that replaces it.
      def reload_declaration(project)
        path = project.path.to_s
        return nil if path.empty? || !File.file?(path)

        fresh = Project.load(path)
        fresh.to_h == project.to_h ? project : fresh
      rescue Project::Invalid
        nil
      end

      # The account projects the service knows, read once per cycle. A row the service cannot make
      # walkable is stated and skipped rather than taking the whole feed down; a queue row with no
      # declaration still uses the stack's defaults, exactly as before.
      def refresh_account_projects!
        remove_instance_variable(:@account_projects) if instance_variable_defined?(:@account_projects)
      end

      def account_projects
        return @account_projects if defined?(@account_projects)

        @account_projects = if @corpus.respond_to?(:projects)
          Array(@corpus.projects.fetch("projects", [])).filter_map do |row|
            # The feed carries the account name for the operator's benefit; it is not a fact about
            # the application, and a project declaration refuses an unknown key by design.
            Project.new(row.reject { |key, _| key == "account" })
          rescue Project::Invalid => e
            @out.puts("serve: account project #{row["slug"].inspect} is not walkable: #{e.message}")
            nil
          end
        else
          []
        end
      rescue Corpus::Unreachable, Corpus::Refused => e
        @out.puts("serve: could not read account projects (#{e.message}); using declarations only")
        @account_projects = []
      end

      # The target every step in this cycle moves towards: the one the operator named, or —
      # under `--walk` — the top of the service's ladder. Asked once per cycle and cached,
      # because it is a fact about the service rather than about a repository, and a cycle
      # that walked five rungs should not have asked five times.
      #
      # `nil` means this loop has nothing to walk towards and says so; without `--walk` that
      # is the deliberate idle an unset target has always meant.
      def target
        return @to unless @to.to_s.empty?
        return @project.to unless @project.nil? || @project.to.to_s.empty?
        return nil unless @walk

        @target ||= @corpus.ladder.fetch("top")
      rescue Corpus::Unreachable, Corpus::Refused, KeyError => e
        @out.puts("serve: the ladder could not be read (#{e.message}), so this cycle will not walk")
        nil
      end

      # One repository, walked: rungs taken while they pass, up to the cycle's budget, and
      # each passed rung published when the operator asked for that.
      #
      # **The outcome is returned because it decides whether the loop waits**, and inferring it
      # from the log is how the loop came to pause ten minutes after a rung that had just passed:
      # `:blocked` is a rung that ran and did not pass (retry soon, not instantly), `:idle` is a
      # move the ledger had already settled (nothing ran at all), and `:worked` is a passed rung,
      # where the next one is ready now.
      def walk_repository(repository, ref, project:, target_id: nil)
        @rungs.times do
          record = run_one(repository, ref, project: project, target_id: target_id)
          return :idle if record.nil?

          return :blocked unless record.passed?

          # **Delivery gates the chain.** The next checkpoint's branch is based on this one's, so a
          # publish that did not arrive must stop the walk rather than stack a pull request on a
          # branch that is not there. `:blocked` is the retry-soon outcome and delivery has its own
          # retry (`retry_delivery`) that does not re-walk the rung.
          if publish_wanted?(project) && !publish(record, project: project)
            @out.puts("serve: #{repository} — the delivery of #{record.to_version} did not arrive, " \
                      "so the walk stops here rather than stacking the next checkpoint on it")
            return :blocked
          end

          # **The next checkpoint is a fresh reading.** The project object this loop holds was the
          # feed's before the run; continuing from it would ask for the stop that just passed, and
          # the step would answer "already at". Re-resolving is also what carries the service's own
          # advance of `from_version` and the checkpoint after it.
          refresh_account_projects!
          project = project_for(repository) || project
        end
        :worked
      end

      # A passed rung's branch and pull request, from the record the step produced. A publish
      # that did not happen is a line rather than a raised exception: the rung *passed*, and
      # a branch that could not be pushed does not un-pass it.
      def publish(record, project: nil)
        root = record.worktree.to_s.empty? ? @home : record.worktree
        pattern = project&.delivery&.branch
        chain = project.nil? ? true : project.delivery.chain
        mode = publish_mode(project)
        publisher = @publish_class.new(
          root: root, repository: record.repository, from_version: record.from_version,
          to_version: record.to_version, record: record, out: @out,
          token: github_token(record.repository), branch_pattern: pattern,
          report_base: ENV["UPGRADER_PUBLIC_URL"], base_ref: project&.base_ref, chain: chain,
          deploy: project&.delivery&.deploy
        )
        result = mode == "branch" ? publisher.call(open_pr: false) : publisher.call
        @out.puts("serve: #{record.repository} — #{result}")
        # **The brief is rendered once, here, and stored beside the delivery.** The site admin reads
        # the bytes the pull request would carry rather than reimplementing `Publish#body` in Rails.
        brief = publisher.respond_to?(:preview_body) ? publisher.preview_body : nil
        remember_delivery(record, result, root: root, pattern: pattern,
          base_ref: project&.base_ref, chain: chain, brief: brief, mode: mode)
        # **A boolean, because the walk's next branch depends on this one.** A plain git remote is a
        # delivered branch with no request, which is complete rather than failed — that distinction
        # already lives on the ledger's answer and is reused here rather than decided twice.
        delivered?(result, record.repository, mode: mode)
      end

      # **The account's handoff switch, with the CLI as an override.** A loop started with
      # `--publish` publishes everything it walks; a project that names `off` is still a project
      # the operator asked to publish by starting the loop that way. A project that names
      # `branch` publishes without opening a request.
      def publish_wanted?(project)
        return true if @publish

        %w[branch pr].include?(project&.delivery&.publish.to_s)
      end

      # **A delivery debt is retried when the ledger says the rung asked for a handoff.** The old
      # gate was the deployment-wide `--publish`, so an account-level `publish: pr` published a
      # passed rung and then never retried a failed one. The ledger entry carries the mode the
      # first attempt used, so this read does not consume a project-feed read — the feed is
      # refreshed per target, and an extra read here shifted the checkpoint the first target used.
      def publish_configured?
        return true if @publish
        return false if @ledger.nil?

        @ledger.entries.any? do |entry|
          delivery = entry.delivery
          next false unless entry.verdict == Ledger::PASSED
          next false if delivery.is_a?(Hash) && delivery["delivered"] == true

          %w[branch pr].include?(delivery.is_a?(Hash) ? delivery["publish"].to_s : "")
        end
      end

      def publish_mode(project)
        mode = project&.delivery&.publish.to_s
        return mode if %w[branch pr].include?(mode)

        @publish ? "pr" : "off"
      end

      # **A connected account gets its own token; there is no deployment-wide customer credential
      # to fall back to.** A repository with no installation is stated and publishes nothing; the
      # account admin surface is where the connection is repaired.
      def github_token(repository)
        return "" unless @corpus.respond_to?(:credential)

        response = @corpus.credential(repository)
        response.is_a?(Hash) ? response["token"].to_s : ""
      rescue Corpus::Refused, Corpus::Duplicate, Corpus::Unreachable => e
        @out.puts("serve: no per-account GitHub credential for #{repository}: #{e.message}")
        ""
      end

      # **What the delivery was, kept on the rung's ledger entry.** The next cycle reads this instead
      # of the record — which is gone by then — and the retry needs the produced commit and the tree
      # it lives in; neither is in the publisher's result or the service's run row.
      def remember_delivery(record, result, root:, pattern:, base_ref: nil, chain: true, brief: nil,
        mode: nil)
        state = {
          "attempted" => true,
          "delivered" => delivered?(result, record.repository, mode: mode),
          "publish" => mode.to_s,
          # **The run this delivery belongs to.** The feed is keyed by the move as well, and a
          # later attempt at the same move must not make an older run page claim its pull request.
          "run_id" => record.run_id,
          "branch" => result.branch,
          "commit" => result.commit,
          # **The base the request actually used.** A chained request names the previous
          # checkpoint's branch; one that fell back names the repository's default, which is the
          # visible shape of a broken stack and the fact the path page needs to say so.
          "base" => result.base,
          "pull_request" => result.pull_request,
          # **GitHub's own stack, when the association was accepted.** The API can refuse it and
          # the branch is still a delivery; the field is how a page tells the two apart.
          "stack" => result.stack,
          "reason" => result.reason,
          # The rendered review brief is evidence a person reads, not a second renderer in the
          # service. It is kept with the delivery because that is where the branch and PR are.
          "brief" => brief.to_s,
          "root" => root.to_s,
          "branch_pattern" => pattern.to_s,
          "base_ref" => base_ref.to_s,
          "chain" => chain
        }
        @ledger&.deliver(
          repo: record.repository, commit: record.commit,
          from_version: record.from_version, to_version: record.to_version, state: state
        )
        @deliveries.record(repo: record.repository, from_version: record.from_version,
          to_version: record.to_version, delivery: state)
      end

      # A branch is delivered when it is on the remote. A pull request is part of delivery only on
      # github.com; a plain git remote has nowhere to open one, and treating that as unfinished is how
      # a mirror would be retried for ever.
      def delivered?(result, repository, mode: nil)
        return false unless result.pushed
        return true if mode.to_s == "branch"

        github = @publish_class.respond_to?(:github?) ? @publish_class.github?(repository) : true
        !github || !result.pull_request.to_s.empty?
      end

      # **Delivery, on its own.** A passed rung whose publish failed is retried from the commit the
      # first attempt produced, and never through the step: the suite that passed is the evidence, and
      # re-walking the rung would both spend it again and change the commit the branch should carry.
      # A tree that is gone cannot be retried (the commit was in it, and the corpus holds the patch but
      # not the objects), so that is said rather than silently skipped.
      #
      # **A rung with no attempt at all is a debt too, and it is the shape a loop leaves behind.**
      # `step --publish` is the one-shot's switch, so a rung walked by hand — or by a loop started
      # without `--publish`, or before the deployment turned publishing on — passes and records no
      # delivery. Nothing revisits a settled rung, so without this the chain keeps a hole for ever:
      # measured on the ohana walk, 7.1.6 passed by hand at 19:17 and by 19:53 the next rung was being
      # measured on top of a checkpoint whose branch had never been pushed. The evidence for it is the
      # record the step wrote — its concern commits, its tree, its brief — so the delivery is read from
      # there rather than by re-walking the rung, and a rung whose record is gone is *said*, not
      # guessed: a branch cannot be built from a patch.
      def retry_delivery
        blocked = []
        return blocked if @ledger.nil?

        @ledger.entries.each do |entry|
          delivery = entry.delivery
          next unless entry.verdict == Ledger::PASSED
          next if delivery.is_a?(Hash) && delivery["delivered"] == true
          next if delivery.is_a?(Hash) && delivery["attempted"] != true

          recovered = !delivery.is_a?(Hash)
          # **A retry is still the same run, and the record is the report.** The first attempt
          # wrote the record; a retry that published only the commit produced a pull request that
          # said the evidence was unavailable. Read the record for both paths.
          record = record_for(entry)
          commit = recovered ? record_head(record) : delivery["commit"].to_s
          root = recovered ? record&.worktree.to_s : delivery["root"].to_s
          if recovered && (record.nil? || commit.empty?)
            @out.puts("serve: #{entry.repo} — #{entry.to_version} passed and was never published, " \
                      "and no record of it was kept, so the commit to publish is not known here: " \
                      "the branch cannot be rebuilt from the patch alone")
            blocked << Repository.name(entry.repo)
            next
          end
          if record.nil?
            @out.puts("serve: #{entry.repo} — the delivery of #{entry.to_version} has no readable " \
                      "record, so its pull request carries the commit without the report")
          end
          unless File.directory?(root)
            @out.puts("serve: #{entry.repo} — the delivery of #{entry.to_version} cannot be retried: " \
                      "the tree at #{root} is gone")
            # The ledger stores the normalized GitHub URL; the queue's spec may be `owner/name`.
            # Blocking on the raw spelling would let the same repository back into `work`.
            blocked << Repository.name(entry.repo)
            next
          end

          project = project_for(entry.repo)
          base_ref = delivery.is_a?(Hash) ? delivery["base_ref"].to_s : ""
          base_ref = project.base_ref if base_ref.empty? && project && !project.base_ref.to_s.empty?
          pattern = delivery.is_a?(Hash) ? delivery["branch_pattern"] : nil
          chain = delivery.is_a?(Hash) && delivery.key?("chain") ? delivery["chain"] != false :
            (project.nil? ? true : project.delivery.chain)
          mode = delivery.is_a?(Hash) ? delivery["publish"].to_s : ""
          mode = "pr" if mode.empty? && @publish
          next if mode == "off"
          publisher = @publish_class.new(
            root: root, repository: entry.repo, from_version: entry.from_version,
            to_version: entry.to_version, record: record, commit: commit,
            out: @out, token: github_token(entry.repo),
            branch_pattern: pattern,
            report_base: ENV["UPGRADER_PUBLIC_URL"], base_ref: base_ref, chain: chain,
            deploy: project&.delivery&.deploy
          )
          result = mode == "branch" ? publisher.call(open_pr: false) : publisher.call
          @out.puts("serve: #{entry.repo} — #{recovered ? "delivery" : "delivery retry"}: #{result}")
          # **What a recovered attempt must write down is what a retry reads.** The first attempt of a
          # rung that never had one is where its `root`, `commit`, pattern and chain are first named;
          # an entry that recorded only the outcome would leave the next cycle with nothing to retry.
          state = (delivery.is_a?(Hash) ? delivery : {}).merge(
            "attempted" => true,
            "delivered" => delivered?(result, entry.repo, mode: mode),
            "publish" => mode,
            "branch" => result.branch,
            "commit" => result.commit.to_s.empty? ? commit : result.commit,
            "pull_request" => result.pull_request,
            "stack" => result.stack,
            "reason" => result.reason,
            "brief" => publisher.respond_to?(:preview_body) ? publisher.preview_body.to_s : "",
            "root" => root,
            "branch_pattern" => pattern.to_s,
            "base_ref" => base_ref.to_s,
            "chain" => chain,
            "run_id" => (delivery.is_a?(Hash) ? delivery["run_id"] : record&.run_id)
          )
          @ledger.deliver(
            repo: entry.repo, commit: entry.commit,
            from_version: entry.from_version, to_version: entry.to_version, state: state
          )
          @deliveries.record(repo: entry.repo, from_version: entry.from_version,
            to_version: entry.to_version, delivery: state)
          blocked << Repository.name(entry.repo) unless
            delivered?(result, entry.repo, mode: mode)
        end
        blocked.uniq
      end

      # The commit a recovered delivery publishes: the last of the record's own concern series, which
      # is the tree's head when the step finished. A record written before the series existed falls
      # back to the tree's `HEAD`, and a tree that is gone answers nothing rather than a guess.
      def record_head(record)
        return "" if record.nil?

        named = Array(record.commits).filter_map do |commit|
          commit.is_a?(Hash) ? commit["commit"] : commit
        end.last
        return named.to_s unless named.to_s.strip.empty?

        Source.head_of(record.worktree).to_s
      end

      # The record a move left behind, or nil. **Not a failure to read it here**: a rung whose record
      # is gone is stated by the caller, which is where the decision about the branch is made.
      def record_for(entry)
        Record.stored(@home, entry.repo, entry.from_version, entry.to_version)
      rescue JSON::ParserError, ArgumentError, TypeError => e
        @out.puts("serve: #{entry.repo} — the record of #{entry.to_version} could not be read: " \
                  "#{e.class}: #{e.message}")
        nil
      end

      # The operator's list wins when there is one — a deployment that named its repositories
      # meant it, and it is also what this container still ships with — and the service's
      # queue is what answers when there is not.: whoever can reach the network fetches, and
      # the service decides what it means; the whole point of the queue is that the order in
      # it is the corpus's answer rather than a list somebody pasted into a compose file.
      def work
        return @repos unless @repos.empty?

        # A project names the repository it is; a loop with one declaration needs no queue to say
        # which application it walks, though the queue still decides *when* when it is present.
        project_spec = project_spec()
        return [project_spec] if project_spec
        return queued if @project.nil?

        []
      end

      # `owner/name@ref` for the project's own repository, or nil when it declared no starting ref.
      def project_spec
        return nil if @project.nil?
        return nil if @project.repo.to_s.empty?

        ref = @project.base_ref.to_s
        ref.empty? ? @project.repository : "#{@project.repository}@#{ref}"
      end

      # The queue as shorthand specs, or nothing at all when the service could not be
      # asked.
      #
      # A failed read is *never* silently an empty queue: the loop says which it got and
      # comes back next cycle, because an outage and "there is no work" want opposite
      # responses and the miner's own trap is a fallback that caught everything and turned
      # a permanent refusal into a quiet afternoon. Empty and unreachable both leave the
      # loop running, which is the one thing they have in common and the only thing the
      # caller does about either.
      def queued
        rows = @corpus.targets(limit: @queue_limit)
        specs = []
        rows.to_a.each do |row|
          url = row.is_a?(Hash) ? row["repo_url"].to_s : ""
          @target_ids[Repository.name(url)] = row["id"].to_s unless url.empty? || row["id"].nil?
          spec = self.class.spec_from(row, out: @out)
          specs << spec if spec
        end
        if specs.empty?
          @out.puts("serve: the service's queue is empty, so this cycle has nothing to walk")
        end
        specs
      rescue Corpus::Unreachable => e
        @out.puts("serve: could not read the queue (#{e.message}) — this cycle walks nothing")
        []
      end

      # **The class methods in this file are public, and the `private` markers around them
      # govern instance helpers only** — a bare `private` cannot reach a singleton method,
      # which is what `Lint/IneffectiveAccessModifier` reports. Two callers make that a
      # decision rather than an accident: the upgrader's suite drives `Serve.split` directly
      # (`test/serve_test.rb`), and `walk`/`queued` call `self.class.split` and
      # `self.class.spec_from` with an explicit receiver, which a private method refuses.
      public

      # A queue row as the shorthand `walk` understands. A row naming no repository is
      # *stated* rather than dropped: a target that the loop silently refuses to walk is
      # indistinguishable from an empty queue, and that is the shape of a bug that runs
      # for weeks.
      def self.spec_from(row, out:)
        url = row.is_a?(Hash) ? row["repo_url"].to_s : ""
        if url.empty?
          out.puts("serve: the queue named a target with no repository — skipped")
          return nil
        end

        # **A finished target is not work.** `done` means its last attempt passed and `refused` means
        # the ladder will refuse the same move again, so both leave the list the loop walks — the
        # knock this removes is the one that filled the corpus with `8.1.0 -> 8.1.0` rows every ten
        # minutes. A passed rung whose run or pull request failed to arrive is a *delivery* retry and
        # has its own queue; walking it again is not that retry.
        status = row.is_a?(Hash) ? row["status"].to_s : ""
        if %w[done refused].include?(status)
          out.puts("serve: #{url} is #{status}, so it is not work — skipped")
          return nil
        end
        # **A blocked target is waiting for a person, not for this loop.** The service's worker
        # queue already omits it; this is the client's half for a deployment whose service is
        # older, and for a manual `--repos` list that never asks the queue at all. Spending a
        # rung here would rediscover the same stop and post the same question.
        if status == "blocked"
          out.puts("serve: #{url} is blocked on a decision — skipped until it is answered")
          return nil
        end

        ref = row["ref"].to_s
        ref.empty? ? url : "#{url}@#{ref}"
      end

      private

      # One repository, one step. `nil` means the move it resolved to was already
      # settled, which is not an error: it is the ledger doing its job, and it is worth a
      # line because it is also what a lost volume would look like from the other side.
      def run_one(repository, ref, project: nil, target_id: nil)
        project ||= project_for(repository)
        lease_token = nil
        if !target_id.to_s.empty?
          claimed, problem = @corpus.claim_target(target_id,
            seconds: @step_timeout.to_i + 300)
          if problem
            @out.puts("serve: #{repository} — #{problem}")
            return nil
          end
          lease_token = claimed["lease_token"].to_s
        end
        # **The checkpoint when the project has one, the destination otherwise.** A feed written
        # before checkpoints existed carries neither field, so an old row keeps walking to `to` —
        # and a service that is mid-upgrade publishes a checkpoint the client already understands
        # because it asked for the fields in the same release that reads them.
        destination = if project && !project.to.to_s.empty?
          project.checkpoint
        else
          target
        end
        if destination.to_s.empty?
          @out.puts("serve: #{repository} — no destination: the project has no target and the " \
                    "loop was not given `--to` or `--walk`")
          return nil
        end

        record = @step_class.new(
          repository: repository, ref: ref, to: destination, api: @api, home: @home, out: @out,
          suite_env: @suite_env,
          ledger: @ledger, suite_timeout: @step_timeout, contribute: @contribute,
          corpus: @corpus, reuse: true, services: @services, env: @env, force: @force,
          record: @record, project: project, control: @control
        ).run
        if record.nil?
          @out.puts("serve: #{repository} — already settled, so nothing was run")
          return nil
        end

        @out.puts("serve: #{repository} -> #{record.verdict} (#{record.to_version})")
        settle(record)
        record
      rescue Lockfile::Missing, Lockfile::Unreadable, Source::Failed, Corpus::Unreachable => e
        # One repository's bad minute is not the loop's: it is logged, the next
        # repository is walked, and the cycle's heartbeat still moves — a service that
        # died because one clone failed is a service that stops working for everybody.
        @out.puts("serve: #{repository}: #{e.class}: #{e.message}")
      ensure
        if lease_token && !target_id.to_s.empty?
          begin
            @corpus.release_target(target_id, lease_token)
          rescue Corpus::Unreachable, Corpus::Refused, Corpus::Duplicate => e
            @out.puts("serve: #{repository} — the target lease could not be released: " \
                      "#{e.message}")
          end
        end
      end

      # What the tree becomes, and this is the difference between a loop and a loop that
      # walks. A step this loop *kept* the tree for has to hand it on in one of two
      # states, and neither is "as the step left it":
      #
      # * **passed** — committed, so the next cycle's base commit is where this step
      #   arrived and the ladder is asked for the rung after it. Without this the next
      #   cycle re-reads the same base, plans the same move, and finds its own ledger
      #   entry: a repository that has been walked once and is now stuck for ever, which
      #   is exactly the failure this project keeps finding in services that look healthy.
      # * **anything else** — reset to the base commit. The tree holds a rewritten pin and
      #   half a move that nobody has shown to work, and the next cycle must retry the same
      #   rung from the same place rather than plan the next one from a release that was
      #   never established.
      def settle(record)
        root = record.worktree.to_s
        return if root.empty? || !File.directory?(root)

        if record.passed?
          commit = Checkpoint.commit(root, from: record.from_version, to: record.to_version, out: @out)
          # The passed head is the next rung's base. Persisting it here — and only here — is what
          # lets `prepare` tell a settled tree from a killed step that happens to be clean.
          Checkpoint.remember_base(root, commit)
          @out.puts("serve: #{record.repository} — the step is committed as #{commit.to_s[0, 8]}, " \
                    "so the next cycle plans from #{record.to_version}")
        else
          # **Back to the commit the rung started from, not merely to a clean worktree.** A failed
          # step may have committed its preflight, rules or pin before the suite went red; those
          # commits are this step's, and a clean tree at their head would still be a half-move the
          # next cycle would plan from.
          base = Checkpoint.base(root) || record.commit
          if Checkpoint.resolvable?(root, base)
            Checkpoint.reset(root, to: base)
            @out.puts("serve: #{record.repository} — #{record.verdict} advances nothing, so the " \
                      "tree is back at its base commit")
          else
            # A base this copy does not hold is a label, not an object. Resetting to HEAD is the
            # only safe move left, and saying so is better than claiming a base that was never
            # reached.
            Checkpoint.reset(root)
            @out.puts("serve: #{record.repository} — #{record.verdict} advances nothing, so the " \
                      "tree is back at HEAD; the recorded base #{base.to_s[0, 8]} is not in this tree")
          end
        end
      end

      # The marker is back for the same reason it is above: the two methods below are
      # public, and the one after them is not.
      public

      # `owner/name@ref` is a person's shorthand, and the ref is optional. `Repository` is the one
      # place that decides what a reference means, so `plan`, `step`, `serve` and a declaration
      # cannot disagree about which repository they mean.
      def self.split(spec) = Repository.split(spec)


      private

      # The healthcheck's file. Written every cycle, whatever the cycle did.
      def touch
        FileUtils.mkdir_p(File.dirname(@heartbeat))
        File.write(@heartbeat, "#{Time.now.utc.iso8601}\n")
      end

      # A flag checked in short steps, rather than a queue the trap handler pushes to.
      #
      # The tidier idiom is `Queue#pop` under a timeout with the handler pushing to wake
      # it, and it is wrong here for one reason: a trap handler runs in a context where
      # some thread primitives are off limits, and the failure that gets wrong is a
      # container that cannot be stopped at all — the runtime SIGKILLs it after the grace
      # period, mid-step, which is exactly what `stop_grace_period` exists to avoid. Half
      # a second of granularity against an interval measured in minutes costs nothing and
      # is a stop request that is always answered.
      # **How long the loop waits, and why it waits at all.** Its own work is never a reason to
      # pause. The interval's stated justification — "a loop that walked faster would re-read ledgers
      # that cannot have changed" — is an argument against *spinning*, not against doing the next
      # useful thing, and it was applied after **every** cycle: a rung that had just passed waited
      # ten minutes before the next one began, which is latency bought for nothing. Two things are
      # worth waiting for:
      #
      # * **Nothing to do** — an empty queue, or a target whose rungs are settled — where the interval
      #   is genuinely the poll's period.
      # * **A rung that just did not pass** — retrying instantly would spin on the same command, and
      #   retrying in ten minutes wastes a window in which somebody may have just fixed what stopped
      #   it. So that delay starts at `BACKOFF_FLOOR` and doubles while the same rung keeps not
      #   passing, capped at the interval; a passed rung resets it.
      def delay_for(outcome, previous:)
        # A stopped cycle already waited for the resume; a second wait would delay the walk after it.
        return 0 if %i[worked stopped].include?(outcome)
        return [previous.zero? ? BACKOFF_FLOOR : previous * 2, @interval].min if outcome == :blocked

        @interval
      end

      # The loop's own rest, said out loud and shown to the site admin: a *stalled* step and a sleeping
      # loop look nothing alike from outside unless the loop says which it is.
      def nap(seconds, outcome)
        return if seconds <= 0

        reason = outcome == :blocked ? "the rung did not pass; retrying" : "nothing to do"
        @out.puts("serve: sleeping #{seconds}s (#{reason})")
        @progress.cycle(note: "waiting #{seconds}s — #{reason}")
        deadline = Time.now + seconds
        since = @cycle_started_at || Time.now
        woken = false
        sleep(0.5) until @stop || Time.now >= deadline || (woken = @control.wake_since?(since))
        return unless woken && !@stop

        @out.puts("serve: a project was queued; waking now")
        @progress.cycle(note: "woken by a queued project")
      end

      def install_traps
        %w[TERM INT].each do |signal|
          Signal.trap(signal) { @stop = true }
        end
      end
    end
  end
end
