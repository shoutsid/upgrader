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

      # The service's own rule, mirrored so the double cannot lie: a `declared` entry is for a gem
      # the caller does not hold, so it travels with every answer.
      { "migrations" => @entries.select { |entry|
        gems.include?(entry["gem"]) || entry["kind"] == "declared"
      },
        "counts" => { "selected" => 0, "total" => @entries.size }, "stored" => false,
        "next_step" => "the digest's own sentence" }
    end
  end

  def entry(gem:, kind: "replaced", replacement: nil, requirement: nil, mechanical: true,
            note: "the digest's reason", source: "the index", condition: nil)
    { "gem" => gem, "kind" => kind, "replacement" => replacement, "requirement" => requirement,
      "mechanical" => mechanical, "note" => note, "source" => source, "when" => condition }
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # The Gemfile the declaration tests use: the same application, without the `github:` pins the
  # protocol rule rewrites — so a test about the digest's declarations asserts the declaration rather
  # than counting repairs that were already there. (`PLAIN_LOCKFILE`, above, is that lockfile.)
  PLAIN_GEMFILE = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n)

  def app(gemfile: GEMFILE, lockfile: LOCKFILE)
    dir = Dir.mktmpdir
    File.write(File.join(dir, "Gemfile"), gemfile)
    File.write(File.join(dir, "Gemfile.lock"), lockfile) unless lockfile.nil?
    @dirs << dir
    dir
  end

  def preflight(dir, corpus: FakeCorpus.new, ruby: nil, rails: nil)
    Preflight.new(root: dir, corpus: corpus, ruby: ruby, rails: rails).run
  end

  def read(dir, name) = File.read(File.join(dir, name))

  # **A declaration is the repair for a gem the application does not hold yet, and there is no line
  # of the application's to rewrite.** Rails 4.2 brings `rails-html-sanitizer` in, that brings loofah
  # in, and on an interpreter too old for nokogiri 1.12 the newest loofah's code needs a constant no
  # nokogiri this Ruby can install provides — measured, the 4.2 rung's `rails:update` died on
  # `uninitialized constant Nokogiri::HTML4`. So the digest's answer is a line to *add*, and the
  # record renders it as one rather than quoting a line that does not exist.
  def test_a_declared_entry_adds_the_line_when_its_condition_holds
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "loofah", kind: "declared",
      requirement: "~> 2.0.3", condition: { "ruby_below" => "2.5" })])

    result = preflight(dir, corpus: corpus, ruby: "2.1")

    declared = result.repairs.select { |repair| repair.subject == "loofah" }
    assert_equal 1, declared.size, "the declaration was not made: #{result.details.inspect}"
    assert_nil declared.first.text, "an addition has no line to quote"
    assert_includes read(dir, "Gemfile"), %(gem "loofah", "~> 2.0.3")
    assert_includes result.details, %(Gemfile: `gem "loofah", "~> 2.0.3"` declared (loofah))
  end

  # The condition is what keeps a digest entry from being applied to an application it is not
  # about: above the Ruby that can run nokogiri 1.12, the newest loofah is the right one.
  def test_a_declaration_the_interpreter_can_do_without_is_not_made
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "loofah", kind: "declared",
      requirement: "~> 2.0.3", condition: { "ruby_below" => "2.5" })])

    result = preflight(dir, corpus: corpus, ruby: "3.2")

    assert_empty result.repairs
    refute_includes read(dir, "Gemfile"), "loofah"
    assert_equal 1, result.notes.size, "the skip was silent: #{result.details.inspect}"
    assert_includes result.notes.first, "this move does not meet it"
    assert_includes result.notes.first, "ruby_below 2.5", "the note has to name the condition"
  end

  # A condition this stage cannot evaluate is a note, not a silent pass — the failure that would
  # hide a broken rung behind a preflight that looked like it had nothing to do.
  def test_a_condition_this_cannot_evaluate_is_a_note_and_not_a_silent_pass
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "loofah", kind: "declared",
      requirement: "~> 2.0.3", condition: { "ruby_below" => "2.5" })])

    result = preflight(dir, corpus: corpus)

    assert_empty result.repairs
    assert_equal 1, result.notes.size
    assert_includes result.notes.first, "was not told the interpreter",
      "an unevaluable condition and a condition this move does not meet are different reasons, and " \
      "the sentence has to say which: #{result.notes.inspect}"
  end

  # **A digest entry can be scoped to the rung, and that is what lets one gem move twice in a walk.**
  # Measured at the 4.2 rung: Rails 4.2 removed `ActionDispatch::Routing::Mapper::Scope#merge!` and
  # devise 3.0.4's own routes file calls it, so the `~> 3.0.0` line that 4.0 and 4.1 need is the wrong
  # one there. The walker takes the entry whose condition holds, applies it *at the pin* (a rung-scoped
  # line waits for the release it is about — see
  # `test_a_rewrite_scoped_to_the_rung_waits_for_the_pin`), and says in a note which entry it did not
  # apply and why.
  def test_a_digest_entry_scoped_to_a_rung_is_the_one_that_applies
    gemfile = %(source "https://rubygems.org"\ngem "devise", "~> 3.0.0"\n)
    corpus = lambda do
      FakeCorpus.new(entries: [
        entry(gem: "devise", replacement: "devise", requirement: "~> 3.0.0",
          condition: { "rails_below" => "4.2" }),
        entry(gem: "devise", replacement: "devise", requirement: "~> 3.2",
          condition: { "rails_at_least" => "4.2" })
      ])
    end

    up = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    up_result = preflight(up, corpus: corpus.call, ruby: "2.0", rails: "4.2.0")

    assert_empty up_result.repairs, "a rung-scoped line is applied at the pin, not here"
    assert_equal %w[devise], up_result.deferred.map { |deferred| deferred["gem"] },
      "the entry scoped at 4.2 and above is the one that holds here"
    assert(up_result.notes.any? { |note| note.include?("rails_below 4.2") },
      "the entry that does not apply has to say so: #{up_result.notes.inspect}")

    applied = Preflight.new(root: up, corpus: corpus.call, ruby: "2.0", rails: "4.2.0")
      .declare_deferred(up_result.deferred)

    assert_equal %w[devise], applied.repairs.map(&:subject)
    assert_includes read(up, "Gemfile"), %(gem "devise", "~> 3.2")
    refute_includes read(up, "Gemfile"), "3.0.0"

    before = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    before_result = preflight(before, corpus: corpus.call, ruby: "2.0", rails: "4.1.0")

    assert_equal %w[devise], before_result.deferred.map { |deferred| deferred["gem"] },
      "the entry 4.0 and 4.1 need is the one held here"
    assert_includes read(before, "Gemfile"), %(gem "devise", "~> 3.0.0")
    refute_includes read(before, "Gemfile"), "3.2"
    assert(before_result.notes.any? { |note| note.include?("rails_at_least 4.2") },
      "the entry that does not apply has to say so: #{before_result.notes.inspect}")
  end

  # **A declaration scoped to the rung cannot be made before the pin names that rung.** Measured at
  # the 4.2 rung: the preflight runs before the machine is chosen — the choice *is* a `bundle
  # install` — so the Gemfile it edits still says `rails 4.1.0`, and declaring `responders ~> 2.0`
  # there answers `railties (< 5, >= 4.2.0.alpha)` against `railties (= 4.1.0)` for every era. The
  # preflight therefore defers it, says so, and the step applies it after the pin is rewritten.
  def test_a_declaration_scoped_to_the_rung_waits_for_the_pin
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "responders", kind: "declared",
      requirement: "~> 2.0", condition: { "rails_at_least" => "4.2" })])

    result = preflight(dir, corpus: corpus, rails: "4.2.0")

    assert_empty result.repairs,
      "the preflight declared a gem the Gemfile's own framework cannot carry: #{result.details.inspect}"
    refute_includes read(dir, "Gemfile"), "responders"
    assert_equal %w[responders], result.deferred.map { |deferred| deferred["gem"] }
    assert_includes result.summary, "1 entry(ies) held for the pin"
    assert_equal %w[responders], result.to_h["deferred"]
    assert(result.notes.any? { |note| note.include?("waits for the pin") },
      "a deferred declaration that says nothing reads as one the digest did not have: " \
      "#{result.notes.inspect}")

    # And where the Gemfile and the pin agree, the same entry is applied.
    later = Preflight.new(root: dir, corpus: corpus, rails: "4.2.0").declare_deferred(result.deferred)

    assert_equal %w[responders], later.repairs.map(&:subject)
    assert_includes read(dir, "Gemfile"), %(gem "responders", "~> 2.0")
    assert_includes later.details, %(Gemfile: `gem "responders", "~> 2.0"` declared (responders))
  end

  # **A line scoped to the rung waits for the pin for the same reason a declaration does, and the
  # failure this was measured on is a green baseline turned red.** At the 6.0 rung the application's
  # own `loofah ~> 2.0.3` was moved to the line actionpack 6.0 asks for, *before* the baseline: the
  # bundle stage's conservative update then took loofah 2.21.1 — whose earlier sibling releases
  # declare `nokogiri >= 1.5.9` while their code calls `Nokogiri::HTML4` — while nokogiri stayed at the
  # 1.9.1 only the 5.2 stack needs, and the 5.2 baseline died on that constant. A line whose whole
  # reason is the release the move ends at belongs where the Gemfile and the pin agree.
  def test_a_rewrite_scoped_to_the_rung_waits_for_the_pin
    gemfile = %(source "https://rubygems.org"\ngem "rails", "5.2.0"\ngem "loofah", "~> 2.0.3"\n)
    corpus = FakeCorpus.new(entries: [entry(gem: "loofah", replacement: "loofah",
      requirement: "~> 2.22", condition: { "rails_at_least" => "6.0" })])

    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    result = preflight(dir, corpus: corpus, ruby: "2.5", rails: "6.0.0")

    assert_empty result.repairs,
      "the preflight moved a line for a rung the Gemfile does not name yet: #{result.details.inspect}"
    assert_includes read(dir, "Gemfile"), %(gem "loofah", "~> 2.0.3")
    assert_equal %w[loofah], result.deferred.map { |deferred| deferred["gem"] }
    assert(result.notes.any? { |note| note.include?("waits for the pin") },
      "a held rewrite that says nothing reads as one the digest did not have: #{result.notes.inspect}")

    later = Preflight.new(root: dir, corpus: corpus, ruby: "2.5", rails: "6.0.0")
      .declare_deferred(result.deferred)

    assert_equal %w[loofah], later.repairs.map(&:subject)
    assert_includes read(dir, "Gemfile"), %(gem "loofah", "~> 2.22")
    refute_includes read(dir, "Gemfile"), "2.0.3"
  end

  # **The other half of the same rule: `ruby`-scoped is the machine, so it stays here.** The install
  # that chooses the interpreter is the first thing a step does, so an entry scoped by the *machine*
  # has to be in the Gemfile before it — the 5.0 rung's `json` floor is the measured case, where a
  # release's own C source does not compile on the interpreter the ladder allows.
  def test_a_rewrite_scoped_to_the_interpreter_is_applied_here
    gemfile = %(source "https://rubygems.org"\ngem "rails", "5.2.0"\ngem "ffi", "~> 1.9"\n)
    corpus = FakeCorpus.new(entries: [entry(gem: "ffi", replacement: "ffi",
      requirement: "~> 1.16.0", condition: { "ruby_at_least" => "2.5" })])

    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    result = preflight(dir, corpus: corpus, ruby: "2.5", rails: "6.0.0")

    assert_equal %w[ffi], result.repairs.map(&:subject)
    assert_includes read(dir, "Gemfile"), %(gem "ffi", "~> 1.16.0")
    assert_empty result.deferred
  end

  # **A gem can be too *old* for the interpreter as well as too new for it.** `ruby_below` catches
  # the case where the newest installable release is wrong; `ruby_at_least` catches the other one —
  # a release whose own source will not compile on the interpreter the rung requires. Measured on
  # the 5.0 rung: json 1.7.7's `rb_str_new` call meets Ruby 2.2's variadic macro, `bundle install`
  # dies in `fbuffer.h`, and no era installs the bundle. The move is made *here* rather than at the
  # pin because the machine probe is itself a `bundle install` of the Gemfile as it stands.
  def test_a_move_scoped_to_a_newer_interpreter_is_made_here_and_not_at_the_pin
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.1.0"\ngem "json", "~> 1.7.7"\n)
    corpus = lambda do
      FakeCorpus.new(entries: [entry(gem: "json", replacement: "json", requirement: "~> 1.8",
        condition: { "ruby_at_least" => "2.2" })])
    end

    newer = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    applied = preflight(newer, corpus: corpus.call, ruby: "2.2.2")

    assert_includes read(newer, "Gemfile"), %(gem "json", "~> 1.8")
    refute_includes read(newer, "Gemfile"), "1.7.7"
    assert_equal 1, applied.repairs.size

    older = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    skipped = preflight(older, corpus: corpus.call, ruby: "2.1.10")

    refute_includes read(older, "Gemfile"), "1.8"
    assert_includes skipped.notes.first, "was not applied"
    assert_includes skipped.notes.first, "ruby_at_least 2.2"
  end

  # A gem the application already declares is the application's line: the digest is not asked about
  # a line it did not write, and adding a second one would be the duplicate bundler refuses outright.
  def test_a_gem_the_application_already_declares_is_left_alone
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\ngem "loofah"\n)
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "loofah", kind: "declared",
      requirement: "~> 2.0.3", condition: { "ruby_below" => "2.5" })])

    result = preflight(dir, corpus: corpus, ruby: "2.1")

    assert_empty result.repairs
    assert_equal gemfile, read(dir, "Gemfile")
  end

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

  # **A `declared` entry travels with every answer, so the clause that scopes it has to be the caller's
  # own Gemfile.** Measured at the 7.0 rung: the sibling that keeps shoulda-matchers 2.8.0 loading on
  # Ruby 2.7 (`bigdecimal ~> 1.4`) is worth declaring only to an application that holds the gem — a
  # caller without it would get a native build of an old bigdecimal for nothing, and the service cannot
  # know which caller it is answering. `declares` is that clause, and it is answered from the Gemfile
  # this stage has already read.
  def test_a_declared_entry_scoped_by_declares_is_applied_where_the_application_holds_the_gem
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\ngem "shoulda-matchers", "~> 2.7"\n)
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [
      entry(gem: "bigdecimal", kind: "declared", replacement: nil, requirement: "~> 1.4",
        condition: { "ruby_at_least" => "2.7", "declares" => "shoulda-matchers" })
    ])

    result = preflight(dir, corpus: corpus, ruby: "2.7.8")

    declaration = result.repairs.find { |repair| repair.subject == "bigdecimal" }
    refute_nil declaration, "the declaration was not made: #{result.repairs.map(&:subject).inspect}"
    assert_includes read(dir, "Gemfile"), %(gem "bigdecimal", "~> 1.4")
  end

  # And where the application does not hold the gem, the skip is a *sentence about the Gemfile* rather
  # than "this move does not meet it" — which would send a reader to look at the rung for a fact that is
  # about their own file.
  def test_a_declared_entry_scoped_by_declares_is_skipped_with_the_reason_where_the_gem_is_absent
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [
      entry(gem: "bigdecimal", kind: "declared", replacement: nil, requirement: "~> 1.4",
        condition: { "ruby_at_least" => "2.7", "declares" => "shoulda-matchers" })
    ])

    result = preflight(dir, corpus: corpus, ruby: "2.7.8")

    assert_nil result.repairs.find { |repair| repair.subject == "bigdecimal" },
      "a line was declared for a gem the application does not hold"
    note = result.notes.find { |line| line.include?("bigdecimal") }
    refute_nil note, "the skip is not in the record: #{result.notes.inspect}"
    assert_includes note, "does not declare shoulda-matchers"
    refute_includes read(dir, "Gemfile"), "bigdecimal"
  end
end
