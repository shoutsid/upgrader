# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "agents/upgrader"

# The one place a model changes somebody's application.
#
# What is asserted here is the *harness* around the model rather than the model: the budget
# switch (off by default, and a number turns it on), the loop's shape (an attempt, the
# suite, another attempt), the brief (the failure and the move's own record, never "fix
# it"), the capability set (read and edit, no shell — the application runs on an era
# interpreter in a container, so a shell cannot run the thing the model reasons about), and
# the evidence (the agent's words and the files it touched, per attempt).
class RepairTest < Minitest::Test
  Repair = Agents::Upgrader::Repair

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

  def evidence(output: "1) Failure:\n   NoMethodError: undefined method `attr_accessible'",
               decisions: [], carried: 0, unapplied_rules: [])
    {
      repository: "https://github.com/acme/storefront", from_version: "4.0.0.rc1",
      to_version: "4.1.0", suite_command: "bundle exec rspec",
      interpreter: "ruby 2.1.10", image: "agents-upgrader-ruby-2.1:dev",
      applied: [Agents::Upgrader::Preflight::Repair.new(path: "Gemfile", line: 3,
        text: %(gem "rails", "4.0.0.rc1"), after: %(gem "rails", "4.1.0"), subject: "rails",
        note: "the pin")],
      refused: [], decisions: decisions, carried: carried, unapplied_rules: unapplied_rules,
      output_tail: output
    }
  end

  def budget(attempts: 2, timeout: 5, models: ["opencode-go/deepseek-v4.1-flash"])
    { attempts: attempts, timeout: timeout, models: models, agent: "repair", binary: "opencode" }
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

  def repair(agent:, suites:, attempts: 2, on_attempt: nil, env: {}, config_dir: nil, models: nil,
             home: nil)
    reruns = suites.dup
    Repair.new(
      root: @root, evidence: evidence,
      budget: (models ? budget(attempts: attempts, models: models) : budget(attempts: attempts)),
      env: env, out: nil, runner: agent, config_dir: config_dir, home: home,
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
    assert_equal ["opencode-go/x"], tuned[:models]
    assert_equal "fixer", tuned[:agent]
    assert_equal "/opt/opencode", tuned[:binary]
  end

  # **A model chain, because a free tier is what needs one.** Measured on the 6.0 rung: the free
  # variant of a model ran one attempt to the 600-second deadline and the next attempt answered
  # `Rate limit exceeded. Please try again later.` in two seconds — so the budget was spent against
  # a provider rather than against the application, and the paid sibling that answers was never
  # asked. The list is read left to right, one model per attempt, and each attempt's command in the
  # record carries the model it actually ran with.
  def test_the_budget_reads_a_model_chain_left_to_right
    chain = Repair.budget({ Repair::ENV_ATTEMPTS => "2",
                            Repair::ENV_MODEL => "opencode/deepseek-v4.1-flash-free, opencode-go/deepseek-v4.1-flash" })

    assert_equal ["opencode/deepseek-v4.1-flash-free", "opencode-go/deepseek-v4.1-flash"], chain[:models]
    assert_equal [], Repair.budget({ Repair::ENV_ATTEMPTS => "1", Repair::ENV_MODEL => "" })[:models]
  end

  def test_the_nth_attempt_runs_the_nth_model_and_the_last_one_repeats
    agent = FakeAgent.new { |_argv, _chdir, _n| [1, "boom", :ran] }
    repair = repair(agent: agent, attempts: 3, models: ["free-model", "paid-model"],
      suites: [FakeSuite.new(ok: false, output: "red"), FakeSuite.new(ok: false, output: "red")])

    result = repair.run

    ran = agent.calls.map { |call| call[:argv][call[:argv].index("--model") + 1] }
    assert_equal ["free-model", "paid-model", "paid-model"], ran,
      "the chain is per attempt and the last model carries the rest: #{agent.calls.map { |c| c[:argv] }.inspect}"
    assert(result.attempts.all? { |attempt| attempt.command.include?("--model") },
      "the record's command has to name the model each attempt ran: #{result.attempts.map(&:command).inspect}")
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

  # **The brief is the residue, not the blanket.** A change with a path and a line is a call site
  # this application has; one this rung carried without a call site is not work at all, and a brief
  # that listed both equally taught the model to hunt for sixteen things when three exist. And a
  # change this tool *has a rule for* and would not touch — a value whose end the rule cannot see —
  # is the closest thing to a starting point, so it is named rather than counted.
  def test_the_brief_carries_the_located_findings_and_what_the_rules_refused
    prompt = nil
    agent = FakeAgent.new do |argv, _chdir, _n|
      prompt = argv.last
      [0, "done\n"]
    end
    located = Agents::Upgrader::Record::Decision.new(
      path: "app/controllers/posts_controller.rb", line: 12, subject: "render :text",
      kind: "renamed", reason: "the response's content type is the application's to choose"
    )
    Repair.new(
      root: @root,
      evidence: evidence(decisions: [located], carried: 13, unapplied_rules: ["require_dependency"]),
      budget: budget(attempts: 1), env: {}, out: nil, runner: agent,
      rerun: -> { FakeSuite.new(ok: true) }
    ).run

    assert_includes prompt, "app/controllers/posts_controller.rb:12 — render :text"
    assert_includes prompt, "13 further change(s) this rung carried are not in this application"
    assert_includes prompt, "This tool has a rule for these changes"
    assert_includes prompt, "- require_dependency"
    refute_includes prompt, "render :text — ", "the located finding must carry its line"
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
    edit = Agents::Upgrader::Record::Decision.new(path: "app/models/user.rb", line: 12,
      subject: "attr_accessible", reason: "move the list to the controller", kind: "removed",
      replacement: "permit(:name)", source: "4.0")
    refuter = Agents::Upgrader::Applier::Refused.new(path: "app/models/user.rb", line: 3,
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
    assert_includes prompt, "there is no shell"
  end

  def test_the_agent_command_names_the_agent_the_model_and_the_prompt_s_size
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }

    result = repair(agent: agent, suites: [FakeSuite.new(ok: true)]).run

    argv = agent.calls.first[:argv]
    assert_equal %w[opencode run --dir], argv.first(3)
    assert_equal @root, argv[3], "the agent's directory is the worktree, not the image it runs in"
    assert_equal %w[--agent repair], argv[4, 2]
    assert_equal ["--model", "opencode-go/deepseek-v4.1-flash"], argv[6, 2]
    refute_includes argv, "--standalone",
      "the installed client answers that flag with its help text and runs no model"
    assert_includes result.attempts.first.command, "opencode run --dir #{@root} --agent repair"
    assert_includes result.attempts.first.command, "--model opencode-go/deepseek-v4.1-flash"
    assert_includes result.attempts.first.command, "bytes"
  end

  # **The agent's home is the one the container can write.** The deployment runs this image
  # with `read_only: true`; opencode's first write was `mkdir /home/upgrader/.local`, which
  # answered `EROFS: read-only file system` before any model call. The client's own home is
  # on the cache volume, so it is the home every attempt gets.
  def test_the_agent_runs_with_the_client_s_writable_home
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }

    repair(agent: agent, suites: [FakeSuite.new(ok: true)], home: "/var/lib/upgrader").run

    assert_equal "/var/lib/upgrader", agent.calls.first[:env]["HOME"]
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

  # **The model process gets an allowlist, not the walker's environment.** The walker holds the
  # corpus key and the application's suite environment; a prompt-injected repository would carry
  # both to the provider. Only what opencode needs to find its config crosses.
  def test_the_agent_environment_is_an_allowlist_rather_than_the_walker_s_own
    agent = FakeAgent.new { |_argv, _chdir, _n| [0, "done\n"] }

    repair(agent: agent, suites: [FakeSuite.new(ok: true)],
      env: { "PATH" => "/usr/bin:/bin", "AGENTS_KEY" => "afy_canary",
             "UPGRADER_SUITE_ENV" => "DATABASE_URL=postgres://secret" }).run

    env = agent.calls.first[:env]
    assert_equal "/usr/bin:/bin", env["PATH"]
    refute env.key?("AGENTS_KEY")
    refute env.key?("UPGRADER_SUITE_ENV")
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

  # **A mechanical repair is an outcome too**, so the corpus's most trustworthy evidence — a real
  # failure, a fix nobody guessed at, and a suite that went green after it — reaches the same
  # report door a model's repair does. There is no attempt to describe, so the count is one and the
  # diff is rendered from the edits: the caller checkpoints before re-running the suite, which
  # leaves `git diff` empty.
  def test_a_mechanical_repair_carries_the_failure_the_edits_and_the_suite_that_passed
    edits = [
      Agents::Upgrader::Applier::Applied.new(path: "app/views/bids/edit.html.erb", line: 5,
        text: "<%= link_to 'Show', @bid %> |",
        after: "<%= link_to 'Show', category_item_bid_path(@category, @item, @bid) %> |",
        origin: "suite-repair"),
      Agents::Upgrader::Applier::Applied.new(path: "app/views/bids/edit.html.erb", line: 6,
        text: "<%= link_to 'Back', bids_path %>",
        after: "<%= link_to 'Back', category_item_bids_path(@category, @item) %>",
        origin: "suite-repair")
    ]

    outcome = Repair.mechanical_outcome(applied: edits, failure: "1) BidsController GET #edit\n",
      suite: "bundle exec rspec")

    assert_equal "1) BidsController GET #edit\n", outcome.failure
    assert_equal "bundle exec rspec", outcome.suite
    assert_equal 1, outcome.attempts
    assert_equal ["app/views/bids/edit.html.erb"], outcome.files
    refute outcome.before_the_move
    assert_includes outcome.diff, "--- a/app/views/bids/edit.html.erb"
    assert_includes outcome.diff, "-<%= link_to 'Show', @bid %> |"
    assert_includes outcome.diff, "+<%= link_to 'Show', category_item_bid_path(@category, @item, @bid) %> |"
  end

  # A repair that wrote nothing is not a repair: there is no failure to report as resolved and no
  # file the resolution names.
  def test_no_edits_is_no_outcome
    assert_nil Repair.mechanical_outcome(applied: [], failure: "red", suite: "rspec")
  end

  # **The write-back's effects are whole files, and a path that is gone is a delete.** A diff
  # would have to be parsed back into `find`/`replace`, and a hunk's context is exactly what a
  # parser cannot see — the effect could apply to a line the repair never touched. The whole
  # file cannot: it is the tree the gate measured, or it is refused by the applier on a machine
  # where the file has moved on.
  def test_a_repair_proposal_carries_the_whole_file_and_a_deleted_path_is_a_delete
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config", "example.rb"), "VALUE = 1\n")

    effects, problem = Repair.effects_for(files: ["config/example.rb", "config/gone.rb"], root: @root)

    assert_nil problem
    assert_equal %w[file delete], effects.map { |effect| effect["kind"] }
    assert_equal %w[post post], effects.map { |effect| effect["phase"] },
      "a repair is applied after the move, not before the baseline it is meant to repair"
    assert_equal({ "path" => "config/example.rb", "content" => "VALUE = 1\n" },
      effects.first["payload"])
    assert_equal({ "path" => "config/gone.rb" }, effects.last["payload"])
  end

  # The proposal is one request, so a repair that touched more files than a body carries is said
  # rather than sent in part: a proposal missing one of its edits applies a tree nobody measured.
  def test_a_repair_with_too_many_files_is_refused_rather_than_proposed_in_part
    files = Array.new(Repair::MAX_PROPOSAL_FILES + 1) { |index| "config/file_#{index}.rb" }

    effects, problem = Repair.effects_for(files: files, root: @root)

    assert_empty effects
    assert_includes problem, Repair::MAX_PROPOSAL_FILES.to_s
  end

  # A repair names files in the application's tree. A path that climbs out of it is not a file
  # this walker can describe, and writing the effect would propose an edit outside the copy the
  # gate measured.
  def test_a_path_outside_the_working_copy_is_refused
    effects, problem = Repair.effects_for(files: ["../outside.rb"], root: @root)

    assert_empty effects
    assert_includes problem, "outside the working copy"
  end

  # **A symlink that leaves the tree is not a file the repair edited.** `expand_path` followed it,
  # so the proposal could carry the content of a file outside the worktree while the record said
  # the repair had changed one inside it.
  def test_a_symlink_out_of_the_working_copy_is_refused
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.symlink("/etc/passwd", File.join(@root, "config", "passwd"))

    effects, problem = Repair.effects_for(files: ["config/passwd"], root: @root)

    assert_empty effects
    assert_includes problem, "outside the working copy"
  end
end
