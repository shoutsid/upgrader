# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# The moves an old application's Gemfile needs before anything can be installed.
#
# The two halves are asserted separately because they fail differently: the protocol rule
# is about a fact that has no exceptions (GitHub stopped speaking `git://` in 2022, and
# Bundler reads the protocol out of the lockfile's own `remote:` lines, so one file is not
# enough), and the digest rule is about *restraint* — every test below that ends in a
# decision or a note is a Gemfile this class refused to rewrite, which is the property
# that keeps a preflight from breaking an application quietly.
class PreflightTest < Minitest::Test
  Preflight = Agents::Upgrader::Preflight
  Corpus = Agents::Upgrader::Corpus
  Companions = Agents::Upgrader::Companions

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

  def entry(gem:, kind: "replaced", replacement: nil, requirement: nil, repository: nil,
            mechanical: true, note: "the digest's reason", source: "the index", condition: nil,
            forced: false, only_if_locked: false)
    row = { "gem" => gem, "kind" => kind, "replacement" => replacement,
            "repository" => repository, "requirement" => requirement,
            "mechanical" => mechanical, "note" => note, "source" => source, "when" => condition }
    row = row.merge("forced" => true) if forced
    only_if_locked ? row.merge("only_if_locked" => true) : row
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

  # The application the companion tests use: the two test gems whose own upgrades need code edits,
  # declared and locked, so the digest's entries for them are entries about *this* application and a
  # companion can be looked up by the line the digest declares.
  TEST_GEMFILE = %(source "https://rubygems.org"\n\ngem "rails", "4.0.0.rc1"\n) +
    %(gem "shoulda-matchers", "~> 2.7"\ngem "rspec-rails", "~> 2.14.0"\n)
  TEST_LOCKFILE = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rails (4.0.0.rc1)
        rspec-rails (2.14.2)
        shoulda-matchers (2.8.0)

    DEPENDENCIES
      rails (= 4.0.0.rc1)
      rspec-rails (~> 2.14.0)
      shoulda-matchers (~> 2.7)
  LOCK

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

  # The stage after the pin: rung-scoped declarations and the rules that belong with them.
  def declarations(dir, rails: nil)
    Preflight.new(root: dir, corpus: FakeCorpus.new, rails: rails).declare_deferred([])
  end

  def read(dir, name) = File.read(File.join(dir, name))

  # **An exact interpreter pin is a patch the matrix may not carry.** Ruby 2.7 is one image, and a
  # Gemfile saying `ruby "2.7.5"` refuses every machine whose patch is 2.7.8 before the bundle is
  # read. The application meant a minimum, so the pin becomes the floor it states; a `~>` would
  # block the later rungs that need a newer minor, which is the move this tool exists to make.
  def test_an_exact_interpreter_pin_becomes_the_floor_it_meant
    dir = app(gemfile: %(source "https://rubygems.org"\nruby "2.7.5"\ngem "rails", "5.2.8"\n),
      lockfile: PLAIN_LOCKFILE)

    result = preflight(dir)

    repair = result.repairs.find { |each| each.subject == "ruby" }
    refute_nil repair, result.details.inspect
    assert_equal %(ruby ">= 2.7.5"), read(dir, "Gemfile").lines[1].strip
    assert_includes repair.note, "patch releases of a minor are compatible"
  end

  # **The exact patch can live in `.ruby-version` instead of the Gemfile.** A Gemfile that says
  # `ruby File.read(".ruby-version").strip` is the same statement one file over, and the preflight
  # that only read literals left `volunteer_portal` refused by every era: its `.ruby-version` says
  # 2.7.1 and the 2.7 image is 2.7.8. The Gemfile becomes the floor; the version file is not edited.
  def test_an_interpreter_pin_read_from_the_version_file_becomes_the_floor_it_meant
    dir = app(gemfile: %(source "https://rubygems.org"\nruby File.read(".ruby-version").strip\ngem "rails", "5.2.8"\n),
      lockfile: PLAIN_LOCKFILE)
    File.write(File.join(dir, ".ruby-version"), "2.7.1\n")

    result = preflight(dir)

    repair = result.repairs.find { |each| each.subject == "ruby" }
    refute_nil repair, result.details.inspect
    assert_equal %(ruby ">= 2.7.1"), read(dir, "Gemfile").lines[1].strip
    assert_equal "2.7.1\n", read(dir, ".ruby-version"),
      "the version manager's file is not the Gemfile's requirement"
  end

  # The expression is understood only for the one file it names. A shell command, or a version
  # file holding a requirement rather than a version, is not a pin this class can relax.
  def test_an_interpreter_expression_this_class_does_not_understand_is_left_alone
    gemfile = %(source "https://rubygems.org"\nruby File.read("config/ruby").strip\ngem "rails", "5.2.8"\n)
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "ruby"), "2.7.1\n")

    result = preflight(dir)

    assert_empty result.repairs
    assert_includes read(dir, "Gemfile"), %(File.read("config/ruby"))
  end

  # **Devise 3.5 extracted `:token_authenticatable`, and an application's model still names it.**
  # Measured on `rails-4-api` at 4.2.11.3: devise moved to 3.5.10 and the boot died on
  # `NameError: uninitialized constant Devise::Models::TokenAuthenticatable`; adding the extracted
  # gem made the same boot print the release. The rule is a declaration because the model's line is
  # the application's and the gem is the module that line names.
  def test_a_token_authenticatable_model_gets_the_extracted_devise_gem
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11.3"\ngem "devise", "~> 3.2"\n),
      lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "user.rb"),
      "class User < ActiveRecord::Base\n  devise :database_authenticatable, :token_authenticatable\nend\n")

    result = declarations(dir, rails: "4.2.11.3")

    repair = result.repairs.find { |each| each.subject == "devise-token_authenticatable" }
    refute_nil repair, result.details.inspect
    assert_includes read(dir, "Gemfile"), %(gem "devise-token_authenticatable", "~> 0.4.0")
    assert_includes repair.note, "devise 3.5"
  end

  # The module is still in devise 3.0, which is the line a Rails 4.1 application uses; adding the
  # extracted gem there would be a dependency the application does not need.
  def test_a_rails_4_1_token_model_is_left_alone
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.1.16"\ngem "devise", "~> 3.0.0"\n),
      lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "user.rb"), "class User\n  devise :token_authenticatable\nend\n")

    result = declarations(dir, rails: "4.1.16")

    assert_empty result.repairs.select { |each| each.subject == "devise-token_authenticatable" }
    refute_includes read(dir, "Gemfile"), "devise-token_authenticatable"
  end

  # A model that does not name the module is not the rule's application, even on 4.2.
  def test_a_4_2_devise_app_without_the_module_gets_no_extra_gem
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "4.2.11.3"\ngem "devise", "~> 3.2"\n),
      lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "user.rb"), "class User\n  devise :database_authenticatable\nend\n")

    result = declarations(dir, rails: "4.2.11.3")

    assert_empty result.repairs.select { |each| each.subject == "devise-token_authenticatable" }
  end

  # A requirement is already the statement the exact pin should have been, and rewriting it would
  # be a second opinion about an application's own bound.
  def test_an_interpreter_requirement_is_left_alone
    dir = app(gemfile: %(source "https://rubygems.org"\nruby "~> 2.7.5"\ngem "rails", "5.2.8"\n),
      lockfile: PLAIN_LOCKFILE)

    result = preflight(dir)

    assert_empty result.repairs
    assert_includes read(dir, "Gemfile"), %(ruby "~> 2.7.5")
  end

  # An engine is not a patch: the application is asking for a different interpreter than the
  # matrix's MRI, and relaxing that line would let the walk run it on the wrong one.
  def test_an_interpreter_pin_for_an_engine_is_left_alone
    gemfile = <<~GEM
      source "https://rubygems.org"
      ruby "2.7.5", engine: "jruby", engine_version: "9.2.0"
      gem "rails", "5.2.8"
    GEM
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)

    result = preflight(dir)

    assert_empty result.repairs
    assert_includes read(dir, "Gemfile"), %(engine: "jruby")
  end

  # **A declaration is the repair for a gem the application does not hold yet, and there is no line
  # of the application's to rewrite.** Rails 4.2 brings `rails-html-sanitizer` in, that brings loofah
  # in, and on an interpreter too old for nokogiri 1.12 the newest loofah's code needs a constant no
  # nokogiri this Ruby can install provides — measured, the 4.2 rung's `rails:update` died on
  # `uninitialized constant Nokogiri::HTML4`. So the digest's answer is a line to *add*, and the
  # record renders it as one rather than quoting a line that does not exist.
  # **A test gem's ceiling is a fact the digest does not hold.** volunteer_portal's maxitest 3.6.0
  # caps minitest below 5.14, while the 7.1 digest declares `~> 5.25.0` for the interpreter. The
  # added line is withdrawn after the digest writes it, leaving the lock's own 5.13 — which
  # satisfies both Rails 7.1's `minitest >= 5.1` and maxitest's ceiling.
  def test_a_digest_minitest_line_is_withdrawn_when_maxitest_caps_it
    lock = <<~LOCK
      GEM
        specs:
          maxitest (3.6.0)
            minitest (>= 5.0.0, < 5.14.0)
          minitest (5.13.0)
          rails (7.1.0)
    LOCK
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "7.1.0"\ngem "maxitest"\n),
      lockfile: lock)
    corpus = FakeCorpus.new(entries: [entry(gem: "minitest", kind: "declared",
      requirement: "~> 5.25.0",
      condition: { "rails_at_least" => "7.1", "rails_below" => "7.2", "ruby_below" => "3.1" })])

    result = preflight(dir, corpus: corpus, ruby: "2.7", rails: "7.1.6")
    deferred = result.deferred
    refute_empty deferred, "the rung-scoped minitest declaration should wait for the pin"

    declared = Preflight.new(root: dir, corpus: corpus, ruby: "2.7", rails: "7.1.6")
      .declare_deferred(deferred)

    refute_includes read(dir, "Gemfile"), "minitest"
    assert_empty declared.repairs.select { |repair| repair.subject == "minitest" }
    assert declared.notes.any? { |note| note.include?("maxitest caps minitest") },
      "the record must say why the digest's line was withheld: #{declared.notes.inspect}"
  end

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

  # **A curated entry is a floor, and the application can already be above it.** The json entry
  # was measured on an application pinning `~> 1.7.7`, whose C source will not compile on 2.2;
  # the second lighthouse locks 2.19.3, and applying the entry wrote `~> 1.8`, a downgrade the
  # resolver then refused against a dev gem. A line the application is already above is not a
  # repair.
  def test_a_digest_replacement_below_the_locked_version_is_not_a_downgrade
    gemfile = %(source "https://rubygems.org"\ngem "json", "2.19.3"\n)
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          json (2.19.3)

      DEPENDENCIES
        json (= 2.19.3)

      BUNDLED WITH
         2.5.9
    LOCK
    corpus = FakeCorpus.new(entries: [
      entry(gem: "json", replacement: "json", requirement: "~> 1.8",
        condition: { "ruby_at_least" => "2.2" })
    ])
    dir = app(gemfile: gemfile, lockfile: lockfile)

    result = preflight(dir, corpus: corpus, ruby: "2.2", rails: "5.0.0")

    assert_empty result.repairs
    assert(result.notes.any? { |note| note.include?("downgrade") }, result.notes.inspect)
    assert_includes read(dir, "Gemfile"), %(gem "json", "2.19.3")
  end

  # **And the exception is the rung that cannot carry the line.** Diaspora pins `minitest 6.0.3`,
  # activesupport 7.2.4 declares `minitest >= 5.1, < 6`, and the pin printed `version solving has
  # failed` before any stage past it ran. The digest's `forced` flag is what says the application
  # being above the line is the fact being repaired rather than the regression the guard refuses.
  def test_a_forced_entry_moves_a_line_the_application_sits_above
    gemfile = %(source "https://rubygems.org"\ngem "minitest", "6.0.3"\n)
    lockfile = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          minitest (6.0.3)

      DEPENDENCIES
        minitest (= 6.0.3)

      BUNDLED WITH
         2.5.9
    LOCK
    corpus = FakeCorpus.new(entries: [
      entry(gem: "minitest", replacement: "minitest", requirement: "~> 5.25.0",
        condition: { "rails_at_least" => "7.2" }, forced: true)
    ])
    dir = app(gemfile: gemfile, lockfile: lockfile)

    held = preflight(dir, corpus: corpus, ruby: "3.2", rails: "7.2.4")

    # A `rails_at_least` clause is the rung's, so the line waits for the pin — and the point of the
    # flag is that it gets there at all, where the guard would have answered "downgrade" instead.
    assert_equal %w[minitest], held.deferred.map { |deferred| deferred["gem"] }, held.notes.inspect
    refute(held.notes.any? { |note| note.include?("downgrade") }, held.notes.inspect)

    applied = Preflight.new(root: dir, corpus: corpus, ruby: "3.2", rails: "7.2.4")
      .declare_deferred(held.deferred)

    assert_equal 1, applied.repairs.size
    assert_includes read(dir, "Gemfile"), %(gem "minitest", "~> 5.25.0")
  end

  # **The guard's reader has to be the one that can read a maintained application's lock.** A
  # tree that vendors a gem — `remote: vendor/gems/js_image_paths`, the shape a recorded decision
  # left diaspora in — makes a bare `Bundler::LockfileParser` resolve its relative remote against
  # Bundler's *root*, and a step runs from `/app`, which is not the application. It raised
  # `Bundler::GemfileNotFound`, the rescue turned that into `{}`, the guard read "nothing is newer
  # than `~> 2.6.0`", and the 8.1 rung wrote `json ~> 2.6.0` over a locked 2.19.3; the pin then
  # died on a `thor` the same blind read had moved beside a `foreman` requiring `~> 1.4`. The test
  # stands where the step stands: a working directory that is not the application.
  def test_a_vendored_lockfile_still_answers_the_downgrade_guard
    gemfile = <<~GEM
      source "https://rubygems.org"

      gem "rails", "8.0.5.1"
      gem "json", "2.19.3"
      gem "js_image_paths", path: "vendor/gems/js_image_paths"
    GEM
    lockfile = <<~LOCK
      PATH
        remote: vendor/gems/js_image_paths
        specs:
          js_image_paths (0.2.0)

      GEM
        remote: https://rubygems.org/
        specs:
          json (2.19.3)
          rails (8.0.5.1)

      DEPENDENCIES
        js_image_paths!
        json (= 2.19.3)
        rails (= 8.0.5.1)
    LOCK
    dir = app(gemfile: gemfile, lockfile: lockfile)
    corpus = FakeCorpus.new(entries: [
      entry(gem: "json", replacement: "json", requirement: "~> 2.6.0",
        condition: { "ruby_at_least" => "3.1" })
    ])

    result = Dir.mktmpdir do |elsewhere|
      Dir.chdir(elsewhere) { preflight(dir, corpus: corpus, ruby: "3.2", rails: "8.1.4") }
    end

    assert_empty result.repairs, "a curated line was written blind: #{result.details.inspect}"
    assert(result.notes.any? { |note| note.include?("downgrade") }, result.notes.inspect)
    assert_includes read(dir, "Gemfile"), %(gem "json", "2.19.3")
  end

  # **"This locks nothing" and "this cannot tell what it locks" are different answers.** A lockfile
  # that vendors a gem with no Gemfile beside it cannot be parsed at all, and that is not an
  # application with nothing locked: the entry is skipped with the reason rather than written,
  # because a curated line that would be a downgrade is the failure the guard exists to refuse.
  def test_an_unreadable_lockfile_does_not_let_a_curated_line_in_blind
    lockfile = <<~LOCK
      PATH
        remote: vendor/gems/js_image_paths
        specs:
          js_image_paths (0.2.0)
    LOCK
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "8.0.5.1"\n), lockfile: lockfile)
    FileUtils.rm(File.join(dir, "Gemfile"))
    corpus = FakeCorpus.new(entries: [
      entry(gem: "loofah", kind: "declared", requirement: "~> 2.0.3")
    ])

    result = preflight(dir, corpus: corpus, ruby: "3.2", rails: "8.1.4")

    assert_empty result.repairs, "a curated line was written blind: #{result.details.inspect}"
    assert(result.notes.any? { |note| note.include?("could not be read") }, result.notes.inspect)
  end

  # **A rung-scoped declaration's companion travels with it to the pin.** The logger line is in the
  # bundle but not required before `require "rails"`, so the Gemfile edit alone leaves the boot
  # exactly as broken; the companion writes the require into the application's own file.
  def test_a_rung_scoped_declaration_carries_its_companion_to_the_pin
    gemfile = %(source "https://rubygems.org"\ngem "rails", "6.1.7.10"\n)
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "application.rb"),
      "require_relative \"boot\"\n\nrequire \"rails\"\n")
    corpus = FakeCorpus.new(entries: [
      entry(gem: "logger", kind: "declared", requirement: "~> 1.4.0",
        condition: { "rails_at_least" => "7.0" })
    ])

    held = preflight(dir, corpus: corpus, ruby: "3.2", rails: "7.0.0")
    assert_equal %w[logger], held.deferred.map { |deferred| deferred["gem"] }

    applied = Preflight.new(root: dir, corpus: corpus, ruby: "3.2", rails: "7.0.0")
      .declare_deferred(held.deferred)

    assert(applied.repairs.any? { |repair| repair.path == "config/application.rb" },
      applied.to_s)
    lines = read(dir, "config/application.rb").lines.map(&:chomp)
    assert_operator lines.index('require "logger"'), :<, lines.index('require "rails"'),
      "the require was written after the constant it exists to define"
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

  # **A declaration is only written where the application already holds the gem.** Measured at the
  # 7.1.6 rung: moving the `database_cleaner` meta-gem to 2.1 keeps `database_cleaner-active_record`
  # 2.0.1 locked, because 2.1.0 asks `>= 2, < 3` — and 2.0.1 calls `SchemaMigration.table_name`,
  # which the rung removed. The component's line is the repair, and `only_if_locked` is what keeps it
  # from being written into an application that does not use the gem.
  def test_a_declaration_marked_only_if_locked_needs_the_gem_in_the_lockfile
    gemfile = %(source "https://rubygems.org"\ngem "rails", "7.0.10"\ngem "database_cleaner", "~> 2.1"\n)
    corpus = FakeCorpus.new(entries: [entry(gem: "database_cleaner-active_record", kind: "declared",
      requirement: "~> 2.1", condition: { "rails_at_least" => "7.1" }, only_if_locked: true)])

    without = app(gemfile: gemfile, lockfile: <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          database_cleaner (2.1.0)

      DEPENDENCIES
        database_cleaner
    LOCK
    result = preflight(without, corpus: corpus, ruby: "2.7", rails: "7.1.6")

    assert_empty result.repairs
    refute_includes read(without, "Gemfile"), "database_cleaner-active_record"
    assert(result.notes.any? { |note| note.include?("does not hold it") },
      "a declaration skipped for the lockfile that does not hold the gem has to say so: " \
      "#{result.notes.inspect}")

    with = app(gemfile: gemfile, lockfile: <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          database_cleaner (2.1.0)
            database_cleaner-active_record (>= 2, < 3)
          database_cleaner-active_record (2.0.1)

      DEPENDENCIES
        database_cleaner
    LOCK
    held = preflight(with, corpus: corpus, ruby: "2.7", rails: "7.1.6")
    assert_equal %w[database_cleaner-active_record], held.deferred.map { |deferred| deferred["gem"] }

    Preflight.new(root: with, corpus: corpus, ruby: "2.7", rails: "7.1.6")
      .declare_deferred(held.deferred)
    assert_includes read(with, "Gemfile"), %(gem "database_cleaner-active_record", "~> 2.1")
  end

  # **A line with no version at all, which is the shape the real Gemfile had.** Measured at
  # ohana-api's 7.1 rung: bullet is declared as a bare `gem 'bullet'`, and 7.0.1 raises from its own
  # dependency check inside `Bundler.require` — `Bullet does not support active_record 7.1.6 yet` —
  # before `app:update` runs a single stage. There is no old requirement to replace, so the rewrite
  # has to *add* one, and the entry is rung-scoped so it lands after the pin rather than beside a
  # Gemfile that still names 7.0.
  def test_an_unversioned_line_scoped_to_the_rung_gains_the_requirement_after_the_pin
    gemfile = %(source "https://rubygems.org"\ngroup :development do\n  gem 'bullet'\nend\ngem "rails", "7.0.10"\n)
    corpus = FakeCorpus.new(entries: [entry(gem: "bullet", replacement: "bullet",
      requirement: "~> 8.0", condition: { "rails_at_least" => "7.1" })])

    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    result = preflight(dir, corpus: corpus, ruby: "2.7", rails: "7.1.6")

    assert_equal %w[bullet], result.deferred.map { |deferred| deferred["gem"] }
    assert_includes read(dir, "Gemfile"), "  gem 'bullet'\n"

    later = Preflight.new(root: dir, corpus: corpus, ruby: "2.7", rails: "7.1.6")
      .declare_deferred(result.deferred)

    assert_equal %w[bullet], later.repairs.map(&:subject)
    assert_includes read(dir, "Gemfile"), %(  gem "bullet", "~> 8.0")
    assert_includes read(dir, "Gemfile"), "end\n", "the group block around the line is still closed"
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

  # **Two lines for one gem, and the era decides which one is written.** The digest states json twice —
  # `~> 1.8` below 3.1, where the app's old line builds and parses, and `~> 2.6` from 3.1, where 1.8.6's
  # `JSON.parse(source, opts)` raises `given 2, expected 1` inside sprockets' manifest read and the
  # application never finishes `initialize!`. The clauses are disjoint, so exactly one rewrite lands: a
  # pair that could both apply would leave the later entry deciding the file, which is the ordering this
  # shape exists to avoid.
  def test_a_gem_with_two_lines_is_rewritten_once_and_by_the_line_its_era_names
    gemfile = %(source "https://rubygems.org"\ngem "rails", "7.1.6"\ngem "json", "~> 1.7.7"\n)
    drawn = ->(requirement, condition) {
      entry(gem: "json", replacement: "json", requirement: requirement, condition: condition)
    }
    entries = [
      drawn.call("~> 1.8", { "ruby_at_least" => "2.2", "ruby_below" => "3.1" }),
      drawn.call("~> 2.6.0", { "ruby_at_least" => "3.1" })
    ]

    old = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    preflight(old, corpus: FakeCorpus.new(entries: entries), ruby: "2.7.8")
    assert_includes read(old, "Gemfile"), %(gem "json", "~> 1.8")
    refute_includes read(old, "Gemfile"), "2.6.0"

    new = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    applied = preflight(new, corpus: FakeCorpus.new(entries: entries), ruby: "3.1.7")
    assert_includes read(new, "Gemfile"), %(gem "json", "~> 2.6.0")
    refute_includes read(new, "Gemfile"), "1.8"
    assert_equal 1, applied.repairs.size,
      "one line was rewritten, not two: the clauses are disjoint"
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

  def test_a_dead_gem_mirror_is_rewritten_in_both_files
    gemfile = %(source "https://rubygems.org"\nsource "https://gems.ruby-china.org"\n)
    gemfile += %(gem "rails", "4.0.0.rc1"\n)
    lockfile = PLAIN_LOCKFILE.sub("remote: https://rubygems.org/",
      "remote: https://gems.ruby-china.org/")
    dir = app(gemfile: gemfile, lockfile: lockfile)

    result = preflight(dir)

    assert_includes read(dir, "Gemfile"), %(source "https://rubygems.org")
    refute_includes read(dir, "Gemfile"), "ruby-china"
    refute_includes read(dir, "Gemfile.lock"), "ruby-china"
    repairs = result.repairs.select { |repair| repair.subject == "dead gem mirror" }
    assert_equal 2, repairs.size, "the Gemfile's source and the lockfile's remote are one fact in two files"
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

  # **A shorthand with no branch means `master`, and `master` is often gone.** Bundler 1.x expanded
  # `github: "owner/name"` to git://… with the default branch `master`; a 2013 repository whose
  # default branch is now `main` re-resolves the source under that name and fails with `Revision
  # master does not exist`. The lockfile names the commit the shorthand meant, so the repair
  # carries it — the same source at the same commit, and the branch lookup never happens. Measured
  # at the 4.0.13 checkpoint of the first real application: the install succeeded from the lock
  # and the pin died on the shorthand it had just rewritten.
  def test_a_github_shorthand_without_a_branch_is_pinned_to_the_locked_revision
    dir = app(gemfile: <<~GEM, lockfile: <<~LOCK)
      source "https://rubygems.org"
      gem "rails", "4.0.0.rc1"
      gem "simple_form", github: "plataformatec/simple_form"
      gem "devise", github: "plataformatec/devise", branch: "rails4"
    GEM
      GIT
        remote: git://github.com/plataformatec/simple_form.git
        revision: 962d56cba3a1f0f5b0d3eb4b1c8d9e0f1a2b3c4d
        specs:
          simple_form (3.0.0.rc)

      GEM
        remote: https://rubygems.org/
        specs:
          rails (4.0.0.rc1)
    LOCK

    result = preflight(dir, corpus: FakeCorpus.new)

    gemfile = read(dir, "Gemfile")
    assert_includes gemfile,
      %(gem "simple_form", git: "https://github.com/plataformatec/simple_form.git", ) +
        %(ref: "962d56cba3a1f0f5b0d3eb4b1c8d9e0f1a2b3c4d")
    assert_includes gemfile, %(gem "devise", git: "https://github.com/plataformatec/devise.git", branch: "rails4"),
      "a line that names its own branch must keep it rather than gain a ref"
    repair = result.repairs.find { |candidate| candidate.text.include?("simple_form") }
    assert_includes repair.note, "master"
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

  # **A fork is a source, not a release.** The gem keeps its name; the requirement goes, because
  # the fork's own gemspec is the version fact, and the line names the repository instead. This is
  # the one move that makes a Rails 8 route possible for a gem whose newest release caps the
  # framework.
  def test_a_forked_entry_rewrites_the_declaration_to_the_repository
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "8.0.5.1"\n) +
      %(gem "js_image_paths", "0.2.0"\n), lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "js_image_paths", kind: "forked",
      replacement: nil, repository: "shoutsid/js_image_paths",
      condition: { "rails_at_least" => "8.0" },
      note: "0.2.0 is the newest release and caps Rails below 8.0")])

    result = preflight(dir, corpus: corpus, rails: "8.0.5.1")

    assert_empty result.repairs, "a rung-scoped line is applied at the pin, not here"
    assert_equal %w[js_image_paths], result.deferred.map { |deferred| deferred["gem"] }

    applied = Preflight.new(root: dir, corpus: corpus, rails: "8.0.5.1")
      .declare_deferred(result.deferred)

    gemfile = read(dir, "Gemfile")
    assert_includes gemfile, %(gem "js_image_paths", github: "shoutsid/js_image_paths")
    refute_includes gemfile, %(gem "js_image_paths", "0.2.0")
    repair = applied.repairs.find { |each| each.subject == "js_image_paths" }
    refute_nil repair, applied.details.inspect
    assert_equal %(gem "js_image_paths", "0.2.0"), repair.text.strip
  end

  # A line that already names a source is a choice this class cannot evaluate: it may be the same
  # fork (nothing to do) or another one (a fact the digest does not hold). It is left alone with a
  # note rather than moved to the digest's repository.
  def test_a_forked_entry_leaves_a_line_that_already_names_a_source
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "8.0.5.1"\n) +
      %(gem "js_image_paths", github: "someone/js_image_paths"\n), lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "js_image_paths", kind: "forked",
      replacement: nil, repository: "shoutsid/js_image_paths",
      condition: { "rails_at_least" => "8.0" })])

    result = preflight(dir, corpus: corpus, rails: "8.0.5.1")
    applied = Preflight.new(root: dir, corpus: corpus, rails: "8.0.5.1")
      .declare_deferred(result.deferred)

    # The protocol rule expands `github:` into a full `git:` URL before the digest pass, so the
    # assertion is on the repository the application chose rather than on its short spelling.
    assert_includes read(dir, "Gemfile"), "someone/js_image_paths"
    assert(applied.notes.any? { |note| note.include?("already names a source") }, applied.notes.inspect)
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

  # **A version rewrite keeps the application's `require: false`.** Measured on `pong`, whose
  # bootsnap line carries the option and whose boot dies inside bootsnap 1.3.2 on the 2.7 era: the
  # option is what keeps Bundler from loading it, and `config/boot` loads it itself. Dropping the
  # option would turn a version repair into a second, unmeasured change.
  def test_a_replaced_entry_keeps_a_require_false_option
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "bootsnap", ">= 1.1.0", require: false\n),
      lockfile: PLAIN_LOCKFILE)
    corpus = FakeCorpus.new(entries: [entry(gem: "bootsnap", kind: "replaced",
      replacement: "bootsnap", requirement: "~> 1.4.9",
      condition: { "ruby_at_least" => "2.6" })])

    result = preflight(dir, corpus: corpus, ruby: "2.7")

    repair = result.repairs.find { |each| each.subject == "bootsnap" }
    refute_nil repair, result.details.inspect
    assert_equal %(gem "bootsnap", "~> 1.4.9", require: false), read(dir, "Gemfile").lines[1].strip
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

  # And when an application does exceed the route's bound, the note says what was not asked
  # about rather than a prefix going out silently: a question cut short reads as a complete
  # answer.
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

  # **A gem's own upgrade can need an edit to the application's code, and an interpreter-scoped entry
  # has to make it here — before the baseline runs.** Measured at the 7.0 rung: the 2.7 era forces
  # shoulda-matchers off 2.8.0 (the digest's `~> 4.1` entry, because 2.8.0 calls `BigDecimal.new` in a
  # class body it loads at boot), shoulda-matchers 3.0 stopped including its matchers automatically,
  # and the *baseline* is then 17 failures with 16 of them matcher methods that are simply absent —
  # `NoMethodError: undefined method `validate_presence_of'`. A companion applied at the gems stage,
  # after the baseline, cannot save that rung; the edits have to be in the tree the baseline reads.
  def test_a_companion_for_an_interpreter_scoped_entry_is_applied_before_the_baseline
    dir = app(gemfile: TEST_GEMFILE, lockfile: TEST_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "spec_helper.rb"),
      "ENV['RAILS_ENV'] ||= 'test'\nrequire 'rspec/rails'\n\nRSpec.configure do |config|\nend\n")
    corpus = FakeCorpus.new(entries: [
      entry(gem: "shoulda-matchers", replacement: "shoulda-matchers", requirement: "~> 4.1",
        condition: { "ruby_at_least" => "2.7" })
    ])

    result = preflight(dir, corpus: corpus, ruby: "2.7.8")

    companion = result.repairs.find { |repair| repair.subject == "shoulda-matchers 3" }
    refute_nil companion, "the companion was not applied: #{result.repairs.map(&:subject).inspect}"
    assert_equal "spec/spec_helper.rb", companion.path
    assert_equal "companion", companion.origin
    assert_includes read(dir, "spec/spec_helper.rb"),
      "require 'rspec/rails'\n#{Companions::SHOULDA_CONFIGURATION}"
    assert_empty(result.notes.grep(/companion/),
      "a companion that applied is not a note: #{result.notes.grep(/companion/).inspect}")

    # The digest's own line moved too, and the two repairs are the same fact seen twice.
    assert_equal ["shoulda-matchers", "shoulda-matchers 3"],
      result.repairs.map { |repair| repair.subject }.sort
  end

  # **A rung-scoped entry's companion is not applied here.** Its gem moves at the pin, so the edits
  # belong at the gems stage — after the baseline, before the pin's resolve — where
  # `Step#apply_companions` keys them to the route's own move. Applying them early is the mistake the
  # digest's own rung-scoped timing already paid for: a rung-scoped rewrite applied early turned the
  # 5.2 baseline red.
  def test_a_companion_for_a_rung_scoped_entry_waits_for_the_gems_stage
    dir = app(gemfile: TEST_GEMFILE, lockfile: TEST_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "spec_helper.rb"),
      "RSpec.configure do |config|\nend\n")
    corpus = FakeCorpus.new(entries: [
      entry(gem: "rspec-rails", replacement: "rspec-rails", requirement: "~> 3.5.0",
        condition: { "rails_at_least" => "5.0" })
    ])

    result = preflight(dir, corpus: corpus, ruby: "2.7.8", rails: "5.0.0")

    assert_nil result.repairs.find { |repair| repair.subject == "rspec-rails 3" },
      "a rung-scoped companion was applied before the pin: #{result.repairs.map(&:subject).inspect}"
    refute_includes read(dir, "spec/spec_helper.rb"), "infer_spec_type_from_file_location!"
  end

  # **An empty companion is two facts, and the record says which.** The helper already carries the
  # block (a move a person finished) or it carries no anchor for it — and the second one is a suite
  # that will stay red with nothing in the record saying why, which is the failure this stage exists
  # to prevent. So the note names the files that were looked at and the gem's own reason.
  def test_a_companion_with_no_anchor_is_a_note_rather_than_a_silent_nothing
    dir = app(gemfile: TEST_GEMFILE, lockfile: TEST_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "spec_helper.rb"), "ENV['RAILS_ENV'] ||= 'test'\n")
    corpus = FakeCorpus.new(entries: [
      entry(gem: "shoulda-matchers", replacement: "shoulda-matchers", requirement: "~> 4.1",
        condition: { "ruby_at_least" => "2.7" })
    ])

    result = preflight(dir, corpus: corpus, ruby: "2.7.8")

    note = result.notes.find { |line| line.include?("companion for shoulda-matchers") }
    refute_nil note, "no note was written: #{result.notes.inspect}"
    assert_includes note, "spec/spec_helper.rb"
    assert_includes note, "spec/rails_helper.rb"
    assert_includes note, "stopped including its matchers"
  end

  # **A method the rung's interpreter removed, in a file the application loads before anything else.**
  # Measured at the 7.2 rung, the first on the 3.2 era: every stage after the install died with
  # `config/boot.rb:4:in '<top (required)>': undefined method 'exists?' for File:Class (NoMethodError)`,
  # and `bin/rails` loads that file itself — so `app:update`, the command that would replace it, could
  # not run either. The baseline, the database and the suite all read it, which is what makes it the
  # preflight's business.
  def test_a_method_the_interpreter_removed_is_repaired_before_the_baseline
    dir = app(lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "boot.rb"),
      "ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __FILE__)\n" \
      "require 'bundler/setup' if File.exists?(ENV['BUNDLE_GEMFILE'])\n")

    result = preflight(dir, corpus: FakeCorpus.new)

    repair = result.repairs.find { |each| each.subject == "File.exists?" }
    refute_nil repair, "the boot file was not repaired: #{result.repairs.map(&:subject).inspect}"
    assert_equal "config/boot.rb", repair.path
    assert_equal 2, repair.line
    assert_includes read(dir, "config/boot.rb"), "File.exist?(ENV['BUNDLE_GEMFILE'])"
  end

  # **`Model.exists?` is a different method on a different receiver.** A rewrite that dropped the
  # receiver would break every ActiveRecord query in the tree, so only the three the interpreter removed
  # are touched.
  def test_a_relation_exists_is_not_the_removed_method
    dir = app(lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "user.rb"), "class User\n  User.exists?(1)\nend\n")

    result = preflight(dir, corpus: FakeCorpus.new)

    assert_nil result.repairs.find { |each| each.subject.to_s.include?("exists?") },
      "a relation's exists? was rewritten: #{result.repairs.map(&:subject).inspect}"
    assert_includes read(dir, "app/models/user.rb"), "User.exists?(1)"
  end

  # **A companion's stage follows its entry's clause, and the deferred stage is the rung-scoped one.**
  # An interpreter-scoped entry's companion is applied beside its line in the preflight, because the
  # baseline that needs it runs before the pin; a rung-scoped entry's line moves *after* the pin, so its
  # edits belong there too. Measured at the 7.2 rung: `factory_girl_rails`'s rename is scoped by
  # `rails_at_least 7.2`, and the application's 93 `FactoryGirl` call sites have to move with the line or
  # the suite the pin leaves behind cannot load.
  def test_a_deferred_entrys_companion_is_applied_where_its_line_is
    gemfile = %(source "https://rubygems.org"\ngem "rails", "4.0.0.rc1"\n) +
      %(gem "factory_girl_rails", "~> 4.0"\n)
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec", "factories"))
    File.write(File.join(dir, "spec", "factories", "user_factory.rb"),
      "FactoryGirl.define do\n  factory :user do\n  end\nend\n")

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "7.2.0")
      .declare_deferred([
        entry(gem: "factory_girl_rails", replacement: "factory_bot_rails", requirement: "~> 4.9",
          condition: { "rails_at_least" => "7.2" })
      ])

    assert_includes read(dir, "Gemfile"), %(gem "factory_bot_rails", "~> 4.9")
    assert_includes read(dir, "spec/factories/user_factory.rb"), "FactoryBot.define do"
    assert(result.repairs.any? { |each| each.subject == "factory_bot" },
      "the companion was not applied with its line: #{result.repairs.map(&:subject).inspect}")
  end

  # **A method the *framework* removed is the rung's fact, not the interpreter's, so its repair is
  # scoped by the rung.** Measured: activerecord 7.1 has both `check_pending!` and `check_all_pending!`
  # and 7.2 has only the second, so the application's own `spec/spec_helper.rb:20` and
  # `test/test_helper.rb:6` die with `undefined method `check_pending!'` — and the *baseline* cannot see
  # it, because the baseline runs on the release the application is leaving. The rewrite is the
  # framework's own prescription rather than a guess: 7.1's body reads "This is deprecated in favor of
  # +check_all_pending!+".
  def test_a_method_the_framework_removed_is_repaired_for_the_rung_that_removed_it
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "7.2.0"\n), lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    FileUtils.mkdir_p(File.join(dir, "test"))
    pending_line = "ActiveRecord::Migration.check_pending! if defined?(ActiveRecord::Migration)\n"
    File.write(File.join(dir, "spec", "spec_helper.rb"), pending_line)
    File.write(File.join(dir, "test", "test_helper.rb"),
      "class T\n  ActiveRecord::Migration.check_pending!\nend\n")

    at_the_rung = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "7.2.0")
      .send(:framework_removal_repairs)

    assert_equal %w[spec/spec_helper.rb test/test_helper.rb], at_the_rung.map(&:path),
      "the rung's own removal was not repaired: #{at_the_rung.map(&:path).inspect}"
    assert_includes read(dir, "spec/spec_helper.rb"), "check_all_pending!"

    # And the same tree one rung lower owes nothing: `check_all_pending!` is not there to move to, and
    # a repair for a removal this move does not meet is not a repair at all.
    File.write(File.join(dir, "spec", "spec_helper.rb"), pending_line)
    below = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "7.1.0")
      .send(:framework_removal_repairs)

    assert_empty below, "a rung below the removal repaired it: #{below.map(&:path).inspect}"
    assert_includes read(dir, "spec/spec_helper.rb"), "check_pending!"
  end

  # **A predicate the release removed, whose matcher the application's specs spell the old way.** The
  # ladder carries no change for it at all — measured, `success` appears zero times in
  # `data/rails_ladder.json` — so this is a fact about the *release* rather than about a rung's
  # documented change, which is what the framework table is for. Measured at the 6.0 rung: every failing
  # example there is a controller spec asserting `expect(response).to be_success`, because RSpec's
  # `be_success` is a dynamic predicate matcher and `ActionDispatch::TestResponse#success?` was
  # deprecated in 5.2 and removed in 6.0, where `successful?` comes from `Rack::Response::Helpers`.
  def test_a_predicate_the_release_removed_moves_the_matcher_that_spells_it
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "6.0.0"\n), lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "bids_controller_spec.rb"),
      "it { expect(response).to be_success }\n")

    at_the_rung = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "6.0.0")
      .send(:framework_removal_repairs)

    assert_equal 1, at_the_rung.size, "the rung's own removal was not repaired"
    assert_includes read(dir, "spec/bids_controller_spec.rb"), "be_successful"

    # And the rung below owes nothing: `success?` is still there at 5.2.
    File.write(File.join(dir, "spec", "bids_controller_spec.rb"),
      "it { expect(response).to be_success }\n")
    below = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "5.2.0")
      .send(:framework_removal_repairs)

    assert_empty below, "a rung below the removal repaired it: #{below.map(&:path).inspect}"
  end

  # **Rails 7.1 removed the format argument from `to_s`, and the successor is `to_fs`.** Measured
  # on volunteer-portal's 7.1.6 suite: three errors are `ArgumentError: wrong number of arguments
  # (given 1, expected 0)` at `timestamp.to_s(:db)`, in the resolver and in the tests that compare
  # its answer. The rule is narrow on purpose: only a literal symbol argument is the removed API;
  # `to_s` with no argument is Ruby's own method and is left alone. The rung below owed nothing.
  def test_a_time_format_call_moves_to_to_fs_at_the_7_1_rung
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "7.1.6"\n),
      lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "user.rb"),
      "class User\n  def stamp\n    updated_at.to_s(:db)\n  end\nend\n" \
      "created_at.to_formatted_s(:short)\nupdated_at.to_s\n")

    at_the_rung = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.1.6")
      .send(:time_format_repairs)
    body = read(dir, "app/models/user.rb")

    assert_equal 2, at_the_rung.size, "the two formatted calls were not repaired"
    assert_includes body, "updated_at.to_fs(:db)"
    assert_includes body, "created_at.to_fs(:short)"
    assert_includes body, "updated_at.to_s\n", "a bare `to_s` is not the removed method"

    File.write(File.join(dir, "app", "models", "user.rb"),
      "updated_at.to_s(:db)\ncreated_at.to_formatted_s(:short)\nupdated_at.to_s\n")
    below = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.0.10")
      .send(:time_format_repairs)

    assert_empty below, "a rung below the removal repaired it: #{below.map(&:path).inspect}"
    assert_includes read(dir, "app/models/user.rb"), "updated_at.to_s(:db)"
  end

  # **A removal name is rewritten only where it *ends*, because one of these names is a prefix of
  # another.** `be_success` is a prefix of `be_successful`, so a plain `gsub` turns a line the
  # application had already migrated into `be_successfulful` — and a rewrite that has to run before
  # another one to be safe is an ordering rather than a rule. The guard also has to keep `File.exists?`
  # matching: `?` is not a word character, so the lookahead asks about the character after it.
  def test_a_removal_name_is_rewritten_only_where_it_ends
    dir = app(gemfile: %(source "https://rubygems.org"\ngem "rails", "6.0.0"\n), lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "a_spec.rb"),
      "it { expect(response).to be_success }\n" \
        "it { expect(response).to be_successful }\n" \
        "it { expect(x).to be_successful_now }\n")

    repairs = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "3.2", rails: "6.0.0")
      .send(:framework_removal_repairs)

    assert_equal 1, repairs.size, "a name that is a prefix of another was rewritten twice"
    assert_equal [
      "it { expect(response).to be_successful }",
      "it { expect(response).to be_successful }",
      "it { expect(x).to be_successful_now }"
    ], read(dir, "spec/a_spec.rb").lines.map(&:chomp),
      "a line the application had already migrated was rewritten again"
  end

  # **A Devise mailer needs a host before the baseline can run.** Measured on
  # rails-devise-graphql's 6.0.3.3 baseline: creating a confirmable user called
  # `confirmation_url`, the mailer raised `Missing host to link to!`, and the rest of the
  # GraphQL/User examples failed behind it. The repair is in the test environment because that
  # is where the suite runs, and it is written by the preflight because a red baseline is not
  # a suite the repair agent is allowed to touch.
  def test_a_devise_test_environment_without_a_mailer_host_gets_one_before_the_baseline
    gemfile = <<~GEM
      source "https://rubygems.org"
      gem "rails", "4.2.11"
      gem "devise", "~> 3.5"
    GEM
    dir = app(gemfile: gemfile, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config", "environments"))
    File.write(File.join(dir, "config", "environments", "test.rb"), <<~RUBY)
      Rails.application.configure do
        config.cache_classes = true
      end
    RUBY

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "4.2.11").run

    host = result.repairs.find { |repair| repair.subject == "action_mailer.default_url_options" }
    refute_nil host, "the Devise baseline would still raise Missing host"
    assert_equal "config/environments/test.rb", host.path
    assert_includes read(dir, "config/environments/test.rb"),
      "config.action_mailer.default_url_options = { host: \"localhost\" }"

    # A second pass is not a second line: the setting is already there.
    again = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "4.2.11").run
    assert_empty again.repairs.select { |repair| repair.subject == "action_mailer.default_url_options" }
  end

  # **A repository's own magic-encoding check is a baseline fact, not a move's.** 19wu's spec calls
  # `bin/magic_encoding_find`, which reports every app/lib/spec file with a non-ASCII byte and no
  # `# encoding:` in its first two lines. The repository also ships `bin/magic_encoding_fix`; this
  # rule writes the same comment before the baseline so the move is measured against a green suite.
  def test_a_repository_magic_encoding_check_gets_its_comment_before_the_baseline
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "magic_encoding_find"), "#!/usr/bin/env ruby\n")
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "app", "models", "thing.rb"), "# 中文\nclass Thing; end\n")
    File.write(File.join(dir, "app", "models", "plain.rb"), "class Plain; end\n")

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.1", rails: "4.0.0").run

    repaired = result.repairs.select { |repair| repair.subject == "magic encoding" }
    assert_equal ["app/models/thing.rb"], repaired.map(&:path)
    assert_includes read(dir, "app/models/thing.rb"), "# encoding: utf-8\n# 中文"
    refute_includes read(dir, "app/models/plain.rb"), "# encoding: utf-8"

    # A second pass does not add a second comment.
    again = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.1", rails: "4.0.0").run
    assert_empty again.repairs.select { |repair| repair.subject == "magic encoding" }
  end

  # **Rails 4.1 deleted Active Record's mass-assignment whitelist.** The 3.2 sample's boot dies
  # on the missing method before the suite; the line is the 3.2 fact, not the move.
  def test_a_rails_4_1_boot_removes_the_deleted_whitelist_attributes_setting
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config"))
    path = File.join(dir, "config", "application.rb")
    File.write(path, <<~RUBY)
      module Sample
        class Application < Rails::Application
          config.active_record.whitelist_attributes = true
        end
      end
    RUBY

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "1.9.3", rails: "4.1.16").run

    repair = result.repairs.find { |each| each.subject == "whitelist_attributes" }
    refute_nil repair
    refute_includes read(dir, "config/application.rb"), "config.active_record.whitelist_attributes = true"
    assert_includes read(dir, "config/application.rb"), "removed: Rails 4.1"
  end

  # **A test-only gem and the framework's test adapter can have an empty minitest window.** The
  # project's `test_gem_removal` class is the permission; the suite is still the gate.
  def test_maxitest_is_removed_only_when_the_project_allows_it
    lock = <<~LOCK
      GEM
        specs:
          maxitest (3.6.0)
            minitest (>= 5.0.0, < 5.14.0)
          minitest-rails (7.1.1)
            minitest (~> 5.20)
          rails (7.1.0)
    LOCK
    gemfile = %(source "https://rubygems.org"\ngem "rails", "7.1.0"\ngem "maxitest", require: false\n)
    dir = app(gemfile: gemfile, lockfile: lock)

    denied = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.1.6",
      decision_policy: { "test_gem_removal" => "ask" }).run
    assert_empty denied.repairs.select { |repair| repair.subject == "maxitest" }
    assert_includes read(dir, "Gemfile"), "maxitest"

    allowed = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.1.6",
      decision_policy: { "test_gem_removal" => "allow" }).run
    repair = allowed.repairs.find { |each| each.subject == "maxitest" }
    refute_nil repair
    refute_includes read(dir, "Gemfile"), "maxitest"
  end

  # **The lock can still name the adapter the previous rung used.** volunteer_portal's 7.1.6 pin
  # resolves minitest-rails 7.1 (minitest ~> 5.20) while the lock still says 7.0.1 (minitest
  # ~> 5.10), and maxitest caps minitest below 5.14. The project allowed the removal, so the rung's
  # adapter is the floor rather than the stale lock's.
  def test_maxitest_is_removed_at_rails_7_1_when_the_lock_still_names_the_7_0_adapter
    lock = <<~LOCK
      GEM
        specs:
          maxitest (3.6.0)
            minitest (>= 5.0.0, < 5.14.0)
          minitest-rails (7.0.1)
            minitest (~> 5.10)
          rails (7.0.8)
    LOCK
    gemfile = %(source "https://rubygems.org"\ngem "rails", "7.0.8"\ngem "minitest-rails", "~> 7.0.1"\ngem "maxitest", require: false\n)
    dir = app(gemfile: gemfile, lockfile: lock)

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.1.6",
      decision_policy: { "test_gem_removal" => "allow" }).run

    repair = result.repairs.find { |each| each.subject == "maxitest" }
    refute_nil repair, "the 7.1 adapter's minitest floor was read from the stale lock"
    refute_includes read(dir, "Gemfile"), "maxitest"
    assert_includes repair.note, "minitest-rails asks 5.20"
  end

  # **A lockfile's BUNDLED WITH is metadata, and a prerelease from another machine is not a gem.**
  # caturday_api's lock says 2.0.0.pre.3; Rails 4.2 declares `bundler < 2.0`, so every era tries a
  # Bundler that is not there. Removing the line lets the era's Bundler write its own.
  def test_a_rails_4_lockfile_with_a_bundler_2_prerelease_has_the_line_removed
    lock = "GEM\n  specs:\n    rails (4.2.11.3)\nBUNDLED WITH\n   2.0.0.pre.3\n"
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: lock)

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.2", rails: "5.0.7.2").run

    repair = result.repairs.find { |each| each.subject == "BUNDLED WITH" }
    refute_nil repair, "the lock's prerelease was left for every era to fail on"
    refute_includes read(dir, "Gemfile.lock"), "BUNDLED WITH"
    assert_includes repair.note, "Rails 4.x"
  end

  def test_the_lockfile_metadata_class_can_be_denied
    lock = "GEM\n  specs:\n    rails (4.2.11.3)\nBUNDLED WITH\n   2.0.0.pre.3\n"
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: lock)

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.2", rails: "5.0.7.2",
      decision_policy: { "lockfile_metadata" => "deny" }).run

    assert_empty result.repairs.select { |each| each.subject == "BUNDLED WITH" }
    assert_includes read(dir, "Gemfile.lock"), "BUNDLED WITH"
  end

  # **Rails 5.0 removed ActiveModel::Serializers::Xml, and MongoMapper still includes it.**
  # Measured on caturday_api's 5.0.7.2 boot: the application dies before the first example with
  # `uninitialized constant ActiveModel::Serializers::Xml`; the extracted gem is the declaration.
  def test_a_mongo_mapper_app_gets_the_extracted_xml_serializer_at_rails_5
    lock = "#{PLAIN_LOCKFILE}    mongo_mapper (0.13.1)\n"
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: lock)

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.2", rails: "5.0.7.2").run

    refute_nil result.repairs.find { |repair| repair.subject == "activemodel-serializers-xml" }
    assert_includes read(dir, "Gemfile"),
      'gem "activemodel-serializers-xml", "~> 1.0"'

    older = app(gemfile: PLAIN_GEMFILE, lockfile: lock)
    older_result = Preflight.new(root: older, corpus: FakeCorpus.new, ruby: "2.1", rails: "4.2.11").run
    assert_empty older_result.repairs.select { |repair| repair.subject == "activemodel-serializers-xml" },
      "the module is still in Active Model on Rails 4.2"
  end

  # **A Rails 7 application can name a namespace directory as an autoload root and hide the
  # namespace it defines.** volunteer_portal's `config/application.rb` does exactly this for
  # `app/graphql/types`: the files say `module Types`, and the suite's `Types::SensitiveObject`
  # dies with `uninitialized constant Types`. The sibling roots are kept because their files
  # define top-level constants, which is what a root means.
  APPLICATION_WITH_AUTOLOAD_ROOTS = <<~RUBY
    module Portal
      class Application < Rails::Application
        config.autoload_paths.concat [
          Rails.root.join('app/graphql/types'),
          Rails.root.join('app/graphql/loaders'),
          Rails.root.join('app/graphql/resolvers')
        ]
      end
    end
  RUBY

  def test_a_nested_namespace_autoload_root_is_removed_for_rails_7
    dir = autoload_app
    FileUtils.mkdir_p(File.join(dir, "app", "graphql", "types"))
    File.write(File.join(dir, "app", "graphql", "types", "sensitive_object.rb"),
      "module Types\n  class SensitiveObject; end\nend\n")

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.0.10").run

    repaired = result.repairs.select { |repair| repair.subject == "nested autoload path" }
    assert_equal ["config/application.rb"], repaired.map(&:path)
    text = read(dir, "config/application.rb")
    refute_includes text, "Rails.root.join('app/graphql/types')"
    assert_includes text, "Rails.root.join('app/graphql/loaders')",
      "the loaders directory defines AssociationLoader, so it really is a root"
    assert_includes text, "Types namespace under app/graphql"
    assert_empty Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.0.10").run
      .repairs.select { |repair| repair.subject == "nested autoload path" },
      "a second pass finds nothing left to do"
  end

  def test_a_nested_autoload_root_is_kept_when_its_files_are_top_level
    dir = autoload_app
    FileUtils.mkdir_p(File.join(dir, "app", "graphql", "types"))
    File.write(File.join(dir, "app", "graphql", "types", "sensitive_object.rb"),
      "class SensitiveObject; end\n")

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "7.0.10").run

    assert_empty result.repairs.select { |repair| repair.subject == "nested autoload path" }
    assert_includes read(dir, "config/application.rb"), "Rails.root.join('app/graphql/types')"
  end

  def test_the_nested_autoload_rule_does_not_run_before_rails_7
    dir = autoload_app
    FileUtils.mkdir_p(File.join(dir, "app", "graphql", "types"))
    File.write(File.join(dir, "app", "graphql", "types", "sensitive_object.rb"),
      "module Types\n  class SensitiveObject; end\nend\n")

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.7", rails: "6.1.7.10").run

    assert_empty result.repairs.select { |repair| repair.subject == "nested autoload path" }
    assert_includes read(dir, "config/application.rb"), "Rails.root.join('app/graphql/types')"
  end

  def autoload_app
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "application.rb"), APPLICATION_WITH_AUTOLOAD_ROOTS)
    FileUtils.mkdir_p(File.join(dir, "app", "graphql", "loaders"))
    File.write(File.join(dir, "app", "graphql", "loaders", "record_loader.rb"),
      "class RecordLoader; end\n")
    FileUtils.mkdir_p(File.join(dir, "app", "graphql", "resolvers"))
    File.write(File.join(dir, "app", "graphql", "resolvers", "event_resolver.rb"),
      "module EventResolver; end\n")
    dir
  end

  # **A squiggly heredoc in an eval is Ruby 2.3 syntax, and the body is still Ruby.** Measured on
  # brimir's 5.1 baseline: `eval <<~END` in a controller test is a parse error on the 2.2 era,
  # before the first example. `<<-` is the same program for an eval body — indentation at the top
  # level is not significant — and only the eval families are rewritten, because a squiggly heredoc
  # used as string content may depend on its dedent.
  def test_a_squiggly_heredoc_in_an_eval_is_rewritten_for_a_ruby_below_2_3
    dir = app(gemfile: PLAIN_GEMFILE, lockfile: PLAIN_LOCKFILE)
    FileUtils.mkdir_p(File.join(dir, "test", "controllers"))
    path = File.join(dir, "test", "controllers", "tickets_controller_test.rb")
    File.write(path, <<~RUBY)
      test "a fixture class" do
        eval <<~END
          class RestClient::Resource
          end
        END
      end
    RUBY

    result = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.2.9", rails: "5.1.6").run

    repaired = result.repairs.find { |repair| repair.subject == "eval heredoc" }
    refute_nil repaired, "the 2.2 baseline still cannot parse the test"
    assert_includes read(dir, "test/controllers/tickets_controller_test.rb"), "eval <<-END"
    refute_includes read(dir, "test/controllers/tickets_controller_test.rb"), "eval <<~END"

    # The same file on an interpreter that understands the syntax is left alone.
    File.write(path, "eval <<~END\n  class RestClient::Resource\n  end\nEND\n")
    above = Preflight.new(root: dir, corpus: FakeCorpus.new, ruby: "2.5.9", rails: "5.1.6").run
    assert_empty above.repairs.select { |repair| repair.subject == "eval heredoc" }
    assert_includes read(dir, "test/controllers/tickets_controller_test.rb"), "eval <<~END"
  end
end
