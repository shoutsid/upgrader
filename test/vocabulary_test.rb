# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "agents_fyi/upgrader"

# The upgrader's vocabulary against the service's, because the upgrader is the client.
#
# `Record`'s four verdicts are the four words the service stores a run's verdict in, and they
# are written in two packages on purpose: this tool is a *client* of the service, not a
# dependency of it — it does not import the service and cannot, in Ruby — so the check lives on
# the side that has to adapt, which is this one.
#
# Both are gone with `api/`. What is left is the schema the deployment holds:
# `db/structure.sql` declares `upgrade_verdict` as a type and `upgrade_runs.verdict`
# as a column of it.
#
# `ledger.rb` is in here too. It holds a copy of the words so it can recognise what a previous
# process wrote, and a third list is exactly the drift this test exists to make
# impossible — the ledger's `SETTLED_VERDICTS` is asserted to be a subset as well, because a
# word settled by one side and unknown to the other is work redone or, worse, work reported as
# done.
class VocabularyTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SCHEMA = File.join(ROOT, "db", "structure.sql")
  LADDER = File.join(ROOT, "data", "rails_ladder.json")
  # The type's own block, so a pattern that drifted cannot pick up another enum's values.
  VERDICT_TYPE = /CREATE TYPE public\.upgrade_verdict AS ENUM \(\n(.*?)\n\);/m

  # **Every rule and every gap names a change the ladder carries, spelled the way the ladder spells
  # it.** A rule finds its change by `subject`, and a subject that differs from the ladder's by a
  # character is a rule that never fires and never says so — the whole residue would report the change
  # as uncovered while the rule sat there looking written. A *gap* keyed on a misspelled subject fails
  # the same way and more quietly: it falls back to the generic sentence, so the specific reason
  # somebody wrote is never read. This is the same class of failure as the two vocabularies above, one
  # layer up: the ladder is the service's, and this tool has to agree with it.
  def test_every_rule_and_gap_names_a_change_the_ladder_carries
    changes = JSON.parse(File.read(LADDER))["steps"].flat_map { |step| step["changes"] }
    subjects = changes.map { |change| change["subject"] }

    assert_operator subjects.size, :>=, 95, "the ladder stopped being read, so this proves nothing"
    rewrites = AgentsFyi::Upgrader::Rewrites
    named = rewrites::RULES.map(&:subject) + rewrites::GAPS.keys + rewrites::PARTIAL.keys +
            rewrites::SURVEYS.map(&:subject)
    assert_empty named.uniq - subjects,
      "a rule or gap names a change the ladder does not carry, so it can never be reached"
    assert_empty rewrites.inert(changes), "a rule outlives the change it belongs to"
  end

  # The values `upgrade_verdict` declares, read out of the schema of record.
  #
  # The pattern is narrow — the type's own block and the `'value'` lines inside it — and the
  # test below asserts it found four rather than trusting it: a set equality against a pattern
  # that matched nothing passes vacuously.
  def service_verdicts
    @service_verdicts ||= begin
      body = File.read(SCHEMA)[VERDICT_TYPE, 1]
      refute_nil body, "the schema no longer declares an upgrade_verdict type"
      body.scan(/'([a-z_]+)'/).flatten.to_set
    end
  end

  def upgrader_verdicts
    record = AgentsFyi::Upgrader::Record
    [record::PASSED, record::FAILED, record::REFUSED, record::UNVERIFIED].to_set
  end

  def test_the_reader_actually_finds_the_services_declaration
    # A guard on the guard: every comparison below is a set equality and would pass
    # against a pattern that matched nothing at all.
    assert_equal 4, service_verdicts.size, "the service's declaration was read as #{service_verdicts.inspect}"
  end

  def test_the_service_can_name_every_verdict_the_upgrader_decides
    assert_equal service_verdicts, upgrader_verdicts,
      "the upgrader writes a verdict the service cannot store, or the reverse"
  end

  def test_the_ledger_speaks_the_same_four_words
    ledger = AgentsFyi::Upgrader::Ledger
    assert_equal service_verdicts, [ledger::PASSED, ledger::FAILED, ledger::REFUSED, ledger::UNVERIFIED].to_set
    assert ledger::SETTLED_VERDICTS.all? { |word| service_verdicts.include?(word) },
      "the ledger settles a verdict the service has never heard of"
  end

  # The vocabulary is only the service's if the column a run is stored in carries the type this
  # list was read from. A value declared in `upgrade_verdict` beside a column declared as plain
  # `text` would be two vocabularies that happen to look alike, and the insert that fails is on
  # the route whose whole job is recording what a run established.
  def test_the_verdict_is_stored_in_the_column_the_type_is_declared_for
    assert_match(/^\s+verdict public\.upgrade_verdict NOT NULL,$/, File.read(SCHEMA),
      "upgrade_runs.verdict is not declared with the verdict type")
  end
end
