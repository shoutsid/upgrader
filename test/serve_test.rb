# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "time"
require "timeout"
require "tmpdir"
require "agents_fyi/upgrader"

# The loop, driven without a repository.
#
# `serve` is the one mode whose failures are invisible from outside: a service that is
# up and redoing work it already settled looks exactly like one that is working, and it
# can look like that for hours. So what is tested here is the four things a container
# cannot show about itself — that it walks the work it was given once per cycle, that a
# restart does not redo what the ledger holds, that the heartbeat moves whatever the
# cycle did, and that a stop request is answered between steps rather than slept
# through.
#
# The step is a stand-in because the real one clones a repository and installs a Rails
# bundle; nothing in this file claims to test a step, only what the loop does with one.
class ServeTest < Minitest::Test
  Serve = AgentsFyi::Upgrader::Serve
  Ledger = AgentsFyi::Upgrader::Ledger
  Source = AgentsFyi::Upgrader::Source
  Corpus = AgentsFyi::Upgrader::Corpus

  # What the loop reads out of a step's record, and every field here is one it decides
  # from: the verdict and the release for its own line, and the worktree, repository and
  # starting release because a step this loop *kept* the tree for has to be handed on in
  # one of two states (committed when it passed, reset when it did not). A record's patch
  # and command list are still none of this loop's business, which is why this is a Struct
  # rather than the real thing.
  Result = Struct.new(:verdict, :to_version, :worktree, :repository, :from_version, :commit,
    :run_id, keyword_init: true) do
    def passed? = verdict == AgentsFyi::Upgrader::Record::PASSED
  end

  # A step that never runs anything. It records every invocation — including whether the
  # heartbeat existed when it was called, which is how "written every cycle" is a
  # measurement instead of a reading of the source — and hands back whatever the test
  # queued for it. An exception (or an exception *class*, which is how `raise` is called)
  # in the queue is raised, so the loop's rescue paths can be driven too.
  #
  # It settles its move in the ledger the way the real step does, because the ledger is
  # what the restart test is about and a stand-in that skipped it would leave that
  # behaviour untestable.
  class FakeStep
    # Initialised here as well as in `setup`, and both are needed: a double whose class
    # state is only created by a *teardown* means the first test to run in a given order
    # reads `nil` where every later one reads an empty array — a failure that appears and
    # disappears with the suite's random seed, which is what this was. The class-level
    # values make `calls` always an array; `setup` is what keeps one test's calls out of
    # the next one's assertions.
    @calls = []
    @results = []
    @walked = 0

    class << self
      attr_reader :calls, :results, :walked
    end

    def self.reset!(results: [])
      @results = results
      @calls = []
      @walked = 0
    end

    def self.next_result
      @results.shift
    end

    def initialize(**kwargs)
      @kwargs = kwargs
      @worktree = self.class.tree(kwargs[:home])
      self.class.calls << kwargs.merge(
        heartbeat_seen: File.file?(File.join(kwargs[:home].to_s, "heartbeat"))
      )
    end

    def run
      result = self.class.next_result
      raise result if result.is_a?(Exception) || (result.is_a?(Class) && result <= Exception)
      return result if result.nil?

      self.class.instance_variable_set(:@walked, self.class.walked + 1)

      # What a real step leaves behind: a pin it rewrote and a file it added. The loop's
      # own work on the tree is decided from exactly these, so a double that handed back a
      # *clean* path would leave both halves untested while looking tested.
      File.write(File.join(@worktree, "Gemfile"), %(gem "rails", "#{result.to_version}"\n))
      File.write(File.join(@worktree, "app_update_added.rb"), "# what app:update wrote\n")
      settle(result)

      Result.new(verdict: result.verdict, to_version: result.to_version, worktree: @worktree,
        repository: @kwargs[:repository], from_version: "4.2.11", commit: "9f2c1ab8",
        run_id: "run-1")
    end

    # A real git tree, because what the loop does with it — commit a passing step, reset
    # one that did not pass — is `git` and nothing else. One per test, under the test's own
    # home, so no test's commits are another's base.
    def self.tree(home)
      dir = File.join(home.to_s, "fake-tree")
      return dir if File.directory?(File.join(dir, ".git"))

      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "Gemfile"), %(gem "rails", "4.2.11"\n))
      File.write(File.join(dir, ".gitignore"), "tmp/\nlog/\n")
      git(dir, "init", "--quiet")
      git(dir, "add", "--all")
      git(dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
        "commit", "--quiet", "-m", "the application as it arrived")
      dir
    end

    def self.git(dir, *argv)
      system("git", "-C", dir, *argv, out: File::NULL, err: File::NULL)
    end

    private

    def settle(result)
      ledger = @kwargs[:ledger]
      return if ledger.nil?

      ledger.record(repo: @kwargs[:repository], commit: "9f2c1ab8", from_version: "4.2.11",
        to_version: result.to_version, verdict: result.verdict)
    end
  end

  # A publisher that fails the first attempt and succeeds on the retry. The first answer is a
  # branch that never reached the remote; the second is the same commit with a pull request.
  class RetryPublish
    @calls = []
    class << self
      attr_reader :calls
    end
    def self.reset! = (@calls = [])

    def initialize(**kwargs)
      @kwargs = kwargs
      self.class.calls << kwargs
    end

    def call
      if self.class.calls.size == 1
        AgentsFyi::Upgrader::Publish::Result.new(pushed: false, branch: "agents-fyi/upgrade-5.0.0",
          commit: "c0ffee01", reason: "the branch could not be pushed: no route to host")
      else
        AgentsFyi::Upgrader::Publish::Result.new(pushed: true, branch: "agents-fyi/upgrade-5.0.0",
          base: "main", commit: "c0ffee01",
          pull_request: "https://github.com/acme/storefront/pull/2", reason: "")
      end
    end
  end

  # A publisher that never delivers, for the cross-cycle half of the delivery gate: a failed
  # retry must keep the repository blocked rather than let the next checkpoint onto a branch that
  # never arrived.
  class NeverPublish
    def initialize(**); end

    def call
      AgentsFyi::Upgrader::Publish::Result.new(pushed: false,
        branch: "agents-fyi/upgrade-7.0.6", commit: "c0ffee01",
        reason: "the branch could not be pushed: no route to host")
    end
  end

  # The service, as much of it as the loop touches: one method, and it records what it
  # was asked for so a test can tell a queue read from a queue read that never happened.
  class FakeCorpus
    attr_reader :asked, :ladder_reads

    def initialize(targets: [], raises: nil, ladder: "8.1.0", ladder_raises: nil)
      @targets = targets
      @raises = raises
      @ladder = ladder
      @ladder_raises = ladder_raises
      @asked = []
      @ladder_reads = 0
    end

    def targets(limit:)
      @asked << limit
      raise @raises if @raises

      @targets
    end

    def ladder
      @ladder_reads += 1
      raise @ladder_raises if @ladder_raises

      { "top" => @ladder }
    end
  end

  # Publishing, as much of it as the loop touches: it records every record it was handed.
  class FakePublish
    def self.published = @published ||= []
    # Every argument the loop handed the publisher, so a wiring the *result* cannot show (the branch
    # pattern, which the double's result already substitutes) is still asserted.
    def self.calls = @calls ||= []
    def self.reset! = (@published = []) && (@calls = [])

    def initialize(**kwargs)
      @kwargs = kwargs
      self.class.calls << kwargs
    end

    def call
      self.class.published << @kwargs[:record]
      AgentsFyi::Upgrader::Publish::Result.new(pushed: true, branch: "agents-fyi/upgrade-#{@kwargs[:to_version]}",
        base: "main", commit: "9f2c1ab8", pull_request: "https://github.com/acme/storefront/pull/1",
        reason: "")
    end

    def preview_body = "## What moved\n\n5.0.0 → 5.1.0\n"
  end

  def setup
    FakeStep.reset!(results: [])
  end

  def teardown
    @dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def track(dir)
    (@dirs ||= []) << dir
    dir
  end

  def home
    @home ||= track(Dir.mktmpdir)
  end

  # **A stopped loop has nothing in flight, and says so.** The Now panel reads this file; a step
  # clears it when it finishes, and a loop that stops *between* steps — the end of a walk, or an
  # operator's SIGTERM — used to leave the last one behind, so the panel said "running this" until
  # `STALLED_SECONDS` (twenty minutes) caught up. Measured on the deployment: the walk finished at
  # 17:45 and the file still named a step at 17:52 with nothing running.
  # The site admin's switch, as the loop sees it: `stopped?` answers from this list in order, so a
  # stop that is lifted between checks is the resume path rather than a second stop.
  class FakeControl
    def initialize(*states, wake: false)
      @states = states
      @wake = wake
    end

    def stopped? = @states.length > 1 ? @states.shift : @states.first
    def wake_since?(_moment) = @wake
  end

  # **A stop is answered before any work and the loop waits, rather than exiting.** Exiting would
  # let `restart: unless-stopped` start it again into the same switch — a crash loop that looks
  # healthy — so the assertion here is both that no step was built and that the loop came back.
  def test_a_stopped_switch_walks_nothing_and_waits_for_a_resume
    out = StringIO.new
    serve(cycles: 1, control: FakeControl.new(true, false), out: out).run

    assert_empty FakeStep.calls, "a step was built while the walker control said stopped"
    assert_includes out.string, "waiting for the walker control to resume"
    assert_includes out.string, "running again"
  end

  # The exception a real `Step` raises at its next command boundary reaches the loop and leaves
  # the rung unsettled: nothing is recorded and the next cycle is the one that tries again.
  def test_a_step_stopped_mid_command_is_not_settled
    out = StringIO.new
    ledger = Ledger.load(File.join(home, "ledger.json"))
    stop = AgentsFyi::Upgrader::Control::Stopped.new("the walker is stopped: clearing the queue")

    serve(cycles: 1, out: out, control: FakeControl.new(false), ledger: ledger).tap do |loop|
      loop.define_singleton_method(:walk) { raise stop }
    end.run

    assert_includes out.string, "clearing the queue"
    assert_equal 0, ledger.size, "a stopped step settled a rung it never measured"
  end

  def test_a_stopped_loop_leaves_nothing_in_flight
    progress = AgentsFyi::Upgrader::Progress.new(home: home)
    progress.stage(repo: "https://example.test/app", from: "5.2.0", to: "6.0.0",
      stage: "pin", detail: "bundle update rails")
    assert File.exist?(AgentsFyi::Upgrader::Progress.path(home)), "the fixture wrote no progress"

    serve(cycles: 1).run

    refute File.exist?(AgentsFyi::Upgrader::Progress.path(home)),
      "the loop stopped and left a step looking in flight"
  end

  def serve(corpus: FakeCorpus.new, cycles: 1, interval: 0, repos: [], to: "7.1.0",
            ledger: nil, out: nil, walk: false, publish: false, rungs: nil, force: false, record: nil,
            project: nil, publish_class: FakePublish, control: nil, step_class: FakeStep)
    Serve.new(api: "http://api.test", home: home, heartbeat: File.join(home, "heartbeat"),
      to: to, repos: repos, interval: interval, out: out || StringIO.new,
      ledger: ledger, cycles: cycles, corpus: corpus, step_class: step_class,
      walk: walk, publish: publish, rungs: rungs, publish_class: publish_class, force: force,
      record: record, project: project, environment: nil, control: control)
  end

  # **The account project, not the deployment, decides the destination and suite.** The queue names
  # a repository; the service's project feed carries the version window and the application's own
  # suite, and the loop must hand that declaration to the step rather than the global `--to`.
  def test_an_account_project_supplies_its_own_destination_and_suite
    corpus = FakeCorpus.new(targets: [
      { "repo_url" => "acme/account", "ref" => "main", "status" => "queued" }
    ])
    corpus.define_singleton_method(:projects) do
      { "projects" => [{
        "slug" => "account", "repo" => "acme/account", "base_ref" => "main",
        "from" => "7.1.0", "to" => "8.1.0", "stack" => "rails",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
        "source_roots" => ["app", "components"],
        "checks" => [{ "id" => "lint", "kind" => "lint", "command" => "bundle exec rubocop" }],
        "toolchain" => { "ruby" => "3.3.12" },
        "style" => { "format" => "bundle exec rubocop -A" },
        "app_update" => { "framework_defaults" => "step" },
        "delivery" => { "provider" => "none" },
        "account" => "Team"
      }] }
    end

    serve(corpus: corpus, cycles: 1, to: "7.1.0").run

    call = FakeStep.calls.first
    refute_nil call, "the account project's queue row was not walked"
    assert_equal "8.1.0", call[:to], "the step walked the deployment target instead of the account's"
    assert_equal "account", call[:project].slug
    assert_equal "bundle exec rspec", call[:project].suite_command
    assert_equal %w[app components], call[:project].source_roots
    assert_equal "lint", call[:project].checks.first.id
    assert_equal "3.3.12", call[:project].toolchain.ruby
    assert call[:project].app_update.step_defaults?
  end

  # **A finished target is not work.** The loop used to knock on the queue's `done` row every ten
  # minutes, be refused with "`8.1.0` and `8.1.0` are the same Rails release", and record the
  # refusal — eight rows in one evening saying a finished walk is finished. `done` and `refused` both
  # leave the list the loop walks, and they say so on the line rather than vanishing. A `blocked`
  # row is the third: it is waiting for a person, not for another rung.
  def test_a_finished_refused_or_blocked_target_is_not_walked_again
    corpus = FakeCorpus.new(targets: [
      { "repo_url" => "acme/finished", "ref" => "main", "status" => "done" },
      { "repo_url" => "acme/refused", "ref" => "main", "status" => "refused" },
      { "repo_url" => "acme/blocked", "ref" => "main", "status" => "blocked" }
    ])
    out = StringIO.new

    serve(corpus: corpus, cycles: 1, out: out).run

    assert_empty FakeStep.calls, "a finished target was walked again"
    assert_includes out.string, "acme/finished is done, so it is not work"
    assert_includes out.string, "acme/refused is refused, so it is not work"
    assert_includes out.string, "acme/blocked is blocked on a decision"
  end

  # **A project supplies the walk.** A loop given a declaration needs no `--repo`, `--ref` or `--to`:
  # the application's own facts say which repository to clone, which ref to start from and which
  # release to move to — and the same declaration travels to the step, which reads its suite and its
  # environment names from it. Measured on the lighthouse: all three were flags before, which is how
  # the engine came to know one application (see `docs/design-notes.md`).
  def test_a_project_supplies_the_repository_the_ref_the_target_and_the_step
    project = AgentsFyi::Upgrader::Project.find("lighthouse")
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "8.1.0")])

    serve(corpus: FakeCorpus.new, to: nil, repos: [], project: project, cycles: 1).run

    call = FakeStep.calls.last
    assert_equal "https://github.com/shoutsid/biddingapp.git", call[:repository]
    assert_equal "agents-fyi/baseline", call[:ref]
    assert_equal "8.1.0", call[:to]
    assert_same project, call[:project]
  end

  # And the branch namespace is the project's: a fork or a second project publishes under its own
  # prefix rather than this tool's, which is why the pattern is declared rather than assumed.
  def test_a_project_s_publishing_pattern_reaches_the_publisher
    project = AgentsFyi::Upgrader::Project.find("lighthouse")
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "8.1.0")])

    serve(corpus: FakeCorpus.new, to: nil, repos: [], project: project, cycles: 1, publish: true,
      walk: true, rungs: 1).run

    assert_equal "agents-fyi/upgrade-<release>", FakePublish.calls.last[:branch_pattern]
    assert_equal "agents-fyi/baseline", FakePublish.calls.last[:base_ref],
      "the declaration's starting ref did not reach the publisher"
    assert FakePublish.calls.last[:chain],
      "the declaration's chain setting did not reach the publisher"
  end

  # **The loop waits only when waiting is the answer.** A passed rung has the next one ready now, and
  # the ten-minute pause that used to follow *every* cycle was latency bought for nothing: the
  # interval's stated justification — "a loop that walked faster would re-read ledgers that cannot
  # have changed" — is an argument against *spinning*, not against doing the next useful thing. What
  # is worth waiting for is nothing to do, or a rung that did not pass; and that one backs off, because
  # retrying instantly spins on the same command while retrying in ten minutes wastes the window in
  # which somebody may have just fixed what stopped it.
  def test_only_nothing_to_do_or_a_blocked_rung_waits_and_a_blocked_one_backs_off
    walker = serve(interval: 600)

    assert_equal 0, walker.send(:delay_for, :worked, previous: 600),
      "a passed rung waited before starting the next one"
    assert_equal AgentsFyi::Upgrader::Serve::BACKOFF_FLOOR,
      walker.send(:delay_for, :blocked, previous: 0),
      "a rung that did not pass is retried after the whole interval"
    assert_equal 120, walker.send(:delay_for, :blocked, previous: 60),
      "the retry delay does not grow while the same rung keeps not passing"
    assert_equal 600, walker.send(:delay_for, :blocked, previous: 600),
      "the backoff is not capped at the interval"
    assert_equal 600, walker.send(:delay_for, :idle, previous: 0),
      "an empty queue is not polled on the interval"
  end

  # **A queued project is a notification, not the next poll.** The interval is the fallback for a
  # deployment where the service cannot write the projects volume; a marker written in it ends the
  # rest at the next half-second check, so a person who has just pressed Start does not watch a
  # ten-minute sleep.
  def test_a_queued_project_wakes_the_idle_wait
    out = StringIO.new
    walker = serve(interval: 600, out: out, control: FakeControl.new(false, wake: true))
    started = Time.now

    walker.send(:nap, 600, :idle)

    assert_operator Time.now - started, :<, 5, "the wake marker was slept through"
    assert_includes out.string, "a project was queued; waking now"
  end

  # **`serve --record` writes what `step --record` writes.** The option was advertised and never passed,
  # so a walk's record lived only in the corpus — and a record the corpus refuses as a duplicate
  # (`filed: not_filed`, which is what it answered for every one of the lighthouse's failed 5.1 runs)
  # was stored nowhere at all: measured three times, where each failure's own output had to be recovered
  # by re-running the step with `--record`.
  def test_a_walk_hands_the_steps_the_record_directory_it_was_given
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    dir = track(Dir.mktmpdir)
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    serve(corpus: corpus, record: dir).run

    assert_equal [dir], FakeStep.calls.map { |call| call[:record] }.uniq,
      "the step was not told where to write its record"
  end

  # One repository in the queue, walked once per cycle. Two cycles is the acceptance
  # criterion's shape: a repository walked on consecutive steps is two cycles, because a cycle
  # is one step — the ladder answers what the next move is, and the tool's own job is to come
  # back for it.
  def test_two_cycles_walk_the_repository_the_queue_named
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0"),
                              Result.new(verdict: "passed", to_version: "6.0.0")])
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    assert_equal 0, serve(corpus: corpus, cycles: 2, out: out).run

    assert_equal 2, FakeStep.calls.size, "the queue named one repository, so one step per cycle"
    repositories = FakeStep.calls.map { |call| call[:repository] }.uniq
    assert_equal ["https://github.com/acme/storefront.git"], repositories
    assert_includes out.string, "(5.0.0)"
    assert_includes out.string, "(6.0.0)"
    assert_equal 2, corpus.asked.size, "the queue is read once per cycle, not once per process"
  end

  # The shorthand an operator types, and the queue row the service hands over, both have
  # to become something git can clone. The ssh URL is the case that a split on `@`
  # silently gets wrong, and a *path* is the other: the service accepts a target whose
  # `repo_url` is a directory on this machine (`identity()` leaves a bare path alone on
  # purpose), and prefixing it with github.com turned a queue row into a clone of nothing.
  def test_a_repository_shorthand_becomes_something_git_can_clone
    assert_equal ["https://github.com/acme/storefront.git", nil], Serve.split("acme/storefront")
    assert_equal ["https://github.com/acme/storefront.git", "v1"], Serve.split("acme/storefront@v1")
    assert_equal ["https://github.com/acme/storefront.git", "main"],
      Serve.split("https://github.com/acme/storefront.git@main")
    assert_equal ["git@github.com:acme/storefront.git", nil],
      Serve.split("git@github.com:acme/storefront.git")
    assert_equal ["/srv/applications/storefront", nil], Serve.split("/srv/applications/storefront")
    assert_equal ["./storefront", "main"], Serve.split("./storefront@main")
  end

  # A tree the loop keeps is the difference between a repository walked once and one that
  # can walk: the next cycle's base is where this step arrived, so the ladder is asked for
  # the rung *after* the one just settled.
  def test_a_passing_step_leaves_its_tree_committed_for_the_next_rung
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    out = StringIO.new

    serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }]), cycles: 1,
      out: out).run

    tree = File.join(home, "fake-tree")
    subject, = capture2("git", "-C", tree, "log", "-1", "--format=%s")
    assert_includes subject, "the 4.2.11 -> 5.0.0 step", "the step's tree was not checkpointed"
    assert_empty capture2("git", "-C", tree, "status", "--porcelain").first.strip
    assert_includes out.string, "the step is committed as"
    # And the flag that made it a kept tree at all: a loop that asked for a per-run copy
    # would re-clone every cycle and never see its own previous step.
    assert_equal [true], FakeStep.calls.map { |call| call[:reuse] }.uniq
  end

  # A step that did not pass advances nothing, so the tree goes back to its base commit:
  # otherwise the next cycle plans from a Gemfile.lock the step had already rewritten,
  # which is a skipped rung reported as a step that passed.
  def test_a_step_that_did_not_pass_leaves_its_tree_at_the_base_commit
    FakeStep.reset!(results: [Result.new(verdict: "failed", to_version: "5.0.0")])
    out = StringIO.new

    serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }]), cycles: 1,
      out: out).run

    tree = File.join(home, "fake-tree")
    assert_includes File.read(File.join(tree, "Gemfile")), %(gem "rails", "4.2.11"),
      "the tree still holds the release the step never established"
    refute File.exist?(File.join(tree, "app_update_added.rb")), "the step's added file survived"
    assert_empty capture2("git", "-C", tree, "status", "--porcelain").first.strip
    assert_includes out.string, "advances nothing, so the tree"
  end

  # **The next stop is the checkpoint, not the destination.** A project on a path publishes the
  # exact release to walk next; handing the step `to` would make every checkpoint a leap to the end
  # of the path — which is the shape the ladder refuses because it has no chapter for it.
  def test_a_project_with_a_checkpoint_walks_it_instead_of_the_destination
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "7.0.6")])
    corpus = account_corpus(account_row("next_checkpoint" => "7.0.6"))

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 1).run

    assert_equal "7.0.6", FakeStep.calls.first[:to],
      "the walker went to the destination instead of the checkpoint the service planned"
  end

  # **A declaration accepted while the cycle is running belongs to the next target.** The cycle
  # used to read the feed once, so a project the service published after that read was invisible
  # until the next cycle — measured on a retry planned from the feed a moment before its accepted
  # answer committed. The read is per target, so a queue with two repositories sees the second
  # target's declaration even when it did not exist when the first was walked.
  def test_a_project_published_mid_cycle_is_used_by_the_next_target
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "7.1.0"),
      Result.new(verdict: "passed", to_version: "8.1.0")
    ])
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/one", "ref" => "main" },
                                      { "repo_url" => "acme/two", "ref" => "main" }])
    row = account_row("slug" => "two", "repo" => "acme/two")
    corpus.define_singleton_method(:projects) do
      { "projects" => FakeStep.calls.any? ? [row] : [] }
    end

    serve(corpus: corpus, cycles: 1, to: "7.1.0").run

    assert_equal 2, FakeStep.calls.size
    assert_equal "7.1.0", FakeStep.calls.first[:to]
    assert_equal "8.1.0", FakeStep.calls.last[:to],
      "the second target read the feed from before the project was published"
    assert_equal "two", FakeStep.calls.last[:project].slug
  end

  # **A passed checkpoint is followed by the next one from a fresh reading.** The project object the
  # cycle started with still names the stop that just passed; continuing from it would ask for the
  # same release, and the step would answer "already at". The feed is re-read after every pass.
  def test_a_passed_checkpoint_refreshes_the_feed_before_the_next_one
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "7.0.6"),
      Result.new(verdict: "passed", to_version: "7.1.6")
    ])
    feed = [account_row("from" => "7.0.3", "next_checkpoint" => "7.0.6"),
            account_row("from" => "7.0.6", "next_checkpoint" => "7.1.6")]
    reads = 0
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/account", "ref" => "main",
                                        "status" => "queued" }])
    corpus.define_singleton_method(:projects) do
      row = feed[[reads, feed.size - 1].min]
      reads += 1
      { "projects" => [row] }
    end

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 2).run

    assert_equal %w[7.0.6 7.1.6], FakeStep.calls.map { |call| call[:to] },
      "the walk repeated the checkpoint it had just passed"
  end

  # **Delivery gates the chain.** The next checkpoint's branch is based on this one's, so a publish
  # that did not arrive has to stop the walk rather than stack a pull request on a branch that is not
  # there. The rung passed and stays settled; only the next stop waits.
  def test_a_delivery_that_did_not_arrive_stops_before_the_next_checkpoint
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "7.0.6"),
      Result.new(verdict: "passed", to_version: "7.1.6")
    ])
    RetryPublish.reset!
    out = StringIO.new
    corpus = account_corpus(account_row("next_checkpoint" => "7.1.6"))

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 2, publish: true,
      publish_class: RetryPublish, out: out).run

    assert_equal 1, FakeStep.walked, "the next checkpoint was stacked on a branch that never arrived"
    assert_includes out.string, "stops here rather than stacking"
  end

  # The next cycle must remember the debt. The old retry logged the failure and then walked the
  # next checkpoint anyway, which is the same branch-stacking bug one cycle later.
  def test_a_delivery_that_still_fails_on_retry_keeps_the_repository_blocked
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "7.0.6"),
      Result.new(verdict: "passed", to_version: "7.1.6")
    ])
    out = StringIO.new
    corpus = account_corpus(account_row("next_checkpoint" => "7.1.6"))

    serve(corpus: corpus, cycles: 2, to: nil, walk: true, rungs: 2, publish: true,
      publish_class: NeverPublish, out: out).run

    assert_equal 1, FakeStep.walked,
      "a still-undelivered rung let the next checkpoint stack on a missing branch"
    assert_includes out.string, "still have an undelivered checkpoint"
  end

  # A feed written before checkpoints existed carries neither field, and that project keeps walking
  # to its destination. The service and the client are deployed apart, so this is the older side.
  def test_a_feed_with_no_checkpoint_still_walks_the_destination
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "8.1.0")])
    corpus = account_corpus(account_row)

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 1).run

    assert_equal "8.1.0", FakeStep.calls.first[:to]
  end

  # A queue row for one account project, as the service publishes it. One helper so a test about a
  # path is not also a test of the declaration's shape.
  def account_corpus(row)
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/account", "ref" => "main",
                                        "status" => "queued" }])
    corpus.define_singleton_method(:projects) { { "projects" => [row] } }
    corpus
  end

  def account_row(**overrides)
    {
      "slug" => "account", "repo" => "acme/account", "base_ref" => "main",
      "from" => "7.0.3", "to" => "8.1.0", "stack" => "rails",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
      "source_roots" => ["app"], "checks" => [], "services" => [], "env_names" => [],
      "toolchain" => {}, "style" => nil, "app_update" => {},
      "delivery" => { "provider" => "none" }, "account" => "Team"
    }.merge(overrides)
  end

  def capture2(*argv)
    output, status = Open3.capture2e(*argv)
    assert status.success?, "#{argv.join(' ')} failed: #{output}"
    [output, status]
  end

  def test_the_queue_s_ref_is_carried_into_the_step
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront", "ref" => "v2022.01.04" }])

    serve(corpus: corpus, cycles: 1).run

    assert_equal "https://github.com/acme/storefront.git", FakeStep.calls.first[:repository]
    assert_equal "v2022.01.04", FakeStep.calls.first[:ref],
      "the queue named a ref and the step was handed something else"
  end

  # **A flag the loop swallows is worse than no flag at all.** `--force` is documented as "walk a move
  # even though the ledger has settled it — the ledger is a memory, not a lock", and `serve` never read
  # it: measured, `serve --walk --force` printed "already settled: passed" and ran nothing, which reads
  # as a walk that finished rather than one that was skipped. The loop has no opinion of its own about
  # the ledger's answer; the step is where it is read, so the step is where the flag has to arrive.
  def test_serve_hands_the_force_flag_to_the_step
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])

    serve(repos: ["acme/storefront"], force: true).run

    assert FakeStep.calls.all? { |call| call[:force] == true },
      "the loop swallowed --force, so a settled move is skipped however the caller asks: " \
      "#{FakeStep.calls.map { |call| call[:force] }.inspect}"
  end

  # `nil` from a step means the ledger already settled that move. It is not a failure, it
  # does not stop the loop, and it is worth a line — a service that has silently lost its
  # volume is exactly a service whose every move looks already settled.
  def test_a_settled_move_is_not_a_failure_and_does_not_stop_the_loop
    FakeStep.reset!(results: [nil, nil])
    out = StringIO.new

    assert_equal 0, serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }]),
      cycles: 2, out: out).run

    assert_equal 2, FakeStep.calls.size, "the loop stopped at a settled move"
    # Counted on the words the *step* line uses, because the startup line also says
    # "already settled" — and a scan that could not tell the two apart would pass on a
    # loop that logged the count and then never walked anything at all.
    assert_equal 2, out.string.scan("nothing was run").size
  end

  # The one line that says whether the volume is still mounted. A lost `upgrader_cache`
  # resets the service to "nothing settled" while the container reports healthy, so the
  # count is read from the file on disk rather than from the process that just wrote it.
  def test_a_restart_reads_the_ledger_and_names_what_is_already_settled
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }]), cycles: 1).run

    assert File.file?(File.join(home, "ledger.json")), "the step's verdict was never persisted"

    second = StringIO.new
    serve(cycles: 1, out: second).run

    assert_includes second.string, "1 move(s) already settled"
    assert_includes second.string, "stopped after 1 cycle(s) with 1 move(s) settled"
  end

  # The healthcheck reads a file whose age is the loop's liveness. "Written at the end"
  # would be a heartbeat that stops exactly when a cycle hangs, which is the failure it
  # exists to catch, so the assertion is that a *later* cycle saw it — not merely that the
  # file exists when the process has finished.
  def test_the_heartbeat_is_written_every_cycle
    FakeStep.reset!(results: [nil, nil])
    serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }]), cycles: 2).run

    assert File.file?(File.join(home, "heartbeat"))
    assert FakeStep.calls.last[:heartbeat_seen],
      "the second cycle started with no heartbeat on disk, so a hang would be invisible"
    assert Time.iso8601(File.read(File.join(home, "heartbeat")).strip)
  end

  # One repository that cannot be cloned is not the loop's problem. The other repositories
  # still get walked, the cycle still counts, and the failure is logged with its class —
  # which is the difference between a bad minute and a service that stops for everybody.
  def test_one_repository_s_bad_minute_is_not_the_loop_s
    FakeStep.reset!(results: [Source::Failed,
                              Result.new(verdict: "passed", to_version: "5.0.0")])
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/broken" },
                                      { "repo_url" => "acme/working" }])

    assert_equal 0, serve(corpus: corpus, cycles: 1, out: out).run

    assert_equal 2, FakeStep.calls.size, "the second repository was never walked"
    assert_includes out.string, "Source::Failed"
    assert_includes out.string, "(5.0.0)"
  end

  # An operator who named repositories meant them, and the queue is what answers when
  # nobody did. Asking the service anyway would be a second opinion nobody wanted — and
  # on a deployment with no egress it would be a delay before every cycle.
  def test_the_operator_s_list_wins_over_the_service_s_queue
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    corpus = FakeCorpus.new(raises: Corpus::Unreachable.new("no route to host"))

    assert_equal 0, serve(corpus: corpus, repos: ["acme/storefront"], cycles: 1).run

    assert_empty corpus.asked, "the queue was read even though the operator named the work"
    assert_equal ["https://github.com/acme/storefront.git"],
      FakeStep.calls.map { |call| call[:repository] }.uniq
  end

  # A queue that could not be read is not an empty queue, and the loop must say which it
  # got. It also must not exit: an unreachable service is a condition to wait out, and a
  # container that stopped because its corpus had a bad minute would need an operator to
  # watch it.
  def test_a_queue_that_could_not_be_read_is_logged_and_does_not_end_the_loop
    out = StringIO.new
    corpus = FakeCorpus.new(raises: Corpus::Unreachable.new("connection refused"))

    assert_equal 0, serve(corpus: corpus, cycles: 2, out: out).run

    assert_includes out.string, "could not read the queue (connection refused)"
    assert_empty FakeStep.calls
    assert_equal 2, corpus.asked.size, "the loop gave up on the queue after one bad read"
  end

  # An empty queue and an unreachable one look identical to a client, so the loop states
  # which it is. This is the miner's log lesson (`0 pair(s)` either way) in one line.
  def test_an_empty_queue_is_stated_rather_than_inferred
    out = StringIO.new

    assert_equal 0, serve(corpus: FakeCorpus.new, cycles: 1, out: out).run

    assert_includes out.string, "the service's queue is empty"
    assert_includes out.string, "the work list comes from the service's queue"
  end

  # **A queue row without a destination is skipped, but the queue is still read.** The loop
  # must ask which repositories exist before it can know whether one of them carries its own
  # target; reading nothing would make an account-owned project invisible. What must not happen
  # is a step being handed an empty destination.
  def test_no_target_means_nothing_is_walked_and_the_queue_is_still_read
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "acme/storefront" }])

    assert_equal 0, serve(corpus: corpus, to: nil, cycles: 1, out: out).run

    assert_empty FakeStep.calls
    refute_empty corpus.asked, "the loop did not read the queue it was supposed to inspect"
    assert_includes out.string, "no target"
  end

  # **An account project supplies its own destination, with no deployment-wide target.** This is
  # the connect wizard's contract: the project's `to` is the decision, so a loop started without
  # `UPGRADER_TO` must still walk it. Before this, `walk` returned idle before `run_one` ever
  # looked at the account project.
  def test_an_account_project_walks_without_a_deployment_target
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "7.1.0")])
    corpus = FakeCorpus.new(targets: [
      { "repo_url" => "acme/account", "ref" => "main", "status" => "queued" }
    ])
    corpus.define_singleton_method(:projects) do
      { "projects" => [{
        "slug" => "account", "repo" => "acme/account", "base_ref" => "main",
        "from" => "7.0.0", "to" => "8.1.0", "stack" => "rails",
        "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" },
        "source_roots" => ["app"], "checks" => [], "services" => [], "env_names" => [],
        "toolchain" => {}, "style" => { "format" => "bundle exec rubocop -A" },
        "app_update" => {},
        "delivery" => { "provider" => "none" }, "account" => "Team"
      }] }
    end

    assert_equal 0, serve(corpus: corpus, cycles: 1, to: nil).run

    call = FakeStep.calls.first
    refute_nil call, "an account project with its own target was not walked"
    assert_equal "8.1.0", call[:to]
  end

  # The deployment's own shape, which is also the bug this test exists for. The helper
  # above defaults `repos:` to `[]`, but the CLI passes the flag's value — `nil` when
  # nobody named a repository — and a keyword default does not apply to a key that is
  # present. The loop's first line reads that list, so the container crash-looped before
  # its first cycle: 31 restarts, each one printing the same line before dying.
  def test_a_repository_list_of_nil_is_the_same_as_none_named
    out = StringIO.new

    assert_equal 0, serve(repos: nil, to: nil, cycles: 1, out: out).run

    assert_includes out.string, "the work list comes from the service's queue"
    assert_includes out.string, "no target"
  end

  # SIGTERM is a *different process's* question, so it is asked in one: a loop sleeping a
  # ten-minute interval in the test process would be woken by a trap this test installed,
  # which proves nothing about the container. The child is given a 600s interval, and the
  # signal has to be answered in seconds — the assertion is on the promptness, because
  # "eventually ends" is what a plain `sleep` does too, at the cost of a SIGKILL.
  # **`--walk` is what makes a cycle a walk rather than a rung.** Without it a loop takes one
  # step per cycle (ten minutes apart in the deployment); with it, passed rungs are chained
  # inside the cycle, up to the budget — and an empty target is read as the top of the
  # service's ladder rather than as the deliberate idle it means without the flag.
  def test_walk_chains_passed_rungs_within_a_cycle_up_to_its_budget
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "5.0.0"),
      Result.new(verdict: "passed", to_version: "5.1.0"),
      Result.new(verdict: "passed", to_version: "5.2.0")
    ])
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }],
      ladder: "8.1.0")

    assert_equal 0, serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 3).run

    assert_equal 3, FakeStep.calls.size, "three passed rungs should chain inside one cycle"
    assert_equal ["8.1.0", "8.1.0", "8.1.0"], FakeStep.calls.map { |call| call[:to] },
      "every step in the cycle moves towards the ladder's top"
    assert_equal 1, corpus.ladder_reads, "the top is asked once per cycle, not once per rung"
  end

  def test_walk_stops_chaining_when_a_rung_does_not_pass
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "5.0.0"),
      Result.new(verdict: "failed", to_version: "5.1.0")
    ])
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, rungs: 3).run

    assert_equal 2, FakeStep.calls.size, "a failed rung must not be walked past"
  end

  def test_walk_says_so_when_the_ladder_cannot_be_read_instead_of_guessing
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }],
      ladder_raises: Corpus::Unreachable.new("could not reach http://api.test: reset"))

    serve(corpus: corpus, cycles: 1, to: nil, walk: true, out: out).run

    assert_empty FakeStep.calls, "nothing may be walked without a target"
    assert_includes out.string, "the ladder could not be read"
  end

  def test_a_passed_rung_is_published_when_the_operator_asked_for_it
    FakeStep.reset!(results: [
      Result.new(verdict: "passed", to_version: "5.0.0"),
      Result.new(verdict: "passed", to_version: "5.1.0")
    ])
    FakePublish.reset!
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    serve(corpus: corpus, cycles: 1, to: "5.1.0", walk: true, publish: true, rungs: 2,
      out: out).run

    assert_equal %w[5.0.0 5.1.0], FakePublish.published.map(&:to_version)
    assert_includes out.string, "agents-fyi/upgrade-5.0.0"
    assert_includes out.string, "agents-fyi/upgrade-5.1.0"
  end

  # **A passed rung whose branch never arrived is retried as a delivery, not as a walk.** The first
  # attempt fails; the next cycle publishes the rung's recorded commit and walks nothing, because the
  # suite that passed is the evidence and re-running the step would spend it again.
  def test_an_undelivered_passed_rung_is_retried_without_walking_it_again
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    RetryPublish.reset!
    out = StringIO.new
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    serve(corpus: corpus, cycles: 2, to: "5.0.0", walk: true, publish: true, rungs: 1,
      publish_class: RetryPublish, out: out).run

    assert_equal 1, FakeStep.walked, "the rung was walked again instead of delivered"
    assert_equal 2, RetryPublish.calls.size
    assert_includes out.string, "delivery retry"
    assert_includes out.string, "pull/2"
    assert_equal "c0ffee01", RetryPublish.calls.last[:commit],
      "the retry did not carry the commit the first attempt produced"
  end

  # **A rung that passed while the loop was not publishing is a debt too, and the record is its
  # evidence.** `step` publishes only with `--publish`, so a rung walked by hand settles with no
  # delivery at all — and nothing revisits a settled rung, which is how the ohana walk reached 7.2.4
  # on top of a 7.1.6 whose branch had never been pushed. The loop delivers it from the record's own
  # last concern commit and tree, without walking anything, and writes the brief it rendered.
  def test_a_passed_rung_that_was_never_published_is_delivered_from_its_record
    FakeStep.reset!(results: [])
    FakePublish.reset!
    out = StringIO.new
    tree = track(Dir.mktmpdir)
    write_record(tree: tree, commits: %w[abc12345 def67890])
    ledger = Ledger.load(File.join(home, "ledger.json"))
    ledger.record(repo: "https://github.com/acme/storefront.git", commit: "b4se0000",
      from_version: "5.0.0", to_version: "5.1.0", verdict: "passed")

    serve(cycles: 1, to: "5.1.0", walk: true, publish: true, rungs: 1, ledger: ledger,
      out: out).run

    assert_equal 0, FakeStep.walked, "a rung that had already passed was walked again to publish it"
    assert_equal 1, FakePublish.calls.size, "the rung was left with no delivery at all"
    call = FakePublish.calls.first
    assert_equal "def67890", call[:commit],
      "the branch was not based on the last commit the record's own series names"
    refute_nil call[:record], "the recovered delivery dropped the record, and with it the brief"
    assert_equal "5.1.0", call[:to_version]
    delivery = ledger.entries.find { |entry| entry.to_version == "5.1.0" }.delivery
    assert_equal true, delivery["delivered"]
    # **The first attempt of a rung that never had one names what a retry reads.** An entry that
    # recorded only the outcome would leave the next cycle with no tree and no commit to publish.
    assert_equal true, delivery["attempted"]
    assert_equal tree, delivery["root"]
    assert_equal "run-9", delivery["run_id"]
    assert_includes out.string, "delivery: published"
  end

  # A rung with no delivery and no record cannot be published: the commit lived in the tree, and the
  # corpus keeps the patch rather than the objects. It is stated and blocked, never guessed.
  def test_a_passed_rung_with_neither_a_record_nor_a_delivery_is_stated
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.1.0")])
    FakePublish.reset!
    out = StringIO.new
    ledger = Ledger.load(File.join(home, "ledger.json"))
    ledger.record(repo: "https://github.com/acme/storefront.git", commit: "b4se0000",
      from_version: "5.0.0", to_version: "5.1.0", verdict: "passed")

    serve(cycles: 1, to: "5.1.0", walk: true, publish: true, rungs: 1, ledger: ledger,
      out: out).run

    assert_empty FakePublish.calls, "a branch was built from a patch, which has no commits to push"
    assert_includes out.string, "passed and was never published"
    assert_includes out.string, "still have an undelivered checkpoint"
  end

  # The step's record, as the step writes it: a recovered delivery reads the tree, the concern
  # series and the run the rung belongs to.
  def write_record(tree:, commits:)
    dir = File.join(home, "records")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir,
      "#{AgentsFyi::Upgrader::Record.stem("https://github.com/acme/storefront.git", "5.0.0", "5.1.0")}.json"),
      JSON.generate(
        "repository" => "https://github.com/acme/storefront.git", "worktree" => tree,
        "from_version" => "5.0.0", "to_version" => "5.1.0", "verdict" => "passed",
        "run_id" => "run-9",
        "commits" => commits.map { |commit| { "concern" => "step", "commit" => commit } }
      ))
  end

  # **The site admin reads a feed, not the ledger.** The ledger is the loop's own book and is not
  # mounted into the service; the delivery facts are written beside the progress file, where the
  # site admin's read-only mount can join them to the runs it already holds.
  def test_a_published_rung_is_written_to_the_delivery_feed
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    FakePublish.reset!
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }])

    serve(corpus: corpus, cycles: 1, to: "5.0.0", walk: true, publish: true, rungs: 1).run

    path = File.join(home, "state", "deliveries.json")
    assert File.file?(path), "the delivery feed was not written where the site admin reads it"
    entries = JSON.parse(File.read(path)).fetch("deliveries")
    entry = entries.find { |row| row["to_version"] == "5.0.0" }
    refute_nil entry
    assert_equal true, entry["delivered"]
    assert_equal "https://github.com/acme/storefront/pull/1", entry["pull_request"]
    assert_equal "9f2c1ab8", entry["commit"]
    assert_equal "run-1", entry["run_id"]
    # **The brief is rendered once by the engine**, not rebuilt by the service; the feed is where
    # the site admin reads it beside the branch and PR.
    assert_includes entry["brief"], "## What moved"
    assert_includes entry["brief"], "5.0.0 → 5.1.0"
  end

  # **A queue row finds its own declaration.** The loop is not told which project a repository is;
  # the declaration names the repository, and the join is what lets one walker serve several
  # applications. The fake step records the declaration it was handed, so the wiring is visible.
  def test_a_queue_row_carries_the_declaration_whose_repository_it_names
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    # The service's queue strips `.git`; the declaration and the ledger use the clone URL. The loop
    # must hand the step one spelling, or the ledger and the kept tree are keyed under two.
    corpus = FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront" }])
    dir = Dir.mktmpdir
    saved = ENV["UPGRADER_PROJECTS_DIR"]
    ENV["UPGRADER_PROJECTS_DIR"] = dir
    File.write(File.join(dir, "site-admin-project.json"), JSON.generate(
      "slug" => "site-admin-project", "repo" => "https://github.com/acme/storefront.git",
      "base_ref" => "agents-fyi/baseline", "from" => "4.2.11", "to" => "5.0.0",
      "suite" => { "kind" => "rspec", "command" => "bundle exec rspec" }
    ))

    serve(corpus: corpus, cycles: 1, to: "5.0.0", walk: true, rungs: 1).run

    project = FakeStep.calls.first[:project]
    refute_nil project, "the queue target did not pick up its declaration"
    assert_equal "site-admin-project", project.slug
    assert_equal "agents-fyi/baseline", FakeStep.calls.first[:ref],
      "a queue row with no ref did not start where its declaration says"
    assert_equal "https://github.com/acme/storefront.git", FakeStep.calls.first[:repository],
      "the queue's spelling and the declaration's were handed to the step as two repositories"
  ensure
    ENV["UPGRADER_PROJECTS_DIR"] = saved
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  def test_publishing_is_off_unless_asked_for
    FakeStep.reset!(results: [Result.new(verdict: "passed", to_version: "5.0.0")])
    FakePublish.reset!

    serve(corpus: FakeCorpus.new(targets: [{ "repo_url" => "https://github.com/acme/storefront.git" }]),
      cycles: 1, to: "5.0.0", walk: true, rungs: 1).run

    assert_empty FakePublish.published, "a loop that was not asked to publish must not"
  end

  def test_sigterm_is_answered_between_cycles_rather_than_slept_through
    lib = File.expand_path("../lib", __dir__)
    script = File.join(track(Dir.mktmpdir), "serve.rb")
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "agents_fyi/upgrader"

      settled = Class.new do
        def initialize(**) = nil
        def run = nil
      end

      exit AgentsFyi::Upgrader::Serve.new(
        api: "http://127.0.0.1:1", home: #{home.inspect},
        heartbeat: #{File.join(home, "heartbeat").inspect}, to: "7.1.0",
        repos: ["acme/storefront"], interval: 600, out: $stdout, step_class: settled
      ).run
    RUBY
    log = File.join(home, "serve.log")
    pid = Process.spawn(RbConfig.ruby, script, out: log, err: log)

    begin
      wait_for(File.join(home, "heartbeat"), 20)
      started = Time.now
      Process.kill("TERM", pid)
      status = Timeout.timeout(10) { Process.wait2(pid).last }

      assert_equal 0, status.exitstatus, "the loop did not stop cleanly: #{File.read(log)}"
      assert_operator Time.now - started, :<, 5,
        "a 600s interval was slept through rather than interrupted"
    rescue Timeout::Error
      Process.kill("KILL", pid)
      flunk "the loop did not answer TERM within 10s: #{File.read(log)}"
    end
  end

  def wait_for(path, seconds)
    deadline = Time.now + seconds
    sleep 0.05 until File.file?(path) || Time.now > deadline
    assert File.file?(path), "#{path} never appeared"
  end
end
