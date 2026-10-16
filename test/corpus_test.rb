# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "agents_fyi/upgrader"

# How a request is built and how a response is read. The transport is replaced rather
# than mocked: what is under test is the mapping from a status and a body to a value or an
# error — which is what decides whether a caller sees the service's sentence or a crash —
# and the request itself, because the header that carries the operator's key is a fact
# about this client that no other test can see.
class CorpusTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  class StubbedCorpus < AgentsFyi::Upgrader::Corpus
    attr_reader :requests

    def initialize(*responses, base: "https://example.test", **kwargs)
      super(base: base, **kwargs)
      # One response is answered for ever, several are served in order: a caller that
      # asks twice in a test is a caller whose second request is the thing under test.
      @responses = responses
      @requests = []
    end

    private

    def fetch(uri, request)
      @requests << [uri, request]
      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end

  def envelope(type, message)
    JSON.generate({ "error" => { "type" => type, "status" => 422, "message" => message } })
  end

  def with_env(name, value)
    previous = ENV[name]
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    previous.nil? ? ENV.delete(name) : ENV[name] = previous
  end

  def test_a_refusal_carries_the_sentence_the_service_wrote
    body = envelope("validation_error", "This reads forward upgrades: `5.1.0` is ahead of `4.2.11`.")
    corpus = StubbedCorpus.new(FakeResponse.new("422", body))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Refused) do
      corpus.upgrade(from: "5.1.0", to: "4.2.11")
    end

    assert_includes error.message, "reads forward upgrades"
  end

  # A refusal with no envelope still has to produce a sentence a person can act on,
  # and it has to name the status, because that is the only clue left.
  def test_a_refusal_with_nothing_to_quote_still_names_the_status
    corpus = StubbedCorpus.new(FakeResponse.new("422", ""))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Refused) do
      corpus.upgrade(from: "4.2.11", to: "5.0.0")
    end

    assert_includes error.message, "HTTP 422"
  end

  # A 500 is not a refusal: nothing about the request was wrong, and reading it as
  # one would tell a caller to stop asking a question the service will happily answer
  # in a minute.
  def test_a_server_error_is_an_outage_rather_than_a_refusal
    corpus = StubbedCorpus.new(FakeResponse.new("500", "{}"))

    assert_raises(AgentsFyi::Upgrader::Corpus::Unreachable) do
      corpus.upgrade(from: "4.2.11", to: "5.0.0")
    end
  end

  def test_a_body_that_is_not_json_is_an_outage_rather_than_an_empty_plan
    corpus = StubbedCorpus.new(FakeResponse.new("200", "<html>a proxy said hello</html>"))

    assert_raises(AgentsFyi::Upgrader::Corpus::Unreachable) do
      corpus.upgrade(from: "4.2.11", to: "5.0.0")
    end
  end

  def test_a_plan_comes_back_exactly_as_the_service_wrote_it
    payload = { "from_version" => "4.2.11", "steps" => [] }
    corpus = StubbedCorpus.new(FakeResponse.new("200", JSON.generate(payload)))

    assert_equal payload, corpus.upgrade(from: "4.2.11", to: "5.0.0")
  end

  # The write path needs an account, and the header is the miner's — one spelling of a
  # credential across two clients, because a second spelling is how two clients start
  # disagreeing about which of them is signed in.
  def test_a_write_carries_the_operator_key_the_way_the_miner_sends_it
    corpus = StubbedCorpus.new(FakeResponse.new("200", "{}"), key: "k-123")

    corpus.record_run({ "verdict" => "passed" })

    uri, request = corpus.requests.first
    assert_equal "POST", request.method
    assert_equal "/upgrades/runs", uri.path
    assert_equal "k-123", request["X-API-Key"]
  end

  # An anonymous read must not carry an empty credential: a request that looks signed in
  # and is not is refused by routes that would otherwise answer it.
  def test_a_read_with_no_key_sends_no_key_header_at_all
    corpus = StubbedCorpus.new(FakeResponse.new("200", JSON.generate({ "from_version" => "4.2.11" })),
      key: "")

    corpus.upgrade(from: "4.2.11", to: "5.0.0")

    _uri, request = corpus.requests.first
    assert_nil request["X-API-Key"]
  end

  # The key is read from the environment rather than passed at every call site, because
  # four places construct this client and the fourth would have forgotten.
  def test_the_key_comes_from_the_environment_when_none_is_passed
    with_env(AgentsFyi::Upgrader::Corpus::ENV_KEY, "from-the-environment") do
      corpus = StubbedCorpus.new(FakeResponse.new("200", "{}"))

      corpus.record_run({ "verdict" => "passed" })

      _uri, request = corpus.requests.first
      assert_equal "from-the-environment", request["X-API-Key"]
    end
  end

  def test_the_queue_is_asked_for_with_the_limit_it_was_given
    corpus = StubbedCorpus.new(FakeResponse.new("200", JSON.generate({ "targets" => [] })))

    corpus.targets(limit: 500)

    uri, request = corpus.requests.first
    assert_equal "GET", request.method
    assert_equal "/upgrades/targets", uri.path
    assert_equal "limit=500", uri.query
  end

  # The route clamps what it will serve, and the clamp is answered rather than refused —
  # so a short page is a short page. The miner asked for more than its route allowed and
  # was answered 422 for as long as the method existed, which its own caller read as "the
  # service has no queue"; the test that pins this is that one request was made.
  def test_a_clamped_queue_read_is_read_what_it_was_served
    body = JSON.generate(
      { "targets" => [{ "repo_url" => "acme/storefront", "rails_version" => "4.2.11" }],
        "count" => 1, "limit_max" => 500 }
    )
    corpus = StubbedCorpus.new(FakeResponse.new("200", body))

    rows = corpus.targets(limit: 1_000)

    assert_equal ["acme/storefront"], rows.map { |row| row["repo_url"] }
    assert_equal 1, corpus.requests.size, "a clamped page was asked for again"
  end

  # A page that is not a queue is not an empty queue: the difference between "there is
  # nothing to walk" and "nothing answered" is the whole of what a loop does next.
  def test_a_200_that_is_not_a_queue_is_an_outage
    corpus = StubbedCorpus.new(FakeResponse.new("200", JSON.generate({ "steps" => [] })))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Unreachable) { corpus.targets }

    assert_includes error.message, "no list of `targets`"
  end

  # And a queue the service has *stopped serving* is not an empty one either. This is the
  # trap AGENTS.md records for the mining queue, one surface over: a client that read the
  # pause as "nothing left" would idle happily while a person had stopped the work.
  def test_a_queue_that_is_not_being_served_is_not_an_empty_queue
    body = JSON.generate(
      { "targets" => [], "count" => 0, "paused" => true,
        "paused_reason" => "an operator stopped it while the ladder is reworked",
        "next_step" => "Resume it with POST /admin/collection/ruby/resume." }
    )
    corpus = StubbedCorpus.new(FakeResponse.new("200", body))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Unreachable) { corpus.targets }

    assert_includes error.message, "an operator stopped it"
    assert_includes error.message, "POST /admin/collection/ruby/resume"
  end

  # An entry the loop cannot walk is not work. Dropping it is a narrowing of what the
  # queue means, and it is done here rather than at four call sites.
  def test_a_queue_row_with_no_repository_is_not_work
    body = JSON.generate(
      { "targets" => [{ "repo_url" => "acme/storefront" }, { "rails_version" => "4.2.11" },
                      { "repo_url" => "" }] }
    )
    corpus = StubbedCorpus.new(FakeResponse.new("200", body))

    assert_equal ["acme/storefront"], corpus.targets.map { |row| row["repo_url"] }
  end

  def test_prechecking_sends_the_draft_to_the_precheck_route
    corpus = StubbedCorpus.new(FakeResponse.new("200", JSON.generate({ "verdict" => "new" })))

    answer = corpus.precheck({ "title" => "a draft", "library" => "rails" })

    uri, request = corpus.requests.first
    assert_equal "/reports/precheck", uri.path
    assert_equal({ "title" => "a draft", "library" => "rails" },
      JSON.parse(request.body))
    assert_equal "new", answer["verdict"]
  end

  # Filing is where a 409 is an *answer*: the corpus saying "already recorded" is the
  # ordinary outcome, and the sentence still travels so a caller that only wanted to know
  # why nothing was written has it.
  def test_a_duplicate_report_is_an_answer_rather_than_a_crash
    body = envelope("duplicate", "A report with this title already exists: `some other title`.")
    corpus = StubbedCorpus.new(FakeResponse.new("409", body))

    answer = corpus.create_report({ "title" => "a failure" })

    assert_equal true, answer["duplicate"]
    assert_includes answer["detail"], "already exists"
    assert_equal "duplicate", answer.dig("error", "type")
  end

  # Every other route has no use for a 409, so it stays a refusal there — and still a
  # `Refused`, which is what the CLI's own rescue catches, so a collision cannot take a
  # process down for a reason it understands.
  def test_a_collision_on_a_route_that_has_no_answer_for_it_is_still_a_refusal
    body = envelope("conflict", "That target already exists.")
    corpus = StubbedCorpus.new(FakeResponse.new("409", body))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Refused) do
      corpus.record_run({ "verdict" => "passed" })
    end

    assert_includes error.message, "already exists"
  end

  # A 422 from the write path is the service reading the request and declining it: a
  # client that filed nothing and reported success would be the failure this repository
  # keeps rediscovering.
  def test_a_report_the_service_will_not_take_raises_with_its_sentence
    corpus = StubbedCorpus.new(FakeResponse.new("422", envelope("validation_error", "title: too short")))

    error = assert_raises(AgentsFyi::Upgrader::Corpus::Refused) do
      corpus.create_report({ "title" => "x" })
    end

    assert_includes error.message, "too short"
  end
end
