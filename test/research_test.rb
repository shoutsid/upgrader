# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The facts the service cannot read for itself, as the client that can read them.
#
# The parser is the substance and it is driven against lines copied from the real index —
# `devise`'s own, with the `&`-joined requirement and the checksum trailer — because the
# format is a third party's and a fixture invented by whoever wrote the reader would agree
# with whatever the reader does.
class ResearchTest < Minitest::Test
  Research = AgentsFyi::Upgrader::Research

  # Copied from `https://index.rubygems.org/info/devise`, verbatim.
  DEVISE = <<~INDEX
    ---
    0.1.0 warden:~> 0.10.7|checksum:aaaa,created_at:2009-01-01T00:00:00Z
    2.2.4 bcrypt-ruby:~> 3.0,orm_adapter:~> 0.1,railties:~> 3.1,warden:~> 1.2.1|checksum:bbbb,created_at:2013-05-07T15:54:34Z
    3.0.0 bcrypt-ruby:~> 3.0,orm_adapter:~> 0.1,railties:< 5&>= 3.2.6,warden:~> 1.2.3|checksum:cccc,ruby:>= 1.9.3,created_at:2013-07-14T18:48:13Z
  INDEX

  class FakeCorpus
    attr_reader :recorded

    def initialize(route: nil)
      @route = route
      @recorded = []
    end

    def record_facts(library:, facts:)
      @recorded << [library, facts]
      { "recorded" => facts.length }
    end

    def route(ruby:, rails:, lockfile:)
      @route || { "ruby" => ruby, "rails" => rails, "gems_read" => 0,
                  "counts" => { "keep" => 0, "move" => 0, "unknown" => 0 }, "gems" => [] }
    end
  end

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def temp_dir
    dir = Dir.mktmpdir
    @dirs << dir
    dir
  end

  def research(corpus: FakeCorpus.new, body: DEVISE, cache: nil)
    Research.new(corpus: corpus, cache: cache, fetcher: ->(_url) { body }, out: nil)
  end

  def test_the_parser_reads_the_index_s_own_lines
    facts = Research.parse(DEVISE)

    assert_equal %w[0.1.0 2.2.4 3.0.0], facts.keys
    assert_equal ">= 1.9.3", facts["3.0.0"]["ruby_requirement"]
    assert_nil facts["2.2.4"]["ruby_requirement"], "3.0.0's own: a release that declared none is nil"
    assert_equal [{ "name" => "bcrypt-ruby", "requirement" => "~> 3.0" },
                  { "name" => "orm_adapter", "requirement" => "~> 0.1" },
                  { "name" => "railties", "requirement" => "~> 3.1" },
                  { "name" => "warden", "requirement" => "~> 1.2.1" }],
      facts["2.2.4"]["dependencies"]

    # The `&` form — two clauses in one requirement — survives as one string, which is what
    # the service's reader expects: it splits on `&` as well as on commas.
    railties = facts["3.0.0"]["dependencies"].find { |dep| dep["name"] == "railties" }
    assert_equal "< 5&>= 3.2.6", railties["requirement"]
  end

  def test_a_release_with_no_dependencies_parses_to_an_empty_list
    facts = Research.parse("1.0.0 |checksum:aaaa,ruby:>= 2.0\n")

    assert_equal [], facts["1.0.0"]["dependencies"]
    assert_equal ">= 2.0", facts["1.0.0"]["ruby_requirement"]
  end

  # The pin is posted whatever its age, and the newest releases with it: routing needs the
  # pin to decide and the recent ones to find a target, and posting a gem's whole history is
  # facts a routing answer never reads.
  def test_one_gem_s_facts_are_the_pin_and_the_newest_releases
    body = +"---\n"
    60.times { |index| body << "1.0.#{index} |checksum:aa,ruby:>= 1.9.3\n" }
    body << "2.2.4 old-gem:~> 1.0|checksum:bb,ruby:>= 1.9.3\n"

    facts = research(body: body).facts_for("gem", "1.0.0")

    assert_equal 41, facts.length, "the pin and RECENT_VERSIONS releases"
    assert_includes facts.map { |fact| fact["version"] }, "1.0.0"
    assert_includes facts.map { |fact| fact["version"] }, "2.2.4"
    assert_equal false, facts.any? { |fact| fact["version"] == "1.0.1" }
  end

  def test_a_pass_records_what_it_read_and_says_what_it_skipped
    corpus = FakeCorpus.new
    result = research(corpus: corpus).run([["devise", "2.2.4"], ["devise", "2.2.4"]])

    assert_equal ["devise"], result.researched
    assert_equal ["devise"], corpus.recorded.map(&:first)
    versions = corpus.recorded.first.last.map { |fact| fact["version"] }
    assert_includes versions, "2.2.4"
    assert_includes versions, "3.0.0"
    assert_includes result.to_s, "researched 1 gem(s)"
  end

  def test_a_gem_whose_document_was_already_fetched_is_read_from_the_cache
    cache = temp_dir
    File.write(File.join(cache, "devise.index"), DEVISE)
    fetcher_used = false
    pass = Research.new(corpus: FakeCorpus.new, cache: cache, out: nil,
      fetcher: lambda { |_url|
        fetcher_used = true
        ""
      })

    facts = pass.facts_for("devise", "2.2.4")

    assert_equal false, fetcher_used, "a fresh cache was ignored"
    refute_empty facts
  end

  def test_a_document_that_cannot_be_used_is_skipped_with_its_reason
    result = research(body: "").run([["devise", "2.2.4"]])

    assert_empty result.researched
    assert_equal 1, result.skipped.length
    assert_includes result.skipped.first[:reason], "the index answered nothing this reader could use"
  end

  # The bound is stated, not implied: a lockfile past it is a *pass* that says what it did
  # not get to, rather than a short list that reads as a complete one.
  def test_a_pass_larger_than_the_bound_says_what_it_did_not_fetch
    pins = Array.new(Research::MAX_GEMS + 3) { |index| ["gem#{index}", "1.0.0"] }
    corpus = FakeCorpus.new
    pass = Research.new(corpus: corpus, fetcher: ->(_url) { "1.0.0 |checksum:aa\n" }, out: nil)

    result = pass.run(pins)

    assert_equal Research::MAX_GEMS, corpus.recorded.length
    assert_equal 1, result.skipped.length
    assert_equal "3 more", result.skipped.last[:gem]
    assert_includes result.skipped.last[:reason], "at most #{Research::MAX_GEMS} gems"
  end
end
