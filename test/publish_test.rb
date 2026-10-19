# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# Delivery: one branch per passed rung, and a pull request chained to the rung before it.
#
# The two halves fail differently and are driven differently. The **git** half is exercised
# against a real bare repository — a push is a push, and a fake would not prove the branch
# is there. The **API** half is a fake, because it can be: what matters is what this class
# sends (a chained base, a body built from the record, a token that never appears in
# anything it returns), and none of that needs GitHub to answer.
class PublishTest < Minitest::Test
  Publish = AgentsFyi::Upgrader::Publish
  Record = AgentsFyi::Upgrader::Record
  Command = AgentsFyi::Upgrader::Record::Command

  # A bare origin and a clone with one commit, made with an explicit initial branch so the
  # base this class computes is a fixed answer rather than whatever `git init` defaults to.
  def origin_and_clone(default_branch: "main")
    root = Dir.mktmpdir
    @dirs << root
    bare = File.join(root, "origin.git")
    clone = File.join(root, "clone")
    quiet("git", "init", "--bare", "--initial-branch=#{default_branch}", "--quiet", bare)
    quiet("git", "clone", "--quiet", bare, clone)
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n))
    commit(clone, "before")
    [bare, clone]
  end

  # Not named `run`: Minitest's runner owns that name, and a test helper that shadows it
  # fails the whole suite with "wrong number of arguments" before a single test runs. (The
  # same trap was paid for in `preflight_test.rb`.)
  def quiet(*argv)
    system(*argv, out: File::NULL, err: File::NULL)
  end

  def capture(*argv)
    Open3.capture2e(*argv)
  end

  def write(root, path, text)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def commit(root, message = "step")
    quiet("git", "-C", root, "add", "--all")
    quiet("git", "-C", root, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", message)
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def passed_record(repository:, from: "4.0.0.rc1", to: "4.1.0", verdict: "passed",
                    decisions: [], refused: [], applied: [], brief: nil)
    Record.new(
      repository: repository, commit: "abc12345", from_version: from, to_version: to,
      name: "Rails 4.1", verdict: verdict,
      why: verdict == "passed" ? "the suite was green before this step and green after it" :
        "the suite was green before this step and failed after it (exit 1)",
      interpreter: "ruby 2.1.10", image: "agentsfyi-upgrader-ruby-2.1:dev",
      machine: "ruby 2.1.10 (agentsfyi-upgrader-ruby-2.1:dev@sha256:#{"a" * 64})",
      era: "2.1", decisions: decisions, refused: refused, applied: applied, brief: brief,
      stages: [
        Command.new(stage: "baseline", command: "bundle exec rspec", ran: true, exit_code: 0,
          seconds: 42.0, output_tail: "12 examples, 0 failures"),
        Command.new(stage: "suite", command: "bundle exec rspec", ran: true, exit_code: 0,
          seconds: 45.0, output_tail: "12 examples, 0 failures")
      ]
    )
  end

  # A git surface that records what it was asked and answers from the test. `push` succeeds
  # unless the test says otherwise; `ls-remote --symref` names the default branch.
  class FakeGit
    attr_reader :calls

    def initialize(symref: "ref: refs/heads/main\tHEAD", heads: "", push: [0, ""], pushes: nil)
      @symref = symref
      @heads = heads
      # A *sequence* is how a retry is driven: the first attempt fails the way the deployment's did
      # and the second succeeds, with no network and no sleeping.
      @pushes = pushes || [push]
      @calls = []
    end

    def call(root, *argv)
      @calls << argv
      if argv.first == "push"
        status, output = @pushes.size > 1 ? @pushes.shift : @pushes.first
        [output, status.zero? ? instance_double_success : instance_double_failure]
      elsif argv.include?("--symref")
        [@symref, instance_double_success]
      elsif argv.include?("--heads")
        [@heads, instance_double_success]
      else
        ["", instance_double_success]
      end
    end

    # `git` returns a `Process::Status`; the two predicates this class asks are all a test
    # needs, and they are stated here rather than faked with a real process.
    def instance_double_success = Struct.new(:success?).new(true)
    def instance_double_failure = Struct.new(:success?).new(false)
  end

  class FakeApi
    attr_reader :calls

    def initialize(url: "https://github.com/acme/storefront/pull/7", default_branch: "main")
      @url = url
      @default_branch = default_branch
      @calls = []
    end

    def default_branch(owner:, name:)
      @calls << [:default_branch, owner, name]
      @default_branch
    end

    def pull_request(owner:, name:, head:, base:, title:, body:)
      @calls << [:pull_request, owner, name, head, base, title, body]
      @url
    end
  end

  # **An API that is briefly unreachable, which is what the network does.** It refuses the way the real
  # class does — `Refused` — and then answers with the same URL.
  class FlakyApi < FakeApi
    def initialize(failures:, **kwargs)
      super(**kwargs)
      @failures = failures
    end

    def pull_request(**arguments)
      if @failures.positive?
        @failures -= 1
        raise Publish::GitHub::Refused, "could not reach https://api.github.com: SocketError"
      end

      super
    end
  end

  # **A plain git remote is delivered to without a token.** The token exists for the API;
  # requiring it to push to an operator's own mirror would make publishing impossible for
  # the deployments that need no API at all.
  def test_a_passed_step_becomes_a_branch_on_a_plain_git_remote
    bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    record = passed_record(repository: bare)

    result = Publish.new(root: clone, repository: bare, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: record, token: "").call

    assert result.pushed, result.reason
    refute result.published?, "there is no pull request to open off github.com"
    assert_includes result.reason, "not a github.com repository"
    assert_equal "agents-fyi/upgrade-4.1.0", result.branch
    assert_equal "main", result.base

    listing, _status = capture("git", "-C", bare, "rev-parse", "refs/heads/agents-fyi/upgrade-4.1.0")
    assert_equal result.commit, listing.strip, "the branch is not the commit this step made"
    shown, _status = capture("git", "-C", bare, "show", "agents-fyi/upgrade-4.1.0:Gemfile")
    assert_includes shown, %(gem "rails", "4.1.0")
  end

  # **A retry publishes the commit the rung produced, and commits nothing.** The tree has moved on
  # since the rung passed; committing it again would publish a different fact than the one the suite
  # established, so the recorded commit is what reaches the branch.
  def test_a_delivery_retry_pushes_the_recorded_commit_without_committing_again
    bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    first = Publish.new(root: clone, repository: bare, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: passed_record(repository: bare), token: "").call
    assert first.pushed, first.reason

    # The walk moved on: the tree is at the next rung, and the retry must not use it.
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.2.0"\n))
    commit(clone, "the next rung")
    head, = capture("git", "-C", clone, "rev-parse", "HEAD")

    retried = Publish.new(root: clone, repository: bare, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: nil, token: "", commit: first.commit).call

    assert retried.pushed, retried.reason
    assert_equal first.commit, retried.commit
    branch, = capture("git", "-C", bare, "rev-parse", "refs/heads/agents-fyi/upgrade-4.1.0")
    assert_equal first.commit, branch.strip, "the branch is not the rung's recorded commit"
    now, = capture("git", "-C", clone, "rev-parse", "HEAD")
    assert_equal head.strip, now.strip, "a delivery retry made a commit"
  end

  # The chain: the second rung's request targets the first rung's branch, which is what
  # makes GitHub show one rung's worth of diff instead of the whole walk.
  def test_the_previous_rung_s_branch_is_the_base_when_the_remote_has_it
    bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    first = Publish.new(root: clone, repository: bare, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: passed_record(repository: bare), token: "").call
    assert_equal "main", first.base

    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.2.0"\n))
    second = Publish.new(root: clone, repository: bare, from_version: "4.1.0",
      to_version: "4.2.0", record: passed_record(repository: bare, from: "4.1.0", to: "4.2.0"),
      token: "").call

    assert_equal "agents-fyi/upgrade-4.1.0", second.base
    assert_equal "agents-fyi/upgrade-4.2.0", second.branch
  end

  def test_a_github_rung_is_pushed_with_a_token_and_opens_a_request
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    git = FakeGit.new
    api = FakeApi.new
    repository = "https://github.com/acme/storefront"

    result = Publish.new(root: clone, repository: repository, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: passed_record(repository: repository),
      token: "ghp_secret", git: git, api: api).call

    assert result.published?, result.reason
    assert_equal "https://github.com/acme/storefront/pull/7", result.pull_request
    assert_equal "main", result.base

    push = git.calls.find { |call| call.first == "push" }
    assert_includes push.join(" "), "x-access-token:ghp_secret@github.com/acme/storefront.git",
      "the push did not carry the token where GitHub expects it"
    _call, owner, name = api.calls.find { |call| call.first == :pull_request }
    assert_equal "acme", owner
    assert_equal "storefront", name
  end

  # **The token never comes back out.** Git's own errors quote the remote URL, and the
  # remote URL carries the token; a reason that carries it is a token in a record, and a
  # record is published beside the run.
  def test_a_push_that_fails_carries_the_reason_with_the_token_taken_out
    _bare, clone = origin_and_clone
    git = FakeGit.new(push: [1, "fatal: unable to access " \
      "'https://x-access-token:ghp_secret@github.com/acme/storefront.git/': 403"])

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_secret", git: git, api: FakeApi.new, pause: ->(_seconds) {}).call

    refute result.pushed
    assert_includes result.reason, "403"
    assert_includes result.reason, "***"
    refute_includes result.to_h.to_s, "ghp_secret"
  end

  # **A push that failed is retried, because the failure a walk actually meets is the network.**
  # Measured on the deployment: `agents-fyi/upgrade-4.1.0` pushed and opened its pull request, and the
  # next rung's push answered `fatal: unable to access … Could not resolve host: github.com` — the rung
  # *passed*, its branch was never created, and the hole is permanent because a passed move is settled
  # and never revisited. The second attempt is the whole fix.
  def test_a_push_that_failed_once_is_retried_before_the_rung_loses_its_branch
    _bare, clone = origin_and_clone
    git = FakeGit.new(pushes: [
      [1, "fatal: unable to access 'https://github.com/acme/storefront.git/': " \
          "Could not resolve host: github.com"],
      [0, ""]
    ])
    waits = []

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_token", git: git, api: FakeApi.new,
      pause: ->(seconds) { waits << seconds }).call

    assert result.pushed, "a push that failed once lost the rung's branch: #{result.reason}"
    assert_equal 2, git.calls.count { |call| call.first == "push" },
      "the push was not attempted a second time"
    assert_equal [AgentsFyi::Upgrader::Publish::PUSH_BACKOFF_SECONDS], waits
  end

  # **The request is the network too.** Measured on the clean re-run: `api.github.com` answered
  # `getaddrinfo: No address associated with hostname` once, the rung had already been pushed and was
  # settled, and 7.0.0 kept a branch with no pull request for the rest of the walk — a permanent hole,
  # because a settled rung is never revisited. The push beside it retried; this did not.
  def test_a_pull_request_that_meets_a_transient_failure_is_retried
    _bare, clone = origin_and_clone
    api = FlakyApi.new(failures: 2)
    waits = []

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_token", git: FakeGit.new, api: api,
      pause: ->(seconds) { waits << seconds }).call

    assert result.pushed, "a request that failed twice lost the rung's pull request: #{result.reason}"
    assert_equal "https://github.com/acme/storefront/pull/7", result.pull_request
    assert_equal [5, 10], waits, "the retries did not back off"
  end

  # And what a caller reads when it never succeeds is one sentence, not a resolver's backtrace.
  def test_a_pull_request_that_keeps_failing_is_a_sentence_rather_than_a_raise
    _bare, clone = origin_and_clone
    api = FlakyApi.new(failures: AgentsFyi::Upgrader::Publish::PUSH_ATTEMPTS)

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_token", git: FakeGit.new, api: api,
      pause: ->(_seconds) {}).call

    refute result.pushed
    assert_includes result.reason, "api.github.com"
    refute_includes result.reason, "\n", "the reason is a backtrace, not a sentence"
  end

  def test_a_github_repository_with_no_token_is_not_pushed_at_all
    _bare, clone = origin_and_clone

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"), token: "").call

    refute result.pushed
    assert_includes result.reason, Publish::ENV_TOKEN
  end

  # A branch is a claim that this rung works, and a record that is not `passed` has not
  # established that. The check is in this class as well as in its caller, because a caller
  # that forgets is how a failing rung gets a pull request.
  def test_a_step_that_did_not_pass_is_never_published
    _bare, clone = origin_and_clone
    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0", token: "ghp_secret", git: FakeGit.new,
      api: FakeApi.new,
      record: passed_record(repository: "https://github.com/acme/storefront", verdict: "failed")).call

    refute result.pushed
    assert_includes result.reason, "failed"
  end

  # **The body carries the decisions that were in force and links the reports it cites.** An
  # accepted decision was applied before the baseline, so it belongs to what the rung is; the
  # report links are built from the deployment's public base, not the walker's internal one.
  def test_the_request_body_carries_the_decisions_in_force_and_links_the_reports
    _bare, clone = origin_and_clone
    applied = AgentsFyi::Upgrader::Applier::Applied.new(path: "app/views/bids/index.html.erb",
      line: 16, text: "<td><%= link_to 'Show', bid %></td>", after: "",
      subject: "bids", origin: "decision:6b1f0a52-0000-4000-8000-000000000001", note: "the list's link")
    brief = AgentsFyi::Upgrader::Brief::Result.new(
      sections: [AgentsFyi::Upgrader::Brief::Section.new(key: "framework", title: "Rails 6.0",
        question: "what the corpus recorded", state: "answers",
        items: [AgentsFyi::Upgrader::Brief::Item.new(id: "r1", title: "a known failure",
          match: "signature")], total: 1)],
      asked: 1, truncated: false, unavailable: 0
    )
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "5.2.0", to_version: "6.0.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "5.2.0",
        to: "6.0.0", applied: [applied], brief: brief),
      token: "ghp_secret", git: FakeGit.new, api: api,
      report_base: "https://agents.example").call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "## Decisions in force"
    assert_includes body, "decision:6b1f0a52-0000-4000-8000-000000000001"
    assert_includes body, "app/views/bids/index.html.erb"
    assert_includes body, "[a known failure](https://agents.example/reports/r1)"
  end

  def test_the_default_branch_is_read_from_the_remote_before_the_api_is_asked
    _bare, clone = origin_and_clone
    git = FakeGit.new(symref: "ref: refs/heads/trunk\tHEAD")
    api = FakeApi.new(default_branch: "wrong-if-asked")

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_secret", git: git, api: api).call

    assert_equal "trunk", result.base
    refute(api.calls.any? { |call| call.first == :default_branch },
      "the API was asked for a branch the remote already named")
  end

  # What the reviewer reads: what moved, what established it, what a machine would not
  # decide, and what the scan refused to touch.
  def test_the_request_body_carries_the_evidence_the_decisions_and_the_refusals
    _bare, clone = origin_and_clone
    decision = Record::Decision.new(path: "app/models/user.rb", line: 12,
      subject: "attr_accessible", reason: "move the list to the controller",
      kind: "removed", replacement: "params.require(:user).permit(:name)", source: "4.0, Mass assignment")
    refusal = AgentsFyi::Upgrader::Applier::Refused.new(path: "app/models/user.rb", line: 3,
      text: "  attr_accessible :name", found: "  attr_accessible :name, :email",
      reason: "app/models/user.rb:3 is not the line the scan read, so it was not written",
      subject: "attr_accessible")
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront",
        decisions: [decision], refused: [refusal]),
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "4.0.0.rc1 → 4.1.0"
    assert_includes body, "ruby 2.1.10"
    assert_includes body, "baseline: `bundle exec rspec` — exit 0"
    assert_includes body, "suite: `bundle exec rspec` — exit 0"
    assert_includes body, "attr_accessible"
    assert_includes body, "move the list to the controller"
    assert_includes body, "is not the line the scan read"
  end
end
