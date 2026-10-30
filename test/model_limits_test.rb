# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents/upgrader"

# **The provider's clock, kept where the next step can read it.** A free model that is spent is
# not work; the reset it names is the fact that lets the walker start with the paid model instead
# of spending the free deadline again.
class ModelLimitsTest < Minitest::Test
  Limits = Agents::Upgrader::ModelLimits

  def setup
    @home = Dir.mktmpdir
    @now = Time.utc(2026, 10, 29, 12, 0, 0)
  end

  def teardown
    FileUtils.remove_entry(@home) if File.directory?(@home)
  end

  def limits(now: @now)
    Limits.new(home: @home, now: -> { now })
  end

  def test_a_reported_iso_reset_is_the_deadline
    entry = limits.record(model: "opencode/free", exit_code: 1,
      output: "Rate limit exceeded. Resets at 2026-10-29T18:00:00Z")

    assert_equal Time.utc(2026, 10, 29, 18), entry.until_time
    assert entry.reset_reported
    assert_equal entry.until_time, limits.limited_until("opencode/free")
    assert_includes entry.reason, "named the reset"
  end

  def test_a_relative_reset_is_read_as_a_duration
    entry = limits.record(model: "opencode/free", exit_code: 1,
      output: "Free usage limit reached. Please try again in 90 minutes.")

    assert_equal @now + (90 * 60), entry.until_time
  end

  def test_a_clock_time_that_has_passed_is_the_next_day
    evening = Time.utc(2026, 10, 29, 20, 0, 0)
    entry = limits(now: evening).record(model: "opencode/free", exit_code: 1,
      output: "You exceeded your free usage limit. It resets at 6pm.")

    assert_equal Time.utc(2026, 10, 30, 18, 0, 0), entry.until_time
  end

  # **A reset the provider did not name is not a clock this process may invent.** The live free
  # tier answered `Free usage limit reached` with no time at all; an hourly retry spends the paid
  # fallback's deadline to re-learn the same sentence, so the entry is held until an operator
  # clears it and the reason says the hold is the absence of a fact.
  def test_a_limit_without_a_reset_is_held_until_an_operator_clears_it
    entry = limits.record(model: "opencode/free", exit_code: 1,
      output: "Free usage limit reached. Subscribe to OpenCode Go to keep going.")

    assert_nil entry.until_time
    refute entry.reset_reported
    assert entry.indefinite?
    assert_includes entry.reason, "operator clears"
    assert_equal Limits::INDEFINITE, limits.limited_until("opencode/free")
    assert_equal Limits::INDEFINITE, limits(now: @now + (365 * 86_400)).limited_until("opencode/free"),
      "an indefinite hold does not expire on a guessed cooldown"
  end

  # **A free model that never answered is unavailable too.** The live tier timed out with no
  # provider sentence; waiting the same deadline on every later step is the cost without the
  # sentence. A paid model that times out may be slow because it is working, so it is not read
  # this way.
  def test_a_free_timeout_is_an_availability_limit_but_a_paid_timeout_is_not
    free = limits.record(model: "opencode/free", timed_out: true, exit_code: nil,
      output: "the repair agent was killed after 300s")
    # A limit-looking word in the agent's own stream is not the provider's limit: measured live,
    # the paid attempt was held because its tool output mentioned a 429 the model was reading.
    paid = limits.record(model: "opencode-go/paid", timed_out: true, exit_code: nil,
      output: "the repair agent was killed after 300s; it had read a 429 in a test fixture")

    refute_nil free
    assert_includes free.reason, "no reset was reported"
    assert_nil paid
  end

  def test_a_successful_answer_that_mentions_a_rate_limit_is_not_a_limit
    entry = limits.record(model: "opencode/free", exit_code: 0,
      output: "I fixed the initializer. The old code had a rate limit check.")

    assert_nil entry
    assert_nil limits.limited_until("opencode/free")
  end

  def test_the_deadline_survives_a_new_reader_and_is_dropped_after_it_passes
    limits.record(model: "opencode/free", exit_code: 1,
      output: "Rate limit exceeded. Resets at 2026-10-29T18:00:00Z")

    assert_equal Time.utc(2026, 10, 29, 18), limits.limited_until("opencode/free")

    later = Time.utc(2026, 10, 29, 18, 0, 1)
    assert_nil limits(now: later).limited_until("opencode/free")
    document = JSON.parse(File.read(File.join(@home, Limits::FILE)))
    assert_empty document.fetch("models")
  end
end
