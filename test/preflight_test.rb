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

    assert_includes read(dir, "Gemfile"), %(github: "moriz/cancan")
    assert_includes read(dir, "Gemfile.lock"), "remote: https://github.com/moriz/cancan.git"
    refute_includes read(dir, "Gemfile.lock"), "git://"

    lock_repair = result.repairs.find { |repair| repair.path == "Gemfile.lock" }
    assert_equal 2, lock_repair.line, "the remote line's number is the file's, not the section's"
    assert_includes lock_repair.note, "2022"
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
    assert_includes gemfile, %(gem "cancan", github: "moriz/cancan") # not in the digest

    assert_equal %w[devise turbo-sprockets-rails3], result.repairs.map(&:subject)
    devise = result.repairs.first
    assert_equal 6, devise.line
    assert_equal %(gem "devise", github: "plataformatec/devise", branch: "rails4"), devise.text.strip
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

    assert_empty result.repairs
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

      assert_empty result.repairs, "#{description} was rewritten"
      assert_equal 1, result.notes.size, "#{description} was skipped without a note"
      assert_includes result.notes.first, "devise"
      assert_includes read(dir, "Gemfile"), declaration.lines.first.strip
    end
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

    assert_equal 1, result.repairs.size
    assert_equal "Gemfile.lock", result.repairs.first.path
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

  def test_the_result_says_what_it_did_in_one_line_and_in_detail
    dir = app(lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "devise", replacement: "devise", requirement: "~> 3.0")])
    result = preflight(dir, corpus: corpus)

    assert_includes result.summary, "1 repair(s), 0 decision(s)"
    assert(result.details.any? { |line| line.include?("Gemfile:6") })
    assert_equal 1, result.to_h["repairs"].size
    assert_equal "devise", result.to_h["repairs"].first["subject"]
    assert_empty result.to_h["decisions"]
  end
end
