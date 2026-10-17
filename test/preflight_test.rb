# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The moves an old application's Gemfile needs before anything can be installed.
#
# The two halves are asserted separately because they fail differently: the protocol rule
# is about a fact that has no exceptions (GitHub stopped speaking `git://` in 2022, and
# Bundler reads the protocol out of the lockfile's own `remote:` lines, so one file is not
# enough), and the digest rule is about *restraint* — every test below that ends in a
# decision or a note is a Gemfile this class refused to rewrite, which is the property
# that keeps a preflight from breaking an application quietly.
class PreflightTest < Minitest::Test
  Preflight = AgentsFyi::Upgrader::Preflight
  Corpus = AgentsFyi::Upgrader::Corpus

  GEMFILE = <<~GEM
    source "https://rubygems.org"

    gem "rails", "4.0.0.rc1"
    gem "cancan", github: "moriz/cancan", branch: "rails4"
    gem "turbo-sprockets-rails3"
    gem "devise", github: "plataformatec/devise", branch: "rails4"
  GEM

  LOCKFILE = <<~LOCK
    GIT
      remote: git://github.com/moriz/cancan.git
      revision: 8b8a3e9a1b1f2f5a4a4c4e4d4f4a4b4c4d4e4f40
      branch: rails4
      specs:
        cancan (1.6.10)

    GEM
      remote: https://rubygems.org/
      specs:
        rails (4.0.0.rc1)
        turbo-sprockets-rails3 (0.3.14)
        devise (2.2.4)

    DEPENDENCIES
      cancan!
      devise!
      rails (= 4.0.0.rc1)
      turbo-sprockets-rails3
  LOCK


  # The same lockfile without the git source, for the tests whose subject is the digest:
  # a repair list that also carried a protocol rewrite would make every assertion about
  # "what the digest did" assert two things.
  PLAIN_LOCKFILE = LOCKFILE.sub(/GIT\n.*?\n\n/m, "")

  # The digest as the service serves it, narrowed to the gems a caller names — the real
  # route's rule, so a test can assert both the entries and the question.
  class FakeCorpus
    attr_reader :asked

    def initialize(entries: [], refuse: nil)
      @entries = entries
      @refuse = refuse
      @asked = []
    end

    def gem_migrations(gems:)
      @asked << gems
      raise Corpus::Refused, @refuse if @refuse

      { "migrations" => @entries.select { |entry| gems.include?(entry["gem"]) },
        "counts" => { "selected" => 0, "total" => @entries.size }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end
  end

  def entry(gem:, kind: "replaced", replacement: nil, requirement: nil, mechanical: true,
            note: "the digest's reason", source: "the index")
    { "gem" => gem, "kind" => kind, "replacement" => replacement, "requirement" => requirement,
      "mechanical" => mechanical, "note" => note, "source" => source }
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def app(gemfile: GEMFILE, lockfile: LOCKFILE)
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile"), gemfile)
    File.write(File.join(dir, "Gemfile.lock"), lockfile) unless lockfile.nil?
    @dirs << dir
    dir
  end

  def preflight(dir, corpus: FakeCorpus.new)
    Preflight.new(root: dir, corpus: corpus).run
  end

  def read(dir, name) = File.read(File.join(dir, name))

  # **The protocol rule touches both files.** Bundler reads a git source's remote out of
  # the lockfile, so rewriting only the Gemfile leaves the lockfile naming a protocol
  # GitHub refuses — the install fails in exactly the way the repair was for.
  def test_a_git_protocol_remote_is_rewritten_in_both_files
    dir = app
    result = preflight(dir)

    assert_includes read(dir, "Gemfile"),
      %(gem "cancan", git: "https://github.com/moriz/cancan.git", branch: "rails4"),
      "the Gemfile's own shorthand is the other spelling of the same dead protocol"
    assert_includes read(dir, "Gemfile.lock"), "remote: https://github.com/moriz/cancan.git"
    refute_includes read(dir, "Gemfile.lock"), "git://"
    refute_includes read(dir, "Gemfile"), "github:"

    lock_repair = result.repairs.find { |repair| repair.path == "Gemfile.lock" }
    assert_equal 2, lock_repair.line, "the remote line's number is the file's, not the section's"
    assert_includes lock_repair.note, "2022"
  end

  # **The other spelling of the dead protocol.** Bundler 1.x expands `github: "owner/name"`
  # to `git://github.com/owner/name.git`, which is why every 2013 Gemfile that pinned a fork
  # broke at once — and rewriting only the literal `git://` left the first real application
  # stuck cloning over a protocol GitHub stopped accepting. The shorthand is expanded into the
  # `git:` remote it stands for, over https, keeping the line's quoting and its other options.
  def test_a_github_shorthand_is_expanded_to_an_https_git_remote
    dir = app(gemfile: <<~GEM, lockfile: PLAIN_LOCKFILE)
      source "https://rubygems.org"
      gem "rails", "4.0.0.rc1"
      gem 'simple_form', github: 'plataformatec/simple_form'
      gem "devise", github: "plataformatec/devise", branch: "rails4"
      gem "rmagick", github: "rmagick/rmagick.git"
    GEM
    corpus = FakeCorpus.new
    result = preflight(dir, corpus: corpus)

    gemfile = read(dir, "Gemfile")
    assert_includes gemfile, %(gem 'simple_form', git: 'https://github.com/plataformatec/simple_form.git')
    assert_includes gemfile, %(gem "devise", git: "https://github.com/plataformatec/devise.git", branch: "rails4")
    assert_includes gemfile, %(gem "rmagick", git: "https://github.com/rmagick/rmagick.git"),
      "a value that already ends in .git must not gain a second one"
    refute_includes gemfile, "github:"
    assert_equal 3, result.repairs.count { |repair| repair.subject == "github:" }
    assert_equal 0, result.repairs.count { |repair| repair.subject == "git://" }
  end

  def test_a_valid_github_line_is_left_alone_when_the_protocol_rule_cannot_apply
    # A `path:` source is not the library's to reinterpret, and a line with no dead protocol
    # is not touched at all.
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "x", path: "../x"\ngem "rails", "4.0.0.rc1"\n),
      lockfile: PLAIN_LOCKFILE)
    result = preflight(dir, corpus: FakeCorpus.new)

    assert_empty result.repairs
    assert_empty result.notes
  end

  # A digest entry whose declaration carries source options is rewritten to the released
  # gem: the options named where the gem came from, and the digest says which release it
  # should have come from.
  def test_a_mechanical_replacement_rewrites_the_declaration
    dir = app(lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [
      entry(gem: "devise", replacement: "devise", requirement: "~> 3.0"),
      entry(gem: "turbo-sprockets-rails3", kind: "removed", replacement: nil)
    ])
    result = preflight(dir, corpus: corpus)

    gemfile = read(dir, "Gemfile")
    assert_includes gemfile, %(gem "devise", "~> 3.0")
    refute_includes gemfile, "plataformatec/devise"
    refute_includes gemfile, %(gem "turbo-sprockets-rails3")
    assert_includes gemfile, %(gem "cancan", git: "https://github.com/moriz/cancan.git") # not in the digest

    assert_equal %w[devise turbo-sprockets-rails3],
      result.repairs.map(&:subject).reject { |subject| subject == "github:" }
    devise = result.repairs.find { |repair| repair.subject == "devise" }
    assert_equal 6, devise.line
    # The protocol pass runs first, so the digest repair's "before" is the expanded line —
    # which is what the file held when the digest pass read it.
    assert_equal %(gem "devise", git: "https://github.com/plataformatec/devise.git", branch: "rails4"),
      devise.text.strip
    assert_equal %(gem "devise", "~> 3.0"), devise.after.strip
  end

  # The gems asked about are the application's own: declared, plus the ones it merely
  # locked so the answer can say that a move belongs to another gem's line. A digest
  # lookup for the whole index would be a browsing rather than an answer.
  def test_the_digest_is_asked_about_the_application_s_own_gems
    dir = app
    corpus = FakeCorpus.new
    preflight(dir, corpus: corpus)

    asked = corpus.asked.first
    assert_includes asked, "cancan"
    assert_includes asked, "turbo-sprockets-rails3"
    refute_includes asked, "rake"
  end

  # A gem the application does not declare is not the application's line: the decision
  # names that, rather than editing a Gemfile nobody wrote.
  def test_a_move_for_a_transitive_gem_is_a_decision_rather_than_an_edit
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n),
      lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "turbo-sprockets-rails3", kind: "removed",
      replacement: nil, note: "declares railties < 4.0.0")])
    result = preflight(dir, corpus: corpus)

    assert_empty result.repairs
    decision = result.decisions.first
    assert_equal "turbo-sprockets-rails3", decision.subject
    assert_includes decision.reason, "not declared in the Gemfile"
    assert_includes decision.reason, "declares railties < 4.0.0"
    assert_equal "the index", decision.source
  end

  def test_a_move_the_digest_says_needs_a_decision_is_one
    dir = app(lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "rails", kind: "updated", replacement: "rails",
      requirement: "~> 4.1", mechanical: false, note: "changing the framework line moves the " \
        "components with it")])
    result = preflight(dir, corpus: corpus)

    refute(result.repairs.any? { |repair| repair.subject == "rails" },
      "a non-mechanical digest entry must not be rewritten")
    assert_equal "rails", result.decisions.first.subject
    assert_equal 3, result.decisions.first.line
    assert_includes read(dir, "Gemfile"), %(gem "rails", "4.0.0.rc1")
  end

  # **A declaration this class does not fully understand is not rewritten**, and each of
  # these is a Gemfile shape that exists in the wild. The note names the line and the
  # reason, so a reader knows the install that follows may be failing about it.
  def test_a_declaration_that_cannot_be_rewritten_is_skipped_with_its_reason
    cases = {
      "a comment on the line" => %(gem "devise" # pinned for the rails4 branch\n),
      "a multi-line declaration" => %(gem "devise",\n  github: "plataformatec/devise",\n  branch: "rails4"\n),
      "an option that changes behaviour" => %(gem "devise", require: false\n),
      "platforms" => %(gem "devise", platforms: :ruby\n)
    }

    cases.each do |description, declaration|
      dir = app(gemfile: %(source "https://rubygems.org"\n#{declaration}), lockfile: PLAIN_LOCKFILE)
      corpus = FakeCorpus.new(entries: [entry(gem: "devise", replacement: "devise",
        requirement: "~> 3.0")])
      result = preflight(dir, corpus: corpus)

      refute(result.repairs.any? { |repair| repair.subject == "devise" },
        "#{description} was rewritten by the digest rule")
      assert_equal 1, result.notes.size, "#{description} was skipped without a note"
      assert_includes result.notes.first, "devise"
      assert_includes read(dir, "Gemfile"), declaration.lines.first.strip
    end
  end

  # **The kind that keeps the gem and stops it loading at boot.** `capistrano`/`rvm-capistrano`
  # in the *default* group make `Bundler.require(:default, Rails.env)` load a deploy recipe
  # before anything boots, and capistrano 2.15.4's `Configuration.instance` answers
  # `LoadError: Please require this file from within a Capistrano recipe` — measured on the
  # first real application, where `rake db:create`, the suite and `bin/rails runner` all died
  # on it. The rewrite appends one option and changes nothing else on the line.
  def test_a_require_false_entry_appends_the_option_and_keeps_the_line_s_own
    dir = app(gemfile: <<~GEM, lockfile: PLAIN_LOCKFILE)
      source "https://rubygems.org"
      gem "rails", "4.0.0.rc1"
      gem 'capistrano'
      gem "rvm-capistrano", group: :deploy
    GEM
    corpus = FakeCorpus.new(entries: [
      entry(gem: "capistrano", kind: "require_false", replacement: nil),
      entry(gem: "rvm-capistrano", kind: "require_false", replacement: nil)
    ])
    result = preflight(dir, corpus: corpus)

    gemfile = read(dir, "Gemfile")
    assert_includes gemfile, %(gem 'capistrano', require: false)
    assert_includes gemfile, %(gem "rvm-capistrano", group: :deploy, require: false),
      "the line's own options are kept"
    assert_equal 2, result.repairs.size
    assert_equal %w[capistrano rvm-capistrano], result.repairs.map(&:subject)
  end

  # A line that already states its own `require:` has made this decision for itself, and the
  # skip says so rather than being silent.
  def test_a_line_that_already_states_a_require_is_left_alone
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "capistrano", require: false\n),
      lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "capistrano", kind: "require_false",
      replacement: nil)])
    result = preflight(dir, corpus: corpus)

    assert_empty result.repairs
    assert_equal 1, result.notes.size
    assert_includes result.notes.first, "already states its own require:"
  end

  # A removal takes the whole line, so what the line's options say does not change what
  # happens to it — this is the lighthouse's own shape: `gem "therubyracer", platforms:
  # :ruby` (the digest's `removed` entry) and `gem "turbo-sprockets-rails3", group:
  # :assets` are both declarations the *rewrite* rule would have refused to touch.
  def test_a_removal_ignores_the_options_and_comments_a_rewrite_would_refuse
    dir = app(gemfile: <<~GEM, lockfile: PLAIN_LOCKFILE)
      source "https://rubygems.org"
      gem "rails", "4.0.0.rc1"
      gem "therubyracer", platforms: :ruby
      gem "turbo-sprockets-rails3", group: :assets # asset speed
    GEM
    corpus = FakeCorpus.new(entries: [
      entry(gem: "therubyracer", kind: "removed", replacement: nil),
      entry(gem: "turbo-sprockets-rails3", kind: "removed", replacement: nil)
    ])
    result = preflight(dir, corpus: corpus)

    assert_equal %w[therubyracer turbo-sprockets-rails3], result.repairs.map(&:subject)
    refute_includes read(dir, "Gemfile"), "therubyracer"
    refute_includes read(dir, "Gemfile"), "turbo-sprockets-rails3"
    assert_empty result.notes
  end

  # A digest entry for a gem this application does not have is not its business, and
  # saying so per gem would bury the two that matter under nine that do not.
  def test_an_entry_for_a_gem_the_application_does_not_have_is_ignored
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n),
      lockfile: "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (4.0.0.rc1)\n")
    corpus = FakeCorpus.new(entries: [entry(gem: "sidekiq", replacement: "sidekiq",
      requirement: "~> 7.0")])
    result = preflight(dir, corpus: corpus)

    assert_empty result.repairs
    assert_empty result.decisions
    assert_empty result.notes
  end

  # An unreadable digest narrows the preflight; it does not stop it. A deployment whose
  # service is older than this route refuses with a 404, and the general repairs are facts
  # about a protocol rather than about an index.
  def test_a_digest_that_cannot_be_read_leaves_the_general_repairs_standing
    dir = app
    result = preflight(dir, corpus: FakeCorpus.new(refuse: "404, and no route for it"))

    assert_equal 3, result.repairs.size, "the general repairs are the blank's and the two shorthands'"
    assert_equal 1, result.repairs.count { |repair| repair.path == "Gemfile.lock" }
    assert_equal 1, result.notes.size
    assert_includes result.notes.first, "the gem-migrations digest was not read"
    assert_includes result.notes.first, "only the general preflight repairs"
  end

  def test_a_directory_that_is_not_an_application_is_refused
    dir = Dir.mktmpdir
    @dirs << dir

    error = assert_raises(Preflight::NotAnApplication) { preflight(dir) }
    assert_includes error.message, "neither a Gemfile nor a Gemfile.lock"
  end

  # Run it twice: the second run has nothing to do, because the first one's repairs are
  # what the second one would have found. A preflight that re-applied its own work would
  # make a reread look like a change.
  def test_a_second_preflight_finds_nothing_left_to_do
    dir = app(lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [
      entry(gem: "devise", replacement: "devise", requirement: "~> 3.0"),
      entry(gem: "turbo-sprockets-rails3", kind: "removed", replacement: nil)
    ])
    first = preflight(dir, corpus: corpus)
    second = preflight(dir, corpus: FakeCorpus.new(entries: [
      entry(gem: "devise", replacement: "devise", requirement: "~> 3.0"),
      entry(gem: "turbo-sprockets-rails3", kind: "removed", replacement: nil)
    ]))

    refute_empty first.repairs
    assert_empty second.repairs
  end

  # **Two components, one bound.** The client's question size is the route's own, read out of
  # the service's file rather than copied and hoped about — a client that drifted below the
  # route would refuse itself questions the service would answer, and one above it would ask
  # questions the service refuses, which is exactly how the whole digest went missing on the
  # first real application.
  def test_the_client_s_question_bound_is_the_routes_own
    route = File.read(File.expand_path("../../upgrade/app/services/upgrade/migrations.rb", __dir__),
      encoding: "utf-8")
    limit = route[/GEMS_LIMIT = (\d+)/, 1]

    refute_nil limit, "the route no longer declares a GEMS_LIMIT for this test to pin"
    assert_equal limit.to_i, Preflight::DIGEST_GEMS_LIMIT
  end

  # And when an application does exceed it, the note says what was not asked about rather
  # than a prefix going out silently: a question cut short reads as a complete answer.
  def test_a_question_larger_than_the_route_s_bound_says_what_it_did_not_ask
    gemfile = +%(source "https://rubygems.org"\n)
    (Preflight::DIGEST_GEMS_LIMIT + 5).times { |index| gemfile << %(gem "gem#{index}", "1.0"\n) }
    dir = app(gemfile: gemfile, lockfile: "GEM\n  remote: https://rubygems.org/\n  specs:\n")
    corpus = FakeCorpus.new
    result = preflight(dir, corpus: corpus)

    assert(result.notes.any? { |note| note.include?("would have to be asked about") })
    assert_operator corpus.asked.first.size, :<=, Preflight::DIGEST_GEMS_LIMIT
  end

  def test_the_result_says_what_it_did_in_one_line_and_in_detail
    dir = app(lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "devise", replacement: "devise", requirement: "~> 3.0")])
    result = preflight(dir, corpus: corpus)

    assert_includes result.summary, "3 repair(s), 0 decision(s)"
    assert(result.details.any? { |line| line.include?("Gemfile:6") })
    assert_equal 3, result.to_h["repairs"].size
    assert_equal %w[devise github: github:], result.to_h["repairs"].map { |row| row["subject"] }.sort
    assert_empty result.to_h["decisions"]
  end
end
