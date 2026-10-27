# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# Delivery: one branch per passed rung, and a pull request chained to the rung before it.
#
# The two halves fail differently and are driven differently. The **git** half is exercised
# against a real bare repository — a push is a push, and a fake would not prove the branch
# is there. The **API** half is a fake, because it can be: what matters is what this class
# sends (a chained base, a body built from the record, a token that never appears in
# anything it returns), and none of that needs GitHub to answer.
class PublishTest < Minitest::Test
  Publish = Agents::Upgrader::Publish
  Record = Agents::Upgrader::Record
  Command = Agents::Upgrader::Record::Command

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
                    decisions: [], refused: [], applied: [], brief: nil, checks: [],
                    commits: [], app_update: nil, accepted_decisions: [], toolchain: nil,
                    repairs: [], project: nil)
    Record.new(
      repository: repository, commit: "abc12345", from_version: from, to_version: to,
      name: "Rails 4.1", verdict: verdict,
      why: verdict == "passed" ? "the suite was green before this step and green after it" :
        "the suite was green before this step and failed after it (exit 1)",
      interpreter: "ruby 2.1.10", image: "agents-upgrader-ruby-2.1:dev",
      machine: "ruby 2.1.10 (agents-upgrader-ruby-2.1:dev@sha256:#{"a" * 64})",
      era: "2.1", decisions: decisions, refused: refused, applied: applied, brief: brief,
      checks: checks, commits: commits, app_update: app_update,
      accepted_decisions: accepted_decisions, toolchain: toolchain, repairs: repairs,
      project: project,
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

    def initialize(url: "https://github.com/acme/storefront/pull/7", default_branch: "main",
                   previous: nil, stacks: {}, chain: {})
      @url = url
      @default_branch = default_branch
      # The request whose head is the lower layer's branch, and the stacks already in GitHub.
      # A fetch by a number the test did not name is no stack, which is the first-rung case.
      @previous = previous
      @stacks = stacks
      # The bases further down, keyed by the branch they are the head of. A walk that follows
      # more than one base needs more than one answer.
      @chain = chain
      @calls = []
    end

    def default_branch(owner:, name:)
      @calls << [:default_branch, owner, name]
      @default_branch
    end

    def pull_request(owner:, name:, head:, base:, title:, body:)
      @calls << [:pull_request, owner, name, head, base, title, body]
      { "html_url" => @url, "base" => base }
    end

    def settle(owner:, name:, number:, base:, title:, body:, current:)
      @calls << [:settle, owner, name, number, base, title, body, current]
      { "html_url" => @url, "base" => current }
    end

    def pull_request_for(owner:, name:, head:)
      @calls << [:pull_request_for, owner, name, head]
      @chain[head.to_s] || @previous
    end

    def stack_for(owner:, name:, pull_request:)
      @calls << [:stack_for, owner, name, pull_request]
      @stacks[pull_request.to_i]
    end

    def create_stack(owner:, name:, pull_requests:)
      @calls << [:create_stack, owner, name, pull_requests]
      { "number" => 1, "url" => "https://api.github.com/repos/#{owner}/#{name}/stacks/1" }
    end

    def add_to_stack(owner:, name:, stack_number:, pull_requests:)
      @calls << [:add_to_stack, owner, name, stack_number, pull_requests]
      { "number" => stack_number,
        "url" => "https://api.github.com/repos/#{owner}/#{name}/stacks/#{stack_number}" }
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

  # **The stack call the walk actually lost once.** GitHub answers 409 while another request is
  # modifying the stack, and a resolver that is briefly absent raises the same class.
  class FlakyStackApi < FakeApi
    def initialize(failures:, **kwargs)
      super(**kwargs)
      @failures = failures
    end

    def add_to_stack(**arguments)
      if @failures.positive?
        @failures -= 1
        raise Publish::GitHub::Refused,
          "https://api.github.com/repos/acme/storefront/stacks/42/add answered 409: Conflict"
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
    assert_equal "agents/upgrade-4.1.0", result.branch
    assert_equal "main", result.base

    listing, _status = capture("git", "-C", bare, "rev-parse", "refs/heads/agents/upgrade-4.1.0")
    assert_equal result.commit, listing.strip, "the branch is not the commit this step made"
    shown, _status = capture("git", "-C", bare, "show", "agents/upgrade-4.1.0:Gemfile")
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
    branch, = capture("git", "-C", bare, "rev-parse", "refs/heads/agents/upgrade-4.1.0")
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

    assert_equal "agents/upgrade-4.1.0", second.base
    assert_equal "agents/upgrade-4.2.0", second.branch
  end

  # **A patch checkpoint is a branch like any other, named for the exact release.** The chain is the
  # stack: 4.1.4 is based on 4.1.3, not on the minor's `.0`, because the previous checkpoint's branch
  # is the one carrying the release this run started from.
  def test_a_patch_checkpoint_is_branched_and_chained_by_its_exact_version
    bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.3"\n))
    first = Publish.new(root: clone, repository: bare, from_version: "4.1.2",
      to_version: "4.1.3", record: passed_record(repository: bare, from: "4.1.2", to: "4.1.3"),
      token: "").call
    assert first.pushed, first.reason
    assert_equal "agents/upgrade-4.1.3", first.branch

    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.4"\n))
    second = Publish.new(root: clone, repository: bare, from_version: "4.1.3",
      to_version: "4.1.4", record: passed_record(repository: bare, from: "4.1.3", to: "4.1.4"),
      token: "").call

    assert second.pushed, second.reason
    assert_equal "agents/upgrade-4.1.4", second.branch, "the patch's branch is not its exact release"
    assert_equal "agents/upgrade-4.1.3", second.base, "the patch was not chained on its predecessor"
  end

  # **The second request is the stack, not only the next branch.** GitHub's stacks API needs an
  # explicit association: two chained requests are not one until it is asked. The client opens the
  # request first — the branch and its base are the delivery — then creates the stack bottom-up
  # from the lower request's number and this one's.
  def test_the_second_rung_creates_a_github_stack_from_the_request_below_it
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.2.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.1.0")
    api = FakeApi.new(url: "#{repository}/pull/8", previous: { "number" => 7, "state" => "open" })

    result = Publish.new(root: clone, repository: repository, from_version: "4.1.0",
      to_version: "4.2.0", record: passed_record(repository: repository, from: "4.1.0", to: "4.2.0"),
      token: "ghp_secret", git: git, api: api).call

    assert result.published?, result.reason
    assert_equal "https://api.github.com/repos/acme/storefront/stacks/1", result.stack
    create = api.calls.find { |call| call.first == :create_stack }
    assert_equal [7, 8], create&.at(3), "the stack was not created bottom-up from the request below"
  end

  # **A first request is the bottom of the stack, whatever else has its base as a head.** The
  # base filter is GitHub's, not this walker's, so an unrelated request from the default branch
  # must not become the layer below this one.
  def test_a_first_request_is_not_stacked_on_a_request_that_merely_shares_its_base
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    repository = "https://github.com/acme/storefront"
    api = FakeApi.new(url: "#{repository}/pull/7", previous: { "number" => 3 })

    result = Publish.new(root: clone, repository: repository, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: passed_record(repository: repository),
      token: "ghp_secret", git: FakeGit.new, api: api).call

    assert result.published?, result.reason
    assert_empty result.stack.to_s
    stack_calls = api.calls.select do |call|
      %i[pull_request_for stack_for create_stack add_to_stack].include?(call.first)
    end
    assert_empty stack_calls, "a first request looked below itself for a stack"
  end

  # A third rung is already below a stack; it is appended to that stack rather than starting a
  # second one, which is what keeps the map one chain rather than several pairs.
  def test_a_later_rung_is_appended_to_the_stack_it_sits_on
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.3.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.2.0")
    api = FakeApi.new(url: "#{repository}/pull/9", previous: { "number" => 8 },
      stacks: { 8 => { "number" => 42,
        "url" => "https://api.github.com/repos/acme/storefront/stacks/42" } })

    result = Publish.new(root: clone, repository: repository, from_version: "4.2.0",
      to_version: "4.3.0", record: passed_record(repository: repository, from: "4.2.0", to: "4.3.0"),
      token: "ghp_secret", git: git, api: api).call

    assert result.published?, result.reason
    assert_equal "https://api.github.com/repos/acme/storefront/stacks/42", result.stack
    add = api.calls.find { |call| call.first == :add_to_stack }
    assert_equal [42, [9]], add && [add[3], add[4]], "the rung was not appended to its stack"
  end

  # **One refused link used to cost the walk its stack for good.** Measured on diaspora: the
  # 8.0.5.1 layer's association was refused once, so 8.1.4 found a loose request below it and
  # created a second stack from the pair — 7.0.10/7.1.6/7.2.4 in stack 11 and 8.0.5.1/8.1.4 in
  # stack 15. The walk follows the bases past the loose layer to the first stacked one and appends
  # both layers in one call.
  def test_a_rung_rejoins_the_chain_when_the_one_below_it_was_never_stacked
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "8.1.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-8.0.0")
    api = FakeApi.new(url: "#{repository}/pull/14",
      previous: { "number" => 13, "state" => "open",
                  "base" => { "ref" => "agents/upgrade-7.2.0" } },
      chain: { "agents/upgrade-7.2.0" => { "number" => 12, "state" => "open",
        "base" => { "ref" => "agents/upgrade-7.1.0" } } },
      stacks: { 12 => { "number" => 11,
        "url" => "https://api.github.com/repos/acme/storefront/stacks/11" } })

    result = Publish.new(root: clone, repository: repository, from_version: "8.0.0",
      to_version: "8.1.0", record: passed_record(repository: repository, from: "8.0.0", to: "8.1.0"),
      token: "ghp_secret", git: git, api: api).call

    assert result.published?, result.reason
    assert_equal "https://api.github.com/repos/acme/storefront/stacks/11", result.stack
    add = api.calls.find { |call| call.first == :add_to_stack }
    assert_equal [11, [13, 14]], add && [add[3], add[4]],
      "the loose layer was not carried into the stack with this one: #{api.calls.inspect}"
    assert_empty api.calls.select { |call| call.first == :create_stack },
      "a second stack was created beside the one that already held the chain"
  end

  # And when no layer of the chain is stacked, the whole chain becomes one stack rather than the
  # pair at the top of it — the same failure in the other direction.
  def test_a_chain_of_unstacked_rungs_becomes_one_stack_from_its_bottom
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.3.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.2.0")
    api = FakeApi.new(url: "#{repository}/pull/9",
      previous: { "number" => 8, "state" => "open",
                  "base" => { "ref" => "agents/upgrade-4.1.0" } },
      chain: {
        "agents/upgrade-4.1.0" => { "number" => 7, "state" => "open",
          "base" => { "ref" => "agents/upgrade-4.0.0" } },
        "agents/upgrade-4.0.0" => { "number" => 6, "state" => "open",
          "base" => { "ref" => "main" } }
      })

    result = Publish.new(root: clone, repository: repository, from_version: "4.2.0",
      to_version: "4.3.0", record: passed_record(repository: repository, from: "4.2.0", to: "4.3.0"),
      token: "ghp_secret", git: git, api: api).call

    assert result.published?, result.reason
    create = api.calls.find { |call| call.first == :create_stack }
    assert_equal [6, 7, 8, 9], create&.at(3),
      "the stack was not created from the bottom of the chain: #{api.calls.inspect}"
  end

  # **A stack call is a network call, and the failure measured here was transient.** The refused
  # association is retried, and the retry re-reads first so a refusal *after* a successful write
  # cannot create the duplicate this exists to prevent.
  def test_a_refused_stack_link_is_retried
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.3.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.2.0")
    api = FlakyStackApi.new(failures: 1, url: "#{repository}/pull/9",
      previous: { "number" => 8, "state" => "open" },
      stacks: { 8 => { "number" => 42,
        "url" => "https://api.github.com/repos/acme/storefront/stacks/42" } })

    result = Publish.new(root: clone, repository: repository, from_version: "4.2.0",
      to_version: "4.3.0", record: passed_record(repository: repository, from: "4.2.0", to: "4.3.0"),
      token: "ghp_secret", git: git, api: api, pause: ->(_seconds) {}).call

    assert_equal "https://api.github.com/repos/acme/storefront/stacks/42", result.stack
    adds = api.calls.select { |call| call.first == :add_to_stack }
    assert_equal 1, adds.size, "the retry appended the layer twice: #{api.calls.inspect}"
  end

  # A retry updates a request that is already in a stack; asking again would either duplicate the
  # association or append the same layer twice.
  def test_a_request_already_in_a_stack_is_left_where_it_is
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.2.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.1.0")
    api = FakeApi.new(url: "#{repository}/pull/8", previous: { "number" => 7 },
      stacks: { 8 => { "number" => 42,
        "url" => "https://api.github.com/repos/acme/storefront/stacks/42" } })

    result = Publish.new(root: clone, repository: repository, from_version: "4.1.0",
      to_version: "4.2.0", record: passed_record(repository: repository, from: "4.1.0", to: "4.2.0"),
      token: "ghp_secret", git: git, api: api).call

    assert_equal "https://api.github.com/repos/acme/storefront/stacks/42", result.stack
    assert_empty api.calls.select { |call| %i[create_stack add_to_stack].include?(call.first) },
      "an existing stack was created or extended again"
  end

  # **The declaration may say no to the chain.** With `delivery.chain` false every request targets
  # the declared starting ref, and no stack is looked for — a project reviewing one cumulative
  # branch should not get a stack it never asked for.
  def test_a_project_can_turn_the_chain_off
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.2.0"\n))
    repository = "https://github.com/acme/storefront"
    git = FakeGit.new(heads: "abc\trefs/heads/agents/upgrade-4.1.0")
    api = FakeApi.new(url: "#{repository}/pull/8")

    result = Publish.new(root: clone, repository: repository, from_version: "4.1.0",
      to_version: "4.2.0", record: passed_record(repository: repository, from: "4.1.0", to: "4.2.0"),
      token: "ghp_secret", git: git, api: api, base_ref: "agents/baseline", chain: false).call

    assert_equal "agents/baseline", result.base
    assert_empty api.calls.select { |call| call.first == :pull_request_for },
      "a non-chained request still looked for a lower layer"
    assert_empty result.stack.to_s
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
  # Measured on the deployment: `agents/upgrade-4.1.0` pushed and opened its pull request, and the
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
    assert_equal [Agents::Upgrader::Publish::PUSH_BACKOFF_SECONDS], waits
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
    api = FlakyApi.new(failures: Agents::Upgrader::Publish::PUSH_ATTEMPTS)

    result = Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront"),
      token: "ghp_token", git: FakeGit.new, api: api,
      pause: ->(_seconds) {}).call

    refute result.pushed
    refute_nil result.commit, "the retry lost the commit the push produced"
    refute_nil result.base, "the retry lost the base the branch was pushed against"
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
    applied = Agents::Upgrader::Applier::Applied.new(path: "app/views/bids/index.html.erb",
      line: 16, text: "<td><%= link_to 'Show', bid %></td>", after: "",
      subject: "bids", origin: "decision:6b1f0a52-0000-4000-8000-000000000001", note: "the list's link")
    brief = Agents::Upgrader::Brief::Result.new(
      sections: [Agents::Upgrader::Brief::Section.new(key: "framework", title: "Rails 6.0",
        question: "what the corpus recorded", state: "answers",
        items: [Agents::Upgrader::Brief::Item.new(id: "r1", title: "a known failure",
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
    assert_includes body, "[a known failure](https://agents.example/api/reports/r1)"
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
    refusal = Agents::Upgrader::Applier::Refused.new(path: "app/models/user.rb", line: 3,
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

  # **The body is a summary, not a diff pasted into prose.** A rung a gem's own upgrade touched a
  # hundred times produced a hundred bullets; the diff is the record, and the body groups the edits
  # by origin instead of listing each one.
  def test_the_body_summarises_applied_edits_instead_of_listing_every_one
    _bare, clone = origin_and_clone
    applied = [
      Agents::Upgrader::Applier::Applied.new(path: "app/models/x.rb", line: 1,
        text: "old", after: "new", origin: "decision:d1"),
      Agents::Upgrader::Applier::Applied.new(path: "app/models/y.rb", line: 2,
        text: "old", after: "new", origin: "companion"),
      Agents::Upgrader::Applier::Applied.new(path: "app/models/z.rb", line: 3,
        text: "old", after: "new", origin: "companion")
    ]
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "5.2.0", to_version: "6.0.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "5.2.0",
        to: "6.0.0", applied: applied),
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "The tool wrote 3 edit(s): 1 from an accepted decision, 2 from gems' own upgrades"
    refute_includes body, "- `app/models/y.rb`:2", "the body listed an edit the diff already carries"
  end

  # **A file a decision wrote is a whole file, and a whole file is not an inline code span.** The
  # 8.0.5.1 request pasted nine vendored files into the body; a backtick in the content closed the
  # span, a newline ended it, and the rest of the section was unreadable markdown. The diff is
  # where content belongs, so the body names the file and its size instead.
  def test_the_body_names_a_written_file_instead_of_pasting_its_contents
    _bare, clone = origin_and_clone
    applied = [
      Agents::Upgrader::Applier::Applied.new(path: "vendor/gems/x/lib/x.rb", line: 1,
        text: "", after: "module X\n  VALUE = `ls`\nend\n", origin: "decision:d1"),
      Agents::Upgrader::Applier::Applied.new(path: "Gemfile", line: 4,
        text: %(gem "x", "1.0"), after: %(gem "x", "2.0"), origin: "decision:d1")
    ]
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "5.2.0", to_version: "6.0.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "5.2.0",
        to: "6.0.0", applied: applied,
        accepted_decisions: [{ "id" => "d1", "question" => "Vendor the gem?",
          "answer" => "vendor it", "accepted_by" => "operator:1",
          "effects" => [{ "kind" => "file",
            "payload" => { "path" => "vendor/gems/x/lib/x.rb",
                           "content" => "module X\n  VALUE = `ls`\nend\n" } }] }],
        project: { "slug" => "storefront", "decisions" => [{ "id" => "d1",
          "question" => "Vendor the gem?", "effects" => [{ "kind" => "file",
            "payload" => { "path" => "vendor/gems/x/lib/x.rb",
                           "content" => "module Y\n  OTHER = 1\nend\n" } }] }] }),
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "`vendor/gems/x/lib/x.rb` — added by the decision (3 line(s))"
    refute_includes body, "module X", "the body pasted a file the diff already carries"
    refute_includes body, "VALUE = `ls`", "the body pasted a backtick from the file's own content"
    refute_includes body, "module Y", "the project declaration's copy of the decision pasted the file"
    assert_includes body, %(`Gemfile`:4 `gem "x", "1.0"` → `gem "x", "2.0"`),
      "a one-line edit still reads as the line it changed: #{body[/The edits these decisions.*/m][0, 400]}"
  end

  # **A public body must not carry the application's secret.** The recorded command is the docker
  # wrapper with `-e RAILS_SECRET_TOKEN=…`; the body prints what the step was asked to do.
  def test_the_body_prints_the_logical_command_not_the_secret_in_the_wrapper
    _bare, clone = origin_and_clone
    record = passed_record(repository: "https://github.com/acme/storefront")
    stage = record.stages.find { |item| item.stage == "suite" }
    stage.command = "docker exec -e RAILS_SECRET_TOKEN=super-secret bundle exec rspec"
    stage.display = "bundle exec rspec"
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record,
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "suite: `bundle exec rspec`"
    refute_includes body, "super-secret"
  end

  # **An old record without a `display` still cannot put the suite's environment in a public body.**
  # The wrapper's `-e KEY=VALUE` pairs are redacted, because the secret is in the command string and
  # a pull request is public.
  def test_the_body_redacts_an_old_record_s_environment
    _bare, clone = origin_and_clone
    record = passed_record(repository: "https://github.com/acme/storefront")
    record.stages.last.command =
      "docker exec --interactive -e RAILS_SECRET_TOKEN=super-secret bundle exec rspec"
    record.stages.last.display = nil
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record,
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    refute_includes body, "super-secret"
    assert_includes body, "RAILS_SECRET_TOKEN=***"
  end

  # **A check's output and a repair's output are command output too.** The body's `checks` and
  # `repairs` sections are part of the run record, and a failing suite's tail is exactly where the
  # application's environment shows up; the full record in the body must not carry either.
  def test_the_body_omits_check_and_repair_output_from_the_collapsed_record
    _bare, clone = origin_and_clone
    check = Agents::Upgrader::Checks::Result.new(id: "lint", kind: "lint",
      command: "bundle exec rubocop", required: true, external: false, status: "passed",
      ran: true, exit_code: 0, seconds: 1.0, output_tail: "SECRET_TOKEN=check-secret")
    attempt = Agents::Upgrader::Repair::Attempt.new(number: 1, command: "opencode", ran: true,
      timed_out: false, exit_code: 0, seconds: 1.0, output_tail: "SECRET_TOKEN=repair-secret",
      changed: ["app/models/item.rb"])
    repair = Agents::Upgrader::Repair::Outcome.new(failure: "FAILURE_SECRET=failure-secret",
      suite: "bundle exec rspec", attempts: [attempt], files: ["app/models/item.rb"],
      diff: "SECRET DIFF", before_the_move: false)
    counted = Agents::Upgrader::Repair::Outcome.new(failure: "another failure",
      suite: "bundle exec rspec", attempts: 1, files: ["app/models/item.rb"],
      diff: "ANOTHER SECRET DIFF", before_the_move: false)
    record = passed_record(repository: "https://github.com/acme/storefront",
      checks: [check], repairs: [repair, counted])
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record,
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    refute_includes body, "check-secret"
    refute_includes body, "repair-secret"
    refute_includes body, "failure-secret"
    refute_includes body, "SECRET DIFF"
    refute_includes body, "ANOTHER SECRET DIFF"
    assert_includes body, "\"attempts\": 1",
      "the repair's attempt count is not command output and should survive"
    assert_includes body, "app/models/item.rb",
      "the repair's files are the part a reviewer needs and were dropped with its output"
  end

  # **The carried guide entries are not work.** The body lists the call site this application has and
  # names the count of changes the rung carries that it does not use; a page of guide entries is a
  # page a reviewer learns to skip.
  def test_the_body_splits_located_manual_changes_from_carried_ones
    _bare, clone = origin_and_clone
    located = Record::Decision.new(path: "app/views/x.html.erb", line: 4, subject: "button_to",
      reason: "the call site this application has")
    carried = Record::Decision.new(subject: "schema.rb column order",
      reason: "the guide carries this, the application does not use it")
    earlier = Record::Decision.new(path: "app/models/bid.rb", line: 2, subject: "belongs_to",
      reason: "carried by an earlier rung — the one that arrives at 5.0.0, which this " \
              "application has not crossed")
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "5.2.0", to_version: "6.0.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "5.2.0",
        to: "6.0.0", decisions: [located, carried, earlier]),
      token: "ghp_secret", git: FakeGit.new, api: api).call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "## Manual changes found in this application"
    assert_includes body, "app/views/x.html.erb:4"
    assert_includes body, "## Manual changes the rung carries"
    assert_includes body, "1 change(s) this rung documents that this application does not use"
    work = body.split("## Manual changes the rung carries").first
    refute_includes work, "schema.rb column order", "a carried change was listed as work"
    assert_includes body, "## Earlier-rung call sites"
    work = body.split("## Earlier-rung call sites").first
    refute_includes work, "app/models/bid.rb:2",
      "a call site an earlier rung located was listed as this rung's work"
  end

  # **The request is a review brief, not a run log.** A reviewer can answer "what changed, what
  # established it, what did the tool decide, what is left, is it safe" without reconstructing the
  # walk — and the full record is there, collapsed, for the reader who wants the evidence.
  def test_the_body_renders_the_checks_the_commits_the_decisions_and_the_update
    _bare, clone = origin_and_clone
    external = Agents::Upgrader::Checks::Result.new(id: "ci", name: "GitHub Actions",
      kind: "external", required: true, external: true, status: "external", ran: false,
      reason: "the application's CI test job")
    lint = Agents::Upgrader::Checks::Result.new(id: "lint", kind: "lint",
      command: "bundle exec rubocop", required: true, external: false, status: "passed",
      ran: true, exit_code: 0, seconds: 1.0)
    record = passed_record(repository: "https://github.com/acme/storefront",
      from: "5.2.0", to: "6.0.0", checks: [lint, external],
      commits: [
        { "concern" => "pin Rails and move gems", "commit" => "b" * 40,
          "message" => "agents upgrader: the 5.2.0 -> 6.0.0 step — pin Rails and move gems" },
        { "concern" => "run app:update", "commit" => "c" * 40,
          "message" => "agents upgrader: the 5.2.0 -> 6.0.0 step — run app:update" }
      ],
      app_update: { "adopt" => "added_only", "adopted" => ["config/initializers/new.rb"],
                    "conflicts" => ["config/application.rb"],
                    "skipped" => [{ "path" => "config/storage.yml",
                                    "reason" => "the project's app_update policy skips it" }],
                    "framework_defaults" => "off", "load_defaults" => "5.2" },
      accepted_decisions: [{ "id" => "d1", "question" => "Remove the Show link?",
                             "answer" => "remove it", "accepted_by" => "operator:9f2c",
                             "effects" => [{ "kind" => "patch" }] }],
      toolchain: { "ruby" => "3.3.12", "postgres" => "pgvector/pgvector:pg16",
                   "extensions" => ["pgvector"] })
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "5.2.0", to_version: "6.0.0", record: record,
      token: "ghp_secret", git: FakeGit.new, api: api,
      report_base: "https://agents.example").call

    body = api.calls.find { |call| call.first == :pull_request }[6]
    assert_includes body, "## Checks"
    assert_includes body, "external — not run here"
    assert_includes body, "does not report them as green"
    assert_includes body, "## What changed"
    assert_includes body, "pin Rails and move gems"
    assert_includes body, "## Decisions in force"
    assert_includes body, "Remove the Show link?"
    assert_includes body, "## app:update"
    assert_includes body, "config/storage.yml"
    assert_includes body, "Declared toolchain"
    assert_includes body, "not the declared Ruby"
    assert_includes body, "PostgreSQL"
    assert_includes body, "## Review and merge"
    assert_includes body, "<details>"
    assert_includes body, "Full run record"
    # **A reviewer reads the record here.** The site admin is the operator's console, not a
    # destination a pull request may send someone to; the body is self-contained.
    refute_includes body, "/site_admin",
      "the pull request body linked the operator-only run console"
  end

  # **A transient remote failure must not move a rung's base to the default branch.** The chain is
  # the previous rung's branch; the `ls-remote` that finds it is the network too.
  class FlakyHeadsGit < FakeGit
    def initialize(heads:, failures: 1, **kwargs)
      super(heads: heads, **kwargs)
      @failures = failures
    end

    def call(root, *argv)
      if argv.include?("--heads") && @failures.positive?
        @failures -= 1
        @calls << argv
        return ["", instance_double_failure]
      end

      super
    end
  end

  def test_a_transient_remote_failure_does_not_move_the_base_to_master
    _bare, clone = origin_and_clone
    git = FlakyHeadsGit.new(heads: "refs/heads/agents/upgrade-4.0.0\n")
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "4.0.0",
        to: "4.1.0"),
      token: "ghp_secret", git: git, api: api, pause: ->(_seconds) {}).call

    call = api.calls.find { |entry| entry.first == :pull_request }
    assert_equal "agents/upgrade-4.0.0", call[4],
      "the base fell back to the default branch on a failed ls-remote"
  end

  # **The first rung is based on the walk's starting ref, not the repository's default.** A project
  # declares `base_ref`; with no previous rung's branch to chain to, the default branch is not the
  # parent — the lighthouse's baseline carries its own view fixes, and basing the 4.1 request on
  # `master` put them in the 4.1 diff.
  class BaseRefGit < FakeGit
    def call(root, *argv)
      if argv.include?("--heads")
        @calls << argv
        candidate = argv.last
        return [candidate == "agents/baseline" ? "refs/heads/agents/baseline\n" : "",
          instance_double_success]
      end

      super
    end
  end

  def test_the_first_rung_targets_the_declaration_s_starting_ref
    _bare, clone = origin_and_clone
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.0.0", to_version: "4.1.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "4.0.0",
        to: "4.1.0"),
      token: "ghp_secret", git: BaseRefGit.new, api: api,
      base_ref: "agents/baseline").call

    call = api.calls.find { |entry| entry.first == :pull_request }
    assert_equal "agents/baseline", call[4],
      "the first rung fell back to the repository default instead of the walk's starting ref"
  end

  # A later rung still chains to its own previous rung even when a starting ref is declared.
  class ChainGit < FakeGit
    def initialize(branches:, **kwargs)
      super(**kwargs)
      @branches = branches
    end

    def call(root, *argv)
      if argv.include?("--heads")
        @calls << argv
        candidate = argv.last
        return [@branches.include?(candidate) ? "refs/heads/#{candidate}\n" : "",
          instance_double_success]
      end

      super
    end
  end

  def test_a_later_rung_chains_to_the_previous_rung_not_the_starting_ref
    _bare, clone = origin_and_clone
    git = ChainGit.new(branches: %w[agents/upgrade-4.1.0 agents/baseline])
    api = FakeApi.new

    Publish.new(root: clone, repository: "https://github.com/acme/storefront",
      from_version: "4.1.0", to_version: "4.2.0",
      record: passed_record(repository: "https://github.com/acme/storefront", from: "4.1.0",
        to: "4.2.0"),
      token: "ghp_secret", git: git, api: api, base_ref: "agents/baseline").call

    call = api.calls.find { |entry| entry.first == :pull_request }
    assert_equal "agents/upgrade-4.1.0", call[4],
      "a later rung was based on the starting ref instead of the previous rung"
  end

  # **`publish: branch` is a handoff without a request.** The branch is still a claim that the rung
  # works, and the account's CI can run on it; only the pull request is absent.
  def test_branch_only_publishes_without_opening_a_pull_request
    _bare, clone = origin_and_clone
    write(clone, "Gemfile", %(source "https://rubygems.org"\ngem "rails", "4.1.0"\n))
    repository = "https://github.com/acme/storefront"
    api = FakeApi.new

    result = Publish.new(root: clone, repository: repository, from_version: "4.0.0.rc1",
      to_version: "4.1.0", record: passed_record(repository: repository),
      token: "ghp_secret", git: FakeGit.new, api: api).call(open_pr: false)

    assert result.pushed, result.reason
    assert_nil result.pull_request
    assert_empty api.calls.select { |call| call.first == :pull_request },
      "branch-only publishing opened a pull request"
  end

  def test_the_body_names_a_policy_accepted_decision_and_what_to_canary
    applied = Agents::Upgrader::Applier::Applied.new(
      path: "app/controllers/users_controller.rb", line: 4, text: "before_filter :x",
      after: "before_action :x", subject: "before_filter", origin: "decision:q1"
    )
    record = passed_record(repository: "https://github.com/acme/storefront", applied: [applied],
      accepted_decisions: [{
        "id" => "q1", "question" => "Which filter?", "answer" => "rename it",
        "accepted_by" => "policy:auto", "accepted_by_policy" => true,
        "risk_class" => "medium",
        "review" => { "verdict" => "safe", "agent" => "reviewer", "model" => "test/model" },
        "effects" => [{ "kind" => "patch", "payload" => { "path" => applied.path } }]
      }])
    text = Publish.new(root: "/tmp", repository: record.repository,
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record).preview_body

    assert_includes text, "Accepted by the account's policy"
    assert_includes text, "reviewer/test/model"
    assert_includes text, "What to canary"
    assert_includes text, "HTTP endpoints"
    assert_includes text, "Your CI, deploy and canary are the release gate"
  end

  def test_the_model_lead_is_prepended_and_the_record_stays_below_it
    record = passed_record(repository: "https://github.com/acme/storefront")
    text = Publish.new(root: "/tmp", repository: record.repository,
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record,
      editorial: "## Summary\n\nThe serialize call is the one change to review.").preview_body

    assert text.start_with?("## Summary")
    assert_includes text, "The serialize call is the one change to review."
    assert_includes text, "## What moved"
    assert_includes text, "## Checks"
  end

  def test_a_body_only_update_refuses_to_overwrite_a_person_s_edit
    record = passed_record(repository: "https://github.com/acme/storefront")
    api = FakeApi.new(previous: {
      "number" => 7, "html_url" => "https://github.com/acme/storefront/pull/7",
      "body" => "a person edited this", "title" => "Keep this title",
      "base" => { "ref" => "main" }
    })
    publisher = Publish.new(root: "/tmp", repository: record.repository,
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record, commit: "abc12345",
      token: "ghp_secret", api: api, editorial: "## Summary\n\nThe lead.",
      expected_body_digest: Digest::SHA256.hexdigest("the body the walker wrote"), base: "main")

    result = publisher.update_only

    refute result.body_updated?
    assert_includes result.reason, "edited"
    assert_empty api.calls.select { |call| call.first == :settle }
  end

  def test_a_body_only_update_patches_the_existing_request_when_the_body_is_still_ours
    record = passed_record(repository: "https://github.com/acme/storefront")
    api = FakeApi.new(previous: {
      "number" => 7, "html_url" => "https://github.com/acme/storefront/pull/7",
      "body" => "the body the walker wrote", "title" => "Keep this title",
      "base" => { "ref" => "main" }
    })
    publisher = Publish.new(root: "/tmp", repository: record.repository,
      from_version: "4.0.0.rc1", to_version: "4.1.0", record: record, commit: "abc12345",
      token: "ghp_secret", api: api, editorial: "## Summary\n\nThe lead.",
      expected_body_digest: Digest::SHA256.hexdigest("the body the walker wrote"), base: "main")

    result = publisher.update_only

    assert result.body_updated?
    settle = api.calls.find { |call| call.first == :settle }
    assert_equal "Keep this title", settle[5]
    assert_includes settle[6], "## Summary"
    assert_includes settle[6], "## What moved"
  end
end

# **An open pull request for the rung is edited, not duplicated.** The GitHub class is driven through
# its injectable HTTP so the two calls are visible: a GET that finds the open request by head branch,
# then a PATCH that replaces its title, body and base. Only a rung with no open request creates one.
class PublishExistingPrTest < Minitest::Test
  Publish = Agents::Upgrader::Publish

  Response = Struct.new(:code, :body, keyword_init: true)

  # A transport that answers a scripted sequence and records what it was asked.
  class ScriptedHttp
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def start(_host, _port, use_ssl:)
      yield self
    end

    def request(request)
      @requests << [request.method, request.path, request.body]
      @responses.shift || Response.new(code: "500", body: "{}")
    end
  end

  def test_an_existing_open_request_is_updated_rather_than_opened_again
    http = ScriptedHttp.new([
      Response.new(code: "200", body: JSON.generate([{ "number" => 7,
        "base" => { "ref" => "main" } }])),
      Response.new(code: "200", body: JSON.generate({ "html_url" => "https://github.com/acme/storefront/pull/7",
        "base" => { "ref" => "main" } }))
    ])
    api = Publish::GitHub.new(token: "ghp_test", http: http)

    result = api.pull_request(owner: "acme", name: "storefront", head: "agents/upgrade-4.1.0",
      base: "main", title: "Upgrade Rails to 4.1.0 (agents)", body: "the rung")

    assert_equal "https://github.com/acme/storefront/pull/7", result["html_url"]
    assert_equal "main", result["base"]
    assert_equal %w[GET PATCH], http.requests.map(&:first)
    assert_includes http.requests.first[1], "/repos/acme/storefront/pulls"
    assert_includes http.requests.first[1], "head=acme%3Aagents%2Fupgrade-4.1.0"
    assert_equal "/repos/acme/storefront/pulls/7", http.requests.last[1]
    assert_includes http.requests.last[2], "the rung"
    # **A base that is not moving is not sent.** A stacked request refuses the field outright, so
    # repeating the base it already has is what made a republish fail with 422.
    refute JSON.parse(http.requests.last[2]).key?("base"),
      "the unchanged base was sent and a stacked request would refuse the update"
  end

  # **And when the base is really moving, the stack wins and the caller learns which base it got.**
  def test_a_stacked_request_keeps_its_base_when_the_patch_names_another
    http = ScriptedHttp.new([
      Response.new(code: "200", body: JSON.generate([{ "number" => 13,
        "base" => { "ref" => "agents/upgrade-7.2.4" } }])),
      Response.new(code: "422", body: JSON.generate({ "message" => "Validation Failed",
        "errors" => [{ "message" => "Cannot change the base branch because the pull request is part of a stack." }] })),
      Response.new(code: "200", body: JSON.generate({ "html_url" => "https://github.com/acme/storefront/pull/13",
        "base" => { "ref" => "agents/upgrade-7.2.4" } }))
    ])
    api = Publish::GitHub.new(token: "ghp_test", http: http)

    result = api.pull_request(owner: "acme", name: "storefront", head: "agents/upgrade-8.0.5.1",
      base: "develop", title: "Upgrade Rails to 8.0.5.1 (agents)", body: "the rung")

    assert_equal "agents/upgrade-7.2.4", result["base"],
      "the caller recorded a base the request does not sit on"
    patches = http.requests.select { |request| request.first == "PATCH" }
    assert_equal 2, patches.size, "the refused update was not retried without the base"
    assert JSON.parse(patches.first[2]).key?("base")
    refute JSON.parse(patches.last[2]).key?("base"), "the retry named the base again"
  end

  def test_a_rung_with_no_open_request_opens_one
    http = ScriptedHttp.new([
      Response.new(code: "200", body: "[]"),
      Response.new(code: "201", body: JSON.generate({ "html_url" => "https://github.com/acme/storefront/pull/8",
        "base" => { "ref" => "agents/upgrade-4.1.0" } }))
    ])
    api = Publish::GitHub.new(token: "ghp_test", http: http)

    result = api.pull_request(owner: "acme", name: "storefront", head: "agents/upgrade-4.2.0",
      base: "agents/upgrade-4.1.0", title: "Upgrade Rails to 4.2.0 (agents)", body: "the rung")

    assert_equal "https://github.com/acme/storefront/pull/8", result["html_url"]
    assert_equal "agents/upgrade-4.1.0", result["base"]
    assert_equal %w[GET POST], http.requests.map(&:first)
  end
end
