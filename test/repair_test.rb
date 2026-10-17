# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "agents_fyi/upgrader"

# The one place a model changes somebody's application.
#
# What is asserted here is the *harness* around the model rather than the model: the budget
# switch (off by default, and a number turns it on), the loop's shape (an attempt, the
# suite, another attempt), the brief (the failure and the move's own record, never "fix
# it"), the capability set (read and edit, no shell — the application runs on an era
# interpreter in a container, so a shell cannot run the thing the model reasons about), and
# the evidence (the agent's words and the files it touched, per attempt).
class RepairTest < Minitest::Test
  Repair = AgentsFyi::Upgrader::Repair

  class FakeSuite
    def initialize(ok:, output: "")
      @ok = ok
      @output = output
    end

    def ok? = @ok
    def output_tail = @output
  end

  def setup
    @dirs = []
    @root = git_app
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # A git worktree with one commit, which is the shape a step leaves behind.
  # A temporary directory this test owns, for the walker's own home (the config lives there).
  def temp_home
    dir = Dir.mktmpdir
    @dirs << dir
    dir
  end

  def git_app
    dir = Dir.mktmpdir
    @dirs << dir
    File.write(File.join(dir, "Gemfile"), %(gem "rails", "4.0.0.rc1"\n))
    quiet("git", "init", "--quiet", dir)
    commit(dir)
    dir
  end

  def commit(dir, message = "base")
    quiet("git", "-C", dir, "add", "--all")
    quiet("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", message)
  end

  def quiet(*argv)
    system(*argv, out: File::NULL, err: File::NULL)
  end

  def evidence(output: "1) Failure:\n   NoMethodError: undefined method `attr_accessible'")
    {
      repository: "https://github.com/acme/storefront", from_version: "4.0.0.rc1",
      to_version: "4.1.0", suite_command: "bundle exec rspec",
      interpreter: "ruby 2.1.10", image: "agentsfyi-upgrader-ruby-2.1:dev",
      applied: [AgentsFyi::Upgrader::Preflight::Repair.new(path: "Gemfile", line: 3,
        text: %(gem "rails", "4.0.0.rc1"), after: %(gem "rails", "4.1.0"), subject: "rails",
        note: "the pin")],
      refused: [], decisions: [], output_tail: output
    }
  end

  def budget(attempts: 2, timeout: 5, model: "opencode-go/deepseek-v4.1-flash")
    { attempts: attempts, timeout: timeout, model: model, agent: "repair", binary: "opencode" }
  end

  # An agent process that does whatever the test says and records the invocation.
  class FakeAgent
    attr_reader :calls

    def initialize(&behaviour)
      @behaviour = behaviour
      @calls = []
    end

    def call(argv, chdir:, timeout:, env:)
      @calls << { argv: argv, chdir: chdir, timeout: timeout, env: env }
      @behaviour.call(argv, chdir, @calls.length)
    end
  end

  def repair(agent:, suites:, attempts: 2, on_attempt: nil, env: {}, config_dir: nil)
    reruns = suites.dup
    Repair.new(
      root: @root, evidence: evidence, budget: budget(attempts: attempts),
      env: env, out: nil, runner: agent, config_dir: config_dir,
      rerun: -> { reruns.shift || FakeSuite.new(ok: false, output: "still red") },
      on_attempt: on_attempt
    )
  end

  # --- the switch -------------------------------------------------------------------------

  # Zero attempts is *off*, and off is the default: a step run by hand on somebody's laptop
  # must not spend model calls because a file was left in a directory. The deployment turns
  # it on with a number.
  def test_zero_attempts_means_this_process_does_not_repair
    assert_nil Repair.budget({})
    assert_nil Repair.budget({ Repair::ENV_ATTEMPTS => "" })
    assert_nil Repair.budget({ Repair::ENV_ATTEMPTS => "0" })

    turned_on = Repair.budget({ Repair::ENV_ATTEMPTS => "2" })

    assert_equal 2, turned_on[:attempts]
    assert_equal Repair::DEFAULT_TIMEOUT, turned_on[:timeout]
    assert_equal "repair", turned_on[:agent]
    assert_equal "opencode", turned_on[:binary]
  end

  def test_the_budget_reads_every_knob_and_falls_back_for_the_empty_ones
    tuned = Repair.budget({ Repair::ENV_ATTEMPTS => "3", Repair::ENV_TIMEOUT => "90",
                            Repair::ENV_MODEL => "opencode-go/x", Repair::ENV_AGENT => "fixer",
                            Repair::ENV_BINARY => "/opt/opencode" })

    assert_equal 3, tuned[:attempts]
    assert_equal 90, tuned[:timeout]
    assert_equal "opencode-go/x", tuned[:model]
    assert_equal "fixer", tuned[:agent]
    assert_equal "/opt/opencode", tuned[:binary]
  end

  # --- the capability set -----------------------------------------------------------------

  # Deny-first, and no shell. `opencode run` falls back to its `build` agent — which has a
  # shell — when the named agent is unknown, so the name is what keeps the capability out.
  def test_the_agent_may_read_and_edit_and_nothing_else
    document = Repair.document(model: "opencode-go/x")

    agent = document.fetch("agent").fetch(Repair::AGENT)
    assert_equal false, agent.fetch("tools").fetch("*")
    assert_equal true, agent.fetch("tools").fetch("edit")
    refute_includes agent.fetch("tools").keys, "bash"
    assert_equal "opencode-go/x", document.fetch("model")
    assert_equal false, document.fetch("snapshot")
  end

  # --- the loop ---------------------------------------------------------------------------

  # One attempt, the suite green afterwards: repaired, and the loop stops — a second attempt
  # after a green suite would be a second change nobody asked for.
  def test_a_successful_attempt_stops_the_loop_and_is_reported_as_repaired
    agent = FakeAgent.new do |_argv, chdir, _n|
      File.write(File.join(chdir, "config.rb"), "# fixed\n")
      [0, "I fixed the configuration.\n"]
    end
    seen = []

    result = repair(agent: agent, suites: [FakeSuite.new(ok: true)], on_attempt: seen.method(:<<)).run

    assert result.repaired, result.inspect
    assert_equal 1, result.attempts.length
    assert_equal 1, agent.calls.length
    assert_includes seen.first.changed, "config.rb"
    assert_includes result.attempts.first.output_tail, "I fixed the configuration."
    assert_includes result.to_s, "1 attempt(s), repaired"
  end

  # Two attempts, the second one green: the *second* prompt is written from the suite's new
  # failure rather than from the first one, because that is the evidence the model has.
  def test_the_second_attempt_is_briefed_with_the_new_failure
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "attempt done\n"] }
    suites = [FakeSuite.new(ok: false, output: "second failure: NameError"),
              FakeSuite.new(ok: true)]

    result = repair(agent: agent, suites: suites).run

    assert result.repaired
    assert_equal 2, result.attempts.length
    assert_includes agent.calls.first[:argv].last, "attr_accessible"
    assert_includes agent.calls.last[:argv].last, "second failure: NameError"
  end

  def test_a_run_that_keeps_failing_reports_not_repaired_and_stops_at_the_budget
    agent = FakeAgent.new do |_argv, chdir, n|
      File.write(File.join(chdir, "attempt-#{n}.rb"), "x\n")
      [0, "tried\n"]
    end

    result = repair(agent: agent, suites: [FakeSuite.new(ok: false), FakeSuite.new(ok: false)]).run

    refute result.repaired
    assert_equal 2, result.attempts.length
    assert_equal 2, agent.calls.length
    assert_includes result.to_s, "2 attempt(s), not repaired"
  end

  # An agent that cannot be started is not a model failure and must not be retried against a
  # wall: one attempt, `ran: false`, and the sentence says what is missing.
  def test_an_agent_that_could_not_be_started_stops_the_loop_with_the_reason
    agent = FakeAgent.new { |_argv, _chdir, _n| [nil, "the repair agent could not be started: no such file"] }

    result = repair(agent: agent, suites: [FakeSuite.new(ok: false)]).run

    refute result.repaired
    assert_equal 1, result.attempts.length
    assert_equal false, result.attempts.first.ran
    assert_includes result.attempts.first.output_tail, "could not be started"
    assert_equal 1, agent.calls.length
  end

  # **A timeout is a spent attempt, not a missing one.** The agent ran the whole budget and may
  # have left a patch, so the suite is re-run on it and the next attempt follows — the live
  # failure this was written from recorded a fifteen-minute attempt as "did not run" and never
  # looked at what it had changed.
  def test_an_attempt_that_times_out_is_still_measured_and_the_next_attempt_follows
    agent = FakeAgent.new do |_argv, chdir, n|
      File.write(File.join(chdir, "partial-#{n}.rb"), "x\n")
      [nil, "thinking about the failure\nthe repair agent was killed after 900s", :timed_out]
    end

    result = repair(agent: agent, suites: [FakeSuite.new(ok: false), FakeSuite.new(ok: true)]).run

    assert result.repaired, result.to_s
    assert_equal 2, result.attempts.length
    first = result.attempts.first
    assert first.ran, "an agent that ran its whole budget was recorded as never having run"
    assert first.timed_out
    assert_nil first.exit_code
    refute first.ok?, "a killed attempt is not a success"
    assert_equal ["partial-1.rb"], first.changed
    assert_includes first.output_tail, "killed after 900s"
    assert_equal 2, agent.calls.length, "a timeout must not end the loop"
  end

  # The sentence a reader gets, because "did not run" for an agent that ran fifteen minutes is
  # a lie a reviewer would believe.
  def test_a_timed_out_attempt_says_so_rather_than_claiming_it_never_ran
    out = StringIO.new
    agent = FakeAgent.new { |_argv, _chdir, _n| [nil, "the repair agent was killed after 900s", :timed_out] }

    Repair.new(
      root: @root, evidence: evidence, budget: budget(attempts: 1),
      env: {}, out: out, runner: agent, rerun: -> { FakeSuite.new(ok: false) }
    ).run

    assert_includes out.string, "timed out after"
    refute_includes out.string, "did not run"
  end

  # A process killed by something other than this deadline is still one that ran: it existed,
  # it produced output, and its edits are in the tree — so the suite measures them.
  def test_a_process_that_was_signalled_still_counts_as_having_run
    agent = FakeAgent.new { |_argv, _chdir, _n| [nil, "killed by the kernel", :ran] }

    result = repair(agent: agent, suites: [FakeSuite.new(ok: false), FakeSuite.new(ok: true)]).run

    assert result.attempts.first.ran
    refute result.attempts.first.timed_out
    assert_equal 2, result.attempts.length
  end

  # --- the brief --------------------------------------------------------------------------

  # The prompt carries the move, the suite, the move's own record and the failure's own words
  # — and the rules a model left alone gets wrong: editing the test, hand-editing the
  # lockfile, and trying to run a suite it cannot run.
  def test_the_prompt_carries_the_record_the_failure_and_the_rules
    prompt = nil
    agent = FakeAgent.new do |argv, _chdir, _n|
      prompt = argv.last
      [0, "done\n"]
    end
    edit = AgentsFyi::Upgrader::Record::Decision.new(path: "app/models/user.rb", line: 12,
      subject: "attr_accessible", reason: "move the list to the controller", kind: "removed",
      replacement: "permit(:name)", source: "4.0")
    refuter = AgentsFyi::Upgrader::Applier::Refused.new(path: "app/models/user.rb", line: 3,
      text: "  attr_accessible :name", found: "  attr_accessible :name, :email",
      reason: "the line is not the one the scan read", subject: "attr_accessible")
    complete = Repair.new(
      root: @root,
      evidence: evidence.merge(decisions: [edit], refused: [refuter]),
      budget: budget(attempts: 1), env: {}, out: nil, runner: agent,
      rerun: -> { FakeSuite.new(ok: true) }
    )

    complete.run

    assert_includes prompt, "Rails 4.0.0.rc1 -> 4.1.0"
    assert_includes prompt, "bundle exec rspec"
    assert_includes prompt, "ruby 2.1.10"
    assert_includes prompt, %(gem "rails", "4.0.0.rc1")
    assert_includes prompt, "move the list to the controller"
    assert_includes prompt, "the line is not the one the scan read"
    assert_includes prompt, "attr_accessible"
    assert_includes prompt, "Do not edit the tests"
    assert_includes prompt, "Do not hand-edit Gemfile.lock"
    assert_includes prompt, "Do not try to run it yourself"
  end

  def test_the_agent_command_names_the_agent_the_model_and_the_prompt_s_size
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }

    result = repair(agent: agent, suites: [FakeSuite.new(ok: true)]).run

    argv = agent.calls.first[:argv]
    assert_equal %w[opencode run --standalone --agent repair], argv.first(5)
    assert_equal ["--model", "opencode-go/deepseek-v4.1-flash"], argv[5, 2]
    assert_includes result.attempts.first.command, "opencode run --agent repair --model opencode-go/deepseek-v4.1-flash"
    assert_includes result.attempts.first.command, "bytes"
  end

  # **The environment the live path hands this class is `ENV`, not a Hash.** `ENV` answers
  # `[]`, `each` and `to_h` but not `merge`, and its class is `Object` — so the first live
  # repair died with `undefined method 'merge' for #<Object:0x...>`, a sentence that names
  # neither the environment nor the method's real subject. Every test here had passed a Hash;
  # this one passes what production passes.
  def test_the_agent_runs_when_the_environment_is_the_process_s_own
    script = File.join(temp_home, "agent.sh")
    seen = File.join(temp_home, "seen.txt")
    File.write(script, "#!/bin/sh\nprintf '%s' \"$OPENCODE_CONFIG\" > #{seen}\nexit 0\n")
    File.chmod(0o755, script)

    result = Repair.new(
      root: @root, evidence: evidence,
      budget: budget(attempts: 1).merge(binary: script, model: ""),
      env: ENV, out: nil, rerun: -> { FakeSuite.new(ok: true) },
      config_dir: File.join(temp_home, "repair")
    ).run

    assert result.repaired, result.inspect
    assert File.exist?(seen), "the agent did not run at all"
    assert_includes File.read(seen), "opencode.json"
  end

  # --- the config file --------------------------------------------------------------------

  # **The config is named to the agent, not left beside the application.** Measured on the
  # first live repair: written into the worktree — the harness's shape, where the run directory
  # *is* the project — opencode did not read it, because a step's working copy is a `git
  # worktree` of somebody's repository and the project root opencode resolves is the repository
  # it points at. It answered `Agent not found: "repair"` in 1.3 seconds. `OPENCODE_CONFIG`
  # names the file outright, and the file lives in this client's own home.
  def test_the_config_is_named_to_the_agent_through_the_environment
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }
    home = temp_home

    repair(agent: agent, suites: [FakeSuite.new(ok: true)], config_dir: File.join(home, "repair")).run

    env = agent.calls.first[:env]
    path = env.fetch("OPENCODE_CONFIG")
    assert_includes path, File.join(home, "repair")
    document = JSON.parse(File.read(path))
    assert document.fetch("agent").key?("repair"), "the agent is not declared in the config"
  end

  def test_no_config_file_is_left_in_the_application_s_tree
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }

    repair(agent: agent, suites: [FakeSuite.new(ok: true)], config_dir: File.join(temp_home, "repair")).run

    refute File.exist?(File.join(@root, "opencode.json")),
      "a config file written into the worktree would be in the patch and is not read there"
  end
end
