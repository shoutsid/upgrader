# frozen_string_literal: true

require "minitest/autorun"
require "set"
require "agents_fyi/upgrader"

# The upgrader's own vocabulary, checked without the service.
#
# The four verdicts are the words a run is recorded under, and the ledger keeps its own copy so
# a previous process's book can be read back. That copy is the risk: a word one side writes and
# the other does not recognise is work redone, or worse, work reported as done. The agreement
# with the *service's* schema is a cross-repository claim and lives in the service's contract
# suite (`test/contracts/upgrader/vocabulary_test.rb`); this file checks the half the client can
# prove alone — that its words are distinct, that its ledger settles only words it writes, and
# that both lists have the shape the rest of the client assumes.
class VocabularyTest < Minitest::Test
  Record = AgentsFyi::Upgrader::Record
  Ledger = AgentsFyi::Upgrader::Ledger

  def record_verdicts
    [Record::PASSED, Record::FAILED, Record::REFUSED, Record::UNVERIFIED]
  end

  def ledger_verdicts
    [Ledger::PASSED, Ledger::FAILED, Ledger::REFUSED, Ledger::UNVERIFIED]
  end

  def test_the_client_writes_four_distinct_verdicts
    # A guard on the guard: the set comparison below would pass vacuously against a list
    # that had silently lost a member.
    assert_equal 4, record_verdicts.uniq.size
    assert_equal 4, ledger_verdicts.uniq.size
  end

  def test_every_verdict_is_a_lowercase_word_a_database_can_store
    record_verdicts.each do |word|
      assert_match(/\A[a-z_]+\z/, word, "#{word.inspect} is not the shape of a stored verdict")
    end
  end

  def test_the_ledger_speaks_the_same_four_words
    assert_equal record_verdicts.to_set, ledger_verdicts.to_set,
      "the ledger and the record disagree about what a verdict is called"
    assert Ledger::SETTLED_VERDICTS.all? { |word| record_verdicts.include?(word) },
      "the ledger settles a verdict the record does not write"
  end
end
