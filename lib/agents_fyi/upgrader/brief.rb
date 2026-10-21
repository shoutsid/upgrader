# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **What the corpus already knows, before the walk decides anything.**
    #
    # A rung is not a fresh question. The ladder (`/api/rails/upgrade`) says what a release changed, and
    # this corpus holds what happened when these moves were made before — by this walk, by the miner
    # over a gem pair, by an operator who hit the same failure in a different application. The first
    # twelve-rung walk learned that the expensive part is not applying a change but deciding what to
    # do when one refuses to apply, and every one of those decisions had been made somewhere before
    # (see `docs/design-notes.md`).
    #
    # Three questions are asked, and the shape of each is the corpus's rather than a guess here:
    #
    # * **The framework move** — `GET /api/reports/upgrade` for `rails` across the rung. This is the
    #   *observed* half of the ladder: reports filed against that window, with the fix that resolved
    #   them and how that fix was verified.
    # * **Each gem the routing moves** — the same read per gem, because a gem's move carries its own
    #   reports (`factory_girl` and `squeel` both bit this application, and neither is a Rails change).
    # * **Each change's subject** — `GET /api/reports/search`, which is the only read that finds a report
    #   by the *symptom* rather than by the window. Ranked by the corpus's own `rank`, which is where
    #   rarity and an identifying signature are already weighed (`is_identifying` is the service's,
    #   computed against the live corpus; a client that recomputed it would be a second opinion about
    #   the same table). `match_type` says whether a report matched by a signature or by words, and
    #   the brief keeps that distinction because it is the difference between "this is the same
    #   failure" and "this mentions the same word".
    #
    # **Nothing here is applied.** A brief is read by a person or by the repair stage and rendered in
    # the site admin and the pull request; a fix this corpus offers is a proposal, and proposing is as
    # far as recall goes (ADR 0008, decision 4).
    class Brief
      # How many questions one brief may ask. A rung's routing moves tens of gems and the plan has
      # dozens of changes; an unbounded sweep would be a full scan of the corpus on every rung, paid
      # on the walker's link. What is not asked is *said* rather than silently dropped.
      MAX_QUESTIONS = 40

      # How many reports one question asks for. The top few are what a reader acts on; the section
      # carries the total, so "there are 40 and here are 3" is visible.
      SEARCH_LIMIT = 3

      # One report, as the brief keeps it: enough to decide whether to open it, and the fix when the
      # corpus has one.
      Item = Struct.new(:id, :title, :library, :version, :status, :trust, :rank, :match, :fix,
        keyword_init: true) do
        # A report whose match came through a stored symptom rather than words is the same failure
        # often enough to be worth trying; one matched by words alone is a mention.
        def identifying? = match.to_s != "fulltext"

        def to_h
          { "id" => id, "title" => title, "library" => library, "version" => version,
            "status" => status, "trust" => trust, "rank" => rank, "match" => match,
            "identifying" => identifying?, "fix" => fix }.compact
        end
      end

      # One question and what came back. **`state` is the answer's meaning, not its size**: a section
      # can be empty because the corpus has nothing (`nothing recorded`), because the question could
      # not be asked (`unavailable`), or because the brief's budget ran out (`not asked`) — and an
      # empty list that collapses those is the reassuring reading of the wrong thing.
      Section = Struct.new(:key, :title, :question, :state, :note, :items, :total, keyword_init: true) do
        def empty? = items.to_a.empty?

        def to_h
          { "key" => key, "title" => title, "question" => question, "state" => state,
            "note" => note, "items" => items.map(&:to_h), "total" => total }
        end
      end

      Result = Struct.new(:sections, :asked, :truncated, :unavailable, keyword_init: true) do
        def empty? = sections.all?(&:empty?)

        def to_h
          { "sections" => sections.map(&:to_h), "asked" => asked,
            "truncated" => truncated, "unavailable" => unavailable }
        end

        # The brief as the pull request body and the site admin render it. A reviewer should be able to
        # read what the walk knew before it decided, in the order it decided it.
        # `base` is where the corpus is reachable *by the reader*: a pull request is opened on
        # GitHub, so a link built from the walker's own `API_BASE_URL` (`http://service:8001`) is a
        # link nobody can open. Without a base the report is named rather than linked, which is the
        # honest rendering of "this walker does not know where you read it".
        def to_markdown(base: nil)
          return "_Nothing in the corpus speaks to this rung, and every read answered._" if empty? && !truncated

          sections.reject(&:empty?).map { |section| render(section, base: base) }.compact.join("\n")
        end

        private

        def render(section, base: nil)
          lines = ["### #{section.title}", "", "_#{section.question}_", ""]
          if section.items.empty?
            lines << "- #{section.state}#{section.note.to_s.empty? ? "" : ": #{section.note}"}"
          else
            section.items.each do |item|
              title = item.title.to_s.strip
              title = "[#{title}](#{base}/api/reports/#{item.id})" if base && !item.id.to_s.empty?
              line = "- #{item.identifying? ? "**same failure**" : "mention"} · #{title}"
              line += " — #{item.status}" unless item.status.to_s.empty?
              line += " · fix: #{item.fix}" unless item.fix.to_s.empty?
              lines << line
            end
            lines << "- …and #{section.total - section.items.length} more in the corpus" if
              section.total.to_i > section.items.length
          end
          lines.join("\n")
        end
      end

      def initialize(corpus:)
        @corpus = corpus
      end

      # `gems` are the routing's moved gems (`name`, `version`, `to`); `subjects` are the changes the
      # plan named (`subject`, `change_kind`), which are asked as search terms.
      def call(rails: nil, from:, to:, gems: [], subjects: [], decisions: [])
        @asked = 0
        sections = []
        sections << ask { framework_section(from: from, to: to) }

        Array(gems).map { |gem| gem.is_a?(Hash) ? gem : gem.to_h }
          .select { |gem| move?(gem) }
          .each { |gem| sections << ask { gem_section(gem) } }

        Array(subjects).compact.each do |subject|
          term = subject.is_a?(Hash) ? subject["subject"] : subject
          next if term.to_s.strip.empty?

          kind = subject.is_a?(Hash) ? subject["change_kind"] : nil
          sections << ask { search_section(term, kind: kind) }
        end

        sections.compact!
        sections << decisions_section(decisions)

        Result.new(sections: sections, asked: @asked, truncated: @asked >= MAX_QUESTIONS,
          unavailable: sections.count { |section| section.state == "unavailable" })
      end

      private

      # **One question, bounded, and a failed question is not a failed brief.** Every read goes
      # through here rather than being wrapped at each site, because the three outcomes want the same
      # words: answered, refused (a fact about the question), unreachable (a fact about the moment) —
      # and the last two are recorded in the section rather than raised, because recall is not
      # permission and a walk that stopped whenever the corpus blinked would never reach a rung.
      #
      # `nil` means the budget is spent: the brief says `truncated` once, rather than repeating a
      # "not asked" section for every question past the bound.
      def ask
        return nil if @asked >= MAX_QUESTIONS

        @asked += 1
        yield
      rescue Corpus::Refused, Corpus::Unreachable => e
        unavailable_section(e.message)
      end

      def unavailable_section(message)
        Section.new(key: "unavailable", title: "A question could not be asked",
          question: "the corpus did not answer", state: "unavailable", note: message,
          items: [], total: 0)
      end

      def framework_section(from:, to:)
        payload = @corpus.reports_upgrade(library: "rails", from_version: from, to_version: to)
        changes = Array(payload["changes"])
        items = changes.map { |change| item_from_change(change) }
        Section.new(key: "framework", title: "The framework move",
          question: "what this corpus observed about rails #{from} → #{to}",
          state: changes.empty? ? "nothing recorded" : "answers",
          note: changes.empty? ? empty_move_note(payload) : nil,
          items: items, total: changes.length)
      end

      def gem_section(gem)
        payload = @corpus.reports_upgrade(library: gem["name"].to_s,
          from_version: gem["version"].to_s, to_version: gem["to"].to_s)
        changes = Array(payload["changes"])
        items = changes.map { |change| item_from_change(change) }
        Section.new(key: "gem:#{gem["name"]}", title: "#{gem["name"]} #{gem["version"]} → #{gem["to"]}",
          question: "what this corpus observed about #{gem["name"]} across that move",
          state: changes.empty? ? "nothing recorded" : "answers",
          note: changes.empty? ? empty_move_note(payload) : nil,
          items: items, total: changes.length)
      end

      # The search half. `match` is kept per item and `total` is the corpus's, not the page's, so a
      # section that showed three of forty says so.
      def search_section(term, kind: nil)
        payload = @corpus.search(query: term.to_s, limit: SEARCH_LIMIT)
        items = Array(payload["items"]).map { |row| item_from_search(row) }
        state = items.empty? ? "nothing recorded" : "answers"
        note = kind.to_s.empty? ? nil : "a #{kind} change"
        Section.new(key: "search:#{term}", title: term.to_s,
          question: "reports matching #{term.to_s.inspect}#{note.nil? ? "" : " (a #{kind} change)"}",
          state: state, note: items.empty? ? "no report matched this subject" : nil,
          items: items, total: payload["total"].to_i)
      end

      # Our own earlier answers, as the walk recorded them. Empty until decisions are first-class
      # (see `docs/design-notes.md`), and a section either way: a reader should see
      # that the walk looked for its own past than infer that it did not.
      def decisions_section(decisions)
        entries = Array(decisions)
        Section.new(key: "decisions", title: "What this walk decided before",
          question: "answers from earlier rungs and earlier applications",
          state: entries.empty? ? "nothing recorded" : "answers",
          note: entries.empty? ? "no decision has been answered for this walk yet" : nil,
          items: entries.map { |decision|
                   effects = Array(decision["effects"]).filter_map { |effect| effect["kind"] if effect.is_a?(Hash) }
                   Item.new(title: decision["question"] || decision["subject"],
                     status: decision["answer"],
                     fix: decision["effect"] || (effects.any? ? "#{effects.uniq.join(", ")} effect(s)" : nil),
                     rank: nil, match: "decision") },
          total: entries.length)
      end

      def item_from_change(change)
        Item.new(id: change["report_id"] || change["id"], title: change["title"],
          library: change["library"], version: change["version"], status: change["status"],
          trust: change["trust"], rank: change["rank"], match: change["change_kind"] || "change",
          fix: change["resolution"] || change["fix"] || change["replacement"])
      end

      def item_from_search(row)
        Item.new(id: row["id"], title: row["title"], library: row["library"], version: row["version"],
          status: row["status"], trust: row["trust"], rank: row["rank"],
          match: row["match_type"] || "search",
          fix: row["resolution"] || row["fix"] || row["replacement"])
      end

      # `/api/reports/upgrade` distinguishes four meanings for an empty list, and the most reassuring one
      # is the wrong one. The route's own `next_step` says which, so it is quoted rather than
      # paraphrased.
      def empty_move_note(payload)
        next_step = payload["next_step"].to_s.strip
        return next_step unless next_step.empty?

        unmatched = payload["unmatched_changes"].to_i
        return "#{unmatched} change(s) in this window are not recorded as changes, so nothing here is a statement about them" if unmatched.positive?

        "no report in this corpus covers this window"
      end

      def move?(gem)
        return false unless %w[move replace remove].include?(gem["verdict"].to_s)

        !gem["name"].to_s.empty? && !gem["to"].to_s.empty?
      end
    end
  end
end
