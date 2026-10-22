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
      "[a known failure](https://agents.example/api/reports/r1)"
    refute_includes result.to_markdown, "https://agents.example/api/reports/r1",
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

  # **The plan is the joined read, so the framework section reads it rather than asking a second
  # question.** An observed report carries the change key it joined; an unmatched report carries the
  # key nobody documented; a rule carries its authority and the change it is about. The window read
  # would know only that the library had reports somewhere in the move.
  def test_the_framework_section_is_the_plan_s_joined_view
    corpus = FakeCorpus.new(moves: { "rails" => { "changes" => [{ "id" => "unused" }] } })
    plan = {
      "changes" => [{ "subject" => "before_filter", "change_key" => "ruby|actionpack|before_filter" }],
      "observed" => [{ "report_id" => "r1", "title" => "before_filter is gone",
                       "library" => "actionpack", "broken_in" => "5.1.0",
                       "status" => "resolved_verified", "change_kind" => "symbol_removed",
                       "change_key" => "ruby|actionpack|before_filter", "resolution" => "use before_action" }],
      "observed_unmatched" => [{ "report_id" => "r2", "title" => "a report nobody documented",
                                 "library" => "rails", "broken_in" => "6.0.0",
                                 "status" => "open", "change_key" => "ruby|rails|unknown" }],
      "rules" => [{ "rule_id" => nil, "change_key" => "ruby|actionpack|before_filter",
                    "kind" => "rewrite", "authority" => "curated" }],
      "counts" => { "observed_unclassified" => 2 }
    }

    result = brief_for(corpus).call(from: "5.0.0", to: "6.0.0", plan: plan)
    section = result.sections.first

    assert_equal "framework", section.key
    assert_equal "answers", section.state
    assert_equal %w[r1 r2], section.items.filter_map(&:id)
    assert_equal ["ruby|actionpack|before_filter", "ruby|rails|unknown", "ruby|actionpack|before_filter"],
      section.items.map(&:change_key)
    assert_equal "unmatched", section.items[1].match
    assert_equal "curated", section.items.last.authority
    assert_includes section.note, "1 documented change(s)"
    assert_includes section.note, "2 report(s) not recorded as changes"
    assert_empty corpus.upgrade_calls, "the plan was already fetched and the brief asked the window again"
  end

  # The plan keeps the flat `observed` list and also lists the unmatched subset; the brief must not
  # show or count the same report twice.
  def test_an_unmatched_report_in_observed_is_shown_once
    plan = {
      "changes" => [{ "subject" => "before_filter", "change_key" => "ruby|actionpack|before_filter" }],
      "observed" => [{ "report_id" => "r2", "title" => "a report nobody documented",
                       "library" => "rails", "broken_in" => "6.0.0",
                       "status" => "open", "change_key" => "ruby|rails|unknown" }],
      "observed_unmatched" => [{ "report_id" => "r2", "title" => "a report nobody documented",
                                 "library" => "rails", "broken_in" => "6.0.0",
                                 "status" => "open", "change_key" => "ruby|rails|unknown" }],
      "rules" => [],
      "counts" => {}
    }

    section = brief_for(FakeCorpus.new).call(from: "5.0.0", to: "6.0.0", plan: plan).sections.first

    assert_equal ["r2"], section.items.map(&:id)
    assert_includes section.note, "0 observed"
    assert_includes section.note, "1 unmatched"
  end

  # A plan that could not read a corpus (`observed` is null) is not a corpus with nothing to say,
  # so the brief falls back to the route rather than turning an unasked question into an empty one.
  def test_a_plan_with_no_corpus_falls_back_to_the_window_read
    corpus = FakeCorpus.new(moves: { "rails" => { "changes" => [{
      "id" => "r1", "title" => "a window report", "library" => "rails",
      "version" => "6.0.0", "status" => "resolved_verified"
    }] } })

    result = brief_for(corpus).call(from: "5.2.0", to: "6.0.0",
      plan: { "observed" => nil, "changes" => [] })

    assert_equal ["a window report"], result.sections.first.items.map(&:title)
    assert_equal [["rails", "5.2.0", "6.0.0"]], corpus.upgrade_calls
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

  # **The word `MultiJson` is not a claim about the multi_json gem.** The Rails 4.1 change is
  # `activesupport` removing its MultiJSON dependency; the corpus also holds three reports about
  # `multi_json 1.20.1`. The 4.1 body showed those three as “same failure” for a library this
  # application does not use. The search stays the corpus's; the section keeps a report only when
  # its library is the change's component or Rails itself.
  def test_a_search_section_keeps_only_reports_from_the_change_s_component
    corpus = FakeCorpus.new(searches: { "MultiJson" => {
      "items" => [
        { "id" => "r1", "title" => "multi_json 1.20.1 removed a name",
          "library" => "multi_json", "match_type" => "signature" },
        { "id" => "r2", "title" => "rails removed MultiJSON",
          "library" => "rails", "match_type" => "signature" }
      ], "total" => 2
    } })

    result = brief_for(corpus).call(from: "4.0.0", to: "4.1.0",
      subjects: [{ "subject" => "MultiJson", "change_kind" => "removed",
                   "component" => "activesupport" }])
    section = result.sections.find { |s| s.key == "search:MultiJson" }

    assert_equal ["r2"], section.items.map(&:id)
    assert_equal 1, section.total, "the total still counts the unrelated library"
    refute_includes result.to_markdown, "multi_json 1.20.1"
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

  # **An accepted decision is part of what the rung knew before it ran.** It carries the question,
  # the answer and the kinds of effects the walk will apply; the brief does not re-derive them.
  def test_accepted_decisions_are_rendered_in_the_decisions_section
    result = brief_for(FakeCorpus.new).call(from: "4.0.0", to: "4.1.0",
      decisions: [{
        "id" => "d1", "project" => "storefront",
        "change_key" => "ruby|actionpack|before_filter",
        "question" => "Should the row keep a Show link?",
        "answer" => "remove it", "accepted_by" => "operator:1",
        "effects" => [{ "kind" => "patch", "payload" => { "path" => "app/views/bids/index.html.erb" } },
                      { "kind" => "rule", "payload" => { "change_key" => "ruby|actionpack|before_filter",
                                                         "kind" => "skip" } }]
      }])

    section = result.sections.find { |candidate| candidate.key == "decisions" }
    assert_equal "answers", section.state
    item = section.items.first
    assert_equal "Should the row keep a Show link?", item.title
    assert_equal "remove it", item.status
    assert_equal "storefront", item.project
    assert_equal "ruby|actionpack|before_filter", item.change_key
    assert_includes item.fix, "patch"
    assert_includes item.fix, "rule skip"
    assert_includes result.to_markdown, "remove it"
    assert_includes result.to_markdown, "change ruby|actionpack|before_filter"
    assert_includes result.to_markdown, "project storefront"
  end

  # A declaration written before the decision carried its own project still names the project the
  # walk is reading, because that is whose declaration it is.
  def test_a_decision_without_a_project_is_the_walk_s_own
    result = brief_for(FakeCorpus.new).call(from: "4.0.0", to: "4.1.0", project: "storefront",
      decisions: [{ "id" => "d1", "question" => "keep the link?", "answer" => "no",
                    "accepted_by" => "operator:1", "effects" => [] }])

    item = result.sections.find { |section| section.key == "decisions" }.items.first
    assert_equal "storefront", item.project
  end

  # **A decision from another project is the same change.** The declaration carries it with the key
  # the plan joins on and the project whose operator answered; the brief does not filter it away.
  def test_a_cross_project_decision_keeps_its_project_and_change_key
    result = brief_for(FakeCorpus.new).call(from: "4.0.0", to: "4.1.0",
      decisions: [{ "id" => "d2", "project" => "lighthouse",
                    "change_key" => "ruby|activerecord|before_filter",
                    "question" => "the filter runs before the association loads",
                    "answer" => "use before_action", "accepted_by" => "operator:2",
                    "effects" => [{ "kind" => "rule",
                                    "payload" => { "change_key" => "ruby|activerecord|before_filter",
                                                   "kind" => "rewrite",
                                                   "old" => "before_filter", "new" => "before_action" } }] }])

    item = result.sections.find { |section| section.key == "decisions" }.items.first

    assert_equal "lighthouse", item.project
    assert_equal "ruby|activerecord|before_filter", item.change_key
    assert_includes item.effects, "rule rewrite on ruby|activerecord|before_filter"
  end
end
