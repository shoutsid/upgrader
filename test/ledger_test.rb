# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "agents/upgrader/ledger"

# The durable memory of what has been walked. What is asserted here is every case in
# which the wrong answer is expensive rather than merely wrong: work redone for weeks,
# or work reported done that never ran.
class LedgerTest < Minitest::Test
  REPO = "https://github.com/huginn/huginn"
  COMMIT = "2e3c74eb19170410426c5b99c768a3b6c1698848"
  MACHINE = "ruby 3.3.12"
  OTHER_MACHINE = "ruby 2.7.8 (ruby:2.7-slim)"

  FROM = "6.0.4.4"
  TO = "6.1.0"

  def ledger_at(path, machine: MACHINE)
    Agents::Upgrader::Ledger.new(path: path, machine: machine).read!
  end

  def record(ledger, verdict:, to: TO, commit: COMMIT, note: "")
    ledger.record(
      repo: REPO, commit: commit, from_version: FROM, to_version: to,
      verdict: verdict, baseline: "green", note: note
    )
  end

  def test_a_verdict_survives_a_round_trip_through_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      record(ledger_at(path), verdict: Agents::Upgrader::Ledger::PASSED, note: "the suite was green")

      read = ledger_at(path)
      entry = read.find(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)

      assert_equal 1, read.size
      assert_equal Agents::Upgrader::Ledger::PASSED, entry.verdict
      assert_equal "green", entry.baseline
      assert_equal MACHINE, entry.machine
      assert_equal 1, entry.attempts
      assert_equal "the suite was green", entry.note
      refute_empty entry.recorded_at
    end
  end

  # **Delivery survives the file too, and a new record clears it.** The loop reads it in a later
  # process to retry a rung it must not re-walk; a new attempt at the move is a different commit, so
  # the old delivery would be evidence about another tree.
  def test_delivery_round_trips_and_a_new_record_clears_it
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      ledger = ledger_at(path)
      record(ledger, verdict: Agents::Upgrader::Ledger::PASSED)
      ledger.deliver(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO,
        state: { "attempted" => true, "delivered" => false, "commit" => "c0ffee01" })

      read = ledger_at(path).find(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
      assert_equal "c0ffee01", read.delivery["commit"]
      assert_equal false, read.delivery["delivered"]
      refute_empty read.delivery["attempted_at"]

      record(ledger, verdict: Agents::Upgrader::Ledger::PASSED)
      cleared = ledger_at(path).find(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
      assert_nil cleared.delivery, "a new record kept a delivery about another attempt"
    end
  end

  def test_a_missing_file_is_an_empty_ledger_rather_than_an_error
    Dir.mktmpdir do |dir|
      ledger = ledger_at(File.join(dir, "ledger.json"))

      assert_equal 0, ledger.size
      assert_nil ledger.set_aside!
      refute ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
    end
  end

  # A refusal is a fact about the move and reaches the same answer however many times it
  # is asked, so it settles on the first attempt. A failure is not: the usual reason is
  # a release that was briefly unavailable, and settling it would abandon work that
  # would have succeeded.
  def test_a_pass_and_a_refusal_settle_on_arrival_and_the_other_two_do_not
    settled_on_arrival = [
      Agents::Upgrader::Ledger::PASSED,
      Agents::Upgrader::Ledger::REFUSED
    ]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      ledger = ledger_at(path)
      settled_on_arrival.each_with_index do |verdict, index|
        record(ledger, verdict: verdict, to: "6.#{index}.0")

        assert ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: "6.#{index}.0"),
          "#{verdict} is settled on arrival"
      end

      record(ledger, verdict: Agents::Upgrader::Ledger::FAILED, to: "6.9.0")

      refute ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: "6.9.0"),
        "a failure is retried rather than believed"
      assert_equal 1, ledger.attempts(repo: REPO, commit: COMMIT, from_version: FROM, to_version: "6.9.0")

      record(ledger, verdict: Agents::Upgrader::Ledger::UNVERIFIED, to: "6.8.0")

      refute ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: "6.8.0"),
        "a run that established nothing was believed"
      assert_equal 0, ledger.attempts(repo: REPO, commit: COMMIT, from_version: FROM, to_version: "6.8.0"),
        "a run that established nothing spent one of the move's attempts"
    end
  end

  # **The trap this rule was written for.** `unverified` means the suite could not run — a fact about
  # the environment rather than about the move — so an environment that is fixed has to be able to
  # measure the move again. Measured on the live walk: 4.0.0 -> 4.1.0 was recorded `unverified` three
  # times because the deployment had not supplied `RAILS_SECRET_TOKEN`, the ceiling then settled the
  # move for ever, and the loop slept while the queue still asked for it — the corpus publishing
  # "will be attempted again" and the ledger refusing to.
  def test_an_unverified_step_is_retried_however_many_times_it_has_run
    Dir.mktmpdir do |dir|
      ledger = ledger_at(File.join(dir, "ledger.json"))
      ceiling = Agents::Upgrader::Ledger::MAX_ATTEMPTS

      (ceiling + 2).times do |attempt|
        record(ledger, verdict: Agents::Upgrader::Ledger::UNVERIFIED)

        refute ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO),
          "attempt #{attempt + 1} left the move settled although nothing was established"
        assert_equal 0, ledger.attempts(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO),
          "an unverified run counted toward the ceiling"
      end

      # And the ceiling still bounds a move that *fails*, which is the case it exists for.
      ceiling.times { record(ledger, verdict: Agents::Upgrader::Ledger::FAILED) }
      assert ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO),
        "a move that failed at the ceiling is still retried for ever"
    end
  end

  # The ceiling, which is what stops a step that fails for a reason that never changes
  # from being attempted on every cycle for the life of the service.
  def test_a_failed_step_is_retried_until_the_ceiling_and_then_settled
    Dir.mktmpdir do |dir|
      ledger = ledger_at(File.join(dir, "ledger.json"))
      ceiling = Agents::Upgrader::Ledger::MAX_ATTEMPTS

      (1..ceiling).each do |attempt|
        record(ledger, verdict: Agents::Upgrader::Ledger::FAILED)
        settled = ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
        attempts = ledger.attempts(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)

        assert_equal attempt, attempts
        if attempt < ceiling
          refute settled, "attempt #{attempt} of #{ceiling} is still worth retrying"
        else
          assert settled, "at the ceiling the step is settled whatever happened"
        end
      end
    end
  end

  # `unverified` is a fact about the interpreter as much as about the repository: an
  # application that cannot be walked on Ruby 3.3 may be walkable on 2.7, which is why
  # the images are one per interpreter. A verdict from another machine is a different
  # piece of work, not this one done.
  def test_a_verdict_from_another_interpreter_is_re_opened_rather_than_trusted
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      other = ledger_at(path, machine: OTHER_MACHINE)
      record(other, verdict: Agents::Upgrader::Ledger::PASSED, note: "the suite was green there")

      assert other.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO),
        "the machine that produced it believes it"

      read = ledger_at(path)

      refute read.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO),
        "another interpreter's verdict does not settle this one"
      assert_equal Agents::Upgrader::Ledger::PASSED,
        read.find(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO).verdict,
        "re-opened, not deleted: the reason is the thing worth reading"
    end
  end

  # A record written before the stamp existed makes no claim about a machine, so there
  # is nothing in it to contradict — and refusing it would re-derive work on the
  # strength of a field that was never written.
  def test_a_record_with_no_stamp_is_read_as_this_machines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      File.write(path, JSON.generate(
        "schema_version" => Agents::Upgrader::Ledger::SCHEMA_VERSION,
        "entries" => [
          {
            "repo" => REPO, "commit" => COMMIT, "from_version" => FROM, "to_version" => TO,
            "verdict" => Agents::Upgrader::Ledger::PASSED
          }
        ]
      ))

      read = ledger_at(path)

      assert read.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
      assert_equal "", read.find(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO).machine
    end
  end

  # Two refs are two pieces of work. A commit is the whole point of the key: the same
  # step walked from a different tree is not this one, however equal the version pair.
  def test_two_commits_are_two_pieces_of_work
    Dir.mktmpdir do |dir|
      ledger = ledger_at(File.join(dir, "ledger.json"))
      record(ledger, verdict: Agents::Upgrader::Ledger::PASSED)

      assert ledger.settled?(repo: REPO, commit: COMMIT, from_version: FROM, to_version: TO)
      refute ledger.settled?(repo: REPO, commit: "0000000", from_version: FROM, to_version: TO)
      refute ledger.settled?(repo: "#{REPO}.git", commit: COMMIT, from_version: FROM, to_version: TO)
      assert_equal 0, ledger.attempts(repo: REPO, commit: "0000000", from_version: FROM, to_version: TO)
    end
  end

  # Guessing at a file we cannot read is the one outcome worse than redoing the work:
  # a wrong parse reports work done that never ran. So the copy is kept and the reason
  # is reported, and the service starts from an empty ledger rather than refusing to.
  def test_an_unparseable_file_is_set_aside_with_its_reason_and_the_ledger_starts_empty
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      File.write(path, "not json at all {")

      read = ledger_at(path)

      assert_equal 0, read.size
      refute_nil read.set_aside!, "the reason is what a service logs"
      assert_includes read.set_aside!, "could not be parsed"
      refute File.exist?(path), "the copy is moved, not deleted over"
      kept = Dir.children(dir).grep(/\.corrupt-/)
      assert_equal 1, kept.size
      assert_equal "not json at all {", File.read(File.join(dir, kept.first))
    end
  end

  # A schema this reader does not understand is not a corrupt file: it is a newer one,
  # and the difference is worth keeping in its name.
  def test_a_newer_schema_is_set_aside_rather_than_guessed_at
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ledger.json")
      File.write(path, JSON.generate(
        "schema_version" => 99,
        "entries" => [
          {
            "repo" => REPO, "commit" => COMMIT, "from_version" => FROM, "to_version" => TO,
            "verdict" => Agents::Upgrader::Ledger::PASSED
          }
        ]
      ))

      read = ledger_at(path)

      assert_equal 0, read.size, "a ledger from the future is not half-read"
      assert_includes read.set_aside!, "99"
      assert_equal 1, Dir.children(dir).grep(/\.unknown-schema-/).size
    end
  end

  # Atomic, and readable only by the account that owns it: a truncated ledger is one a
  # restart cannot interpret, and the mode has to be set before the rename so the file
  # is never briefly world-readable.
  def test_the_save_is_atomic_and_creates_its_directory
    Dir.mktmpdir do |dir|
      nested = File.join(dir, "state", "upgrader")
      path = File.join(nested, "ledger.json")
      record(ledger_at(path), verdict: Agents::Upgrader::Ledger::PASSED)

      assert File.file?(path)
      assert_equal ["ledger.json"], Dir.children(nested), "no half-written neighbour is left behind"
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 1, ledger_at(path).size
    end
  end
end
