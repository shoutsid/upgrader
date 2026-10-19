# frozen_string_literal: true

require "minitest/autorun"
require "agents_fyi/upgrader"

# **The brief is what the corpus says before the walk decides anything.** Three reads and one
# rule — a section's state is the meaning of an empty answer, not its size — and the cases here are
# the ones a real rung produced: a window with no recorded changes, a gem whose move carries its own
# reports, a subject that matches by words alone, a question the corpus refuses, and more questions
# than one brief may ask.
class BriefTest < Minitest::Test
  class FakeCorpus
    attr_reader :upgrade_calls, :search_calls

    def initialize(moves: {}, searches: {}, raises: {})
      @moves = moves
      @searches = searches
      @raises = raises
      @upgrade_calls = []
      @search_calls = []
    end

    def reports_upgrade(library:, from_version:, to_version:, **)
      @upgrade_calls << [library, from_version, to_version]
      raise_for("move:#{library}") || @moves.fetch(library, { "changes" => [] })
    end

    def search(query:, limit:, **)
      @search_calls << [query, limit]
      raise_for("search:#{query}") || @searches.fetch(query, { "items" => [], "total" => 0 })
    end

    private

    def raise_for(key)
      error = @raises[key]
      raise error if error
    end
  end

  def brief_for(corpus)
    AgentsFyi::Upgrader::Brief.new(corpus: corpus)
  end

  # **A link only when the reader's base is known.** The walker's own API base is often an internal
  # hostname; a pull request is read on GitHub, so the deployment names the public base and the
  # report becomes a link. Without one the title is named rather than pointed at a host nobody can
  # resolve.
  def test_reports_are_linked_when_a_readers_base_is_named
    corpus = FakeCorpus.new(moves: { "rails" => { "changes" => [{
      "id" => "r1", "title" => "a known failure", "library" => "rails",
      "version" => "6.0.0", "status" => "resolved_verified",
      "change_kind" => "config", "resolution" => "set the flag"
    }] } })

    result = brief_for(corpus).call(from: "5.2.0", to: "6.0.0")

    assert_includes result.to_markdown(base: "https://agents.example"),
      "[a known failure](https://agents.example/reports/r1)"
    refute_includes result.to_markdown, "https://agents.example/reports/r1",
      "a brief with no reader base linked a host it does not know"
  end

  # The framework half: a report filed against this very window, with its fix, is what the brief
  # exists to surface. Asked with the ecosystem named, because the service's default is python.
  def test_the_framework_move_carries_what_the_corpus_observed
    corpus = FakeCorpus.new(moves: { "rails" => { "changes" => [{
      "id" => "r1", "title" => "rails 6.0.0: served static assets", "library" => "rails",
      "version" => "6.0.0", "status" => "resolved_verified", "trust" => 0.9,
      "change_kind" => "config", "resolution" => "set config.public_file_server.enabled"
    }] } })

    result = brief_for(corpus).call(from: "5.2.0", to: "6.0.0")
    section = result.sections.first

    assert_equal "framework", section.key
    assert_equal "answers", section.state
    assert_equal ["r1"], section.items.map(&:id)
    assert_equal "set config.public_file_server.enabled", section.items.first.fix
    assert_includes section.items.first.title, "served static assets"
  end

  # **A gem's move is its own question.** The routing moved `factory_girl` at 4.1 and no Rails
  # change knows about it; a brief that asked only the framework would miss exactly the report that
  # saved that rung.
  def test_each_gem_the_routing_moves_is_asked_about_and_a_kept_gem_is_not
    corpus = FakeCorpus.new(moves: { "factory_girl" => { "changes" => [{
      "id" => "r2", "title" => "factory_girl 4.0 removed the static attribute", "library" => "factory_girl",
      "version" => "4.0.0", "status" => "resolved_verified", "resolution" => "factory_bot"
    }] } })

    gems = [
      { "name" => "factory_girl", "version" => "2.6.0", "to" => "4.0.0", "verdict" => "replace" },
      { "name" => "rspec-rails", "version" => "2.14.0", "to" => "2.14.0", "verdict" => "keep" }
    ]
    result = brief_for(corpus).call(from: "4.0.0", to: "4.1.0", gems: gems)

    assert_equal %w[rails factory_girl], corpus.upgrade_calls.map(&:first)
    assert_equal [%w[factory_girl 2.6.0 4.0.0]], corpus.upgrade_calls.drop(1)
    section = result.sections.find { |s| s.key == "gem:factory_girl" }
    assert_equal "answers", section.state
    assert_equal "factory_bot", section.items.first.fix
  end

  # **A signature match is the same failure; a word match is a mention.** The distinction is the
  # corpus's (`match_type`) and the brief keeps it, because the two want different amounts of trust.
  def test_a_change_subject_is_searched_and_a_signature_match_is_marked_apart_from_a_mention
    corpus = FakeCorpus.new(searches: { "config.serve_static_assets" => {
      "items" => [
        { "id" => "r3", "title" => "serve_static_assets is gone", "status" => "open", "match_type" => "signature" },
        { "id" => "r4", "title" => "a blog post mentions it", "status" => "open", "match_type" => "fulltext" }
      ], "total" => 9
    } })

    result = brief_for(corpus).call(from: "4.0.0", to: "4.1.0",
      subjects: [{ "subject" => "config.serve_static_assets", "change_kind" => "config" }])
    section = result.sections.find { |s| s.key == "search:config.serve_static_assets" }

    assert_equal ["config.serve_static_assets", AgentsFyi::Upgrader::Brief::SEARCH_LIMIT], corpus.search_calls.first
    assert_equal [true, false], section.items.map(&:identifying?)
    assert_equal 9, section.total, "the total is the corpus's, not the page's"
    assert_includes result.to_markdown, "**same failure**"
    assert_includes result.to_markdown, "mention"
    assert_includes result.to_markdown, "and 7 more in the corpus"
  end

  # **Four meanings collapse into one reassuring sentence if you let them.** The route's own
  # `next_step` says which, so the empty section quotes it rather than paraphrasing.
  def test_an_empty_window_says_which_meaning_it_is
    corpus = FakeCorpus.new(moves: { "rails" => { "changes" => [],
      "next_step" => "No report in this corpus names `rails`." } })

    section = brief_for(corpus).call(from: "4.0.0", to: "4.1.0").sections.first

    assert_equal "nothing recorded", section.state
    assert_equal "No report in this corpus names `rails`.", section.note
  end

  # A refusal is a fact about the question, not about the walk: the section says so and the next
  # question is still asked. A brief that raised would turn a corpus's "I have nothing" into a
  # stopped rung.
  def test_a_refused_question_becomes_a_section_and_the_brief_continues
    corpus = FakeCorpus.new(
      raises: { "move:rails" => AgentsFyi::Upgrader::Corpus::Refused.new("this service reads forward upgrades") },
      searches: { "x" => { "items" => [{ "id" => "r5", "title" => "found anyway", "match_type" => "signature" }], "total" => 1 } }
    )

    result = brief_for(corpus).call(from: "4.0.0", to: "4.1.0", subjects: ["x"])

    assert_equal "unavailable", result.sections.first.state
    assert_includes result.sections.first.note, "forward"
    assert_equal 1, result.unavailable
    found = result.sections.find { |section| section.key == "search:x" }
    assert_equal ["found anyway"], found.items.map(&:title)
  end

  # **A bound on what a brief asks is said, not silently applied.** The walk is billed in requests,
  # and a brief that quietly asked forty of fifty questions would leave a reader believing the corpus
  # had nothing to say about the rest.
  def test_more_questions_than_the_brief_may_ask_is_reported_as_truncated
    corpus = FakeCorpus.new
    subjects = (1..(AgentsFyi::Upgrader::Brief::MAX_QUESTIONS + 5)).map { |n| "subject-#{n}" }

    result = brief_for(corpus).call(from: "4.0.0", to: "4.1.0", subjects: subjects)

    assert result.truncated
    assert_equal AgentsFyi::Upgrader::Brief::MAX_QUESTIONS, corpus.search_calls.length + 1,
      "the framework move is one question; the rest stop at the bound"
  end

  # Our own past answers are a section whether or not there are any: a reader should be able to see
  # that the walk looked for them rather than infer that it did not.
  def test_our_own_decisions_are_a_section_even_when_empty
    result = brief_for(FakeCorpus.new).call(from: "4.0.0", to: "4.1.0")

    decisions = result.sections.find { |s| s.key == "decisions" }
    assert_equal "nothing recorded", decisions.state
    assert_includes result.to_h.keys, "sections"
  end
end
