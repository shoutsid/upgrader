# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # What an old application's Gemfile needs *before* anything can be installed.
    #
    # A step begins by installing the application's bundle, and an application from 2013
    # often cannot be installed at all: its sources use a protocol GitHub no longer
    # speaks (`git://`, accepted until 2022), a fork it pinned has been deleted, a gem
    # it declares cannot sit beside the framework it is moving to, or a branch pin
    # stands in for a release that has since shipped. None of those are facts about the
    # move the ladder asked for; they are facts about the *application's own choices*,
    # and the install failure that reports them is the same failure for all four.
    #
    # So the preflight runs first and has two halves:
    #
    # * **General repairs**, which need no knowledge of gems: a `git://` remote rewritten
    #   to `https://` in the Gemfile *and* the lockfile, because Bundler reads the
    #   protocol out of the lockfile's own `remote:` lines and rewriting one file leaves
    #   the other pointing at GitHub's refusal.
    # * **Digest repairs**, from `GET /gems/migrations`: the curated, attributed moves a
    #   machine may make without reading the application's code. `mechanical` is the
    #   whole of what this class will act on; every other entry becomes a decision, because
    #   a Gemfile line it cannot rewrite alone is one a person or an agent has to look at.
    #
    # Three rules carry the weight, and each is a line somebody's Gemfile is on the other
    # side of:
    #
    # * **A declaration this class does not fully understand is not rewritten.** A
    #   declaration spanning several lines, one carrying a comment, one carrying an option
    #   that changes behaviour rather than sourcing (`require:`, `platforms:`) — each is
    #   skipped with the reason recorded. Rewriting what it cannot parse is how a
    #   preflight breaks an application quietly; a preflight that skipped something says
    #   so, and the install that follows is the same failure it would have been.
    # * **A gem the application does not declare is not the application's line.** An entry
    #   whose gem is in the lockfile but pulled in by something else becomes a decision
    #   naming that fact, rather than an edit to a line nobody wrote.
    # * **An unreadable digest narrows the preflight; it does not stop it.** A deployment
    #   whose service is older than this route refuses with a 404, and the record says the
    #   digest was not consulted. The general repairs still run — they are facts about the
    #   protocol rather than about an index — and the sentence says which half was skipped
    #   rather than leaving a short repair list to read as a clean Gemfile.
    class Preflight
      # The two files a protocol repair touches. Both, and deliberately: see above.
      SOURCES = %w[Gemfile Gemfile.lock].freeze

      # A declaration, with its indentation and its name. The name is captured so a
      # lookup by name cannot match a longer one — `gem "cancan"` is not `gem
      # "cancancan"` — and the indentation is kept so a rewritten line stays where the
      # application put it.
      DECLARATION = /\A(\s*)gem\s+["']([^"']+)["']/

      # The options that name *where* a gem comes from, and so may be dropped when the
      # digest says which release to declare instead. Anything else on the line
      # (`require:`, `platforms:`, `group:`) changes what the application does and makes
      # the declaration one this class will not rewrite.
      SOURCE_OPTIONS = %w[git github branch ref tag path source submodules glob].freeze

      # Bundler's `github:` shorthand. It is the *second* spelling of the dead protocol and
      # the one this class nearly missed: Bundler 1.x expands `github: "owner/name"` to
      # `git://github.com/owner/name.git`, which is why every 2013 Gemfile that pinned a fork
      # broke at once — and why rewriting only the literal `git://` left the first real
      # application's install stuck cloning over a protocol GitHub stopped accepting.
      GITHUB_OPTION = /github:\s*(["'])([^"']+)\1/

      # One repair that was written: the line before, the line after, and the gem it is
      # about. The field names are `Applier::Applied`'s so a record can show a preflight
      # repair and a scanned edit the same way.
      Repair = Struct.new(:path, :line, :text, :after, :subject, :note, keyword_init: true)

      # Nothing here is an application.
      class NotAnApplication < StandardError; end

      # Everything the preflight did, in the two lists a record already has places for
      # and the sentences that say what it could not do.
      Result = Struct.new(:repairs, :decisions, :notes, keyword_init: true) do
        def empty? = repairs.empty? && decisions.empty?

        # The one-line summary the `preflight:` stage carries, and the mode prints.
        def summary
          "#{repairs.size} repair(s), #{decisions.size} decision(s)" \
            "#{notes.empty? ? "" : ", #{notes.size} note(s)"}"
        end

        # The details, one per line, in the record's bounded tail.
        def details
          lines = repairs.map do |repair|
            # **An addition has no line to quote.** A declaration the digest asks for is a line
            # the application does not have, so `text` is nil and there is nothing to render
            # before the arrow — and a renderer that called `.strip` on nil would turn a repair
            # into a crash in the one place a record is being written.
            if repair.text.nil?
              "#{repair.path}: `#{repair.after.strip}` declared (#{repair.subject})"
            else
              "#{repair.path}:#{repair.line} `#{repair.text.strip}` -> `#{repair.after.strip}` " \
                "(#{repair.subject})"
            end
          end
          lines += decisions.map do |decision|
            "decide #{decision.subject}: #{decision.reason}"
          end
          lines + notes
        end

        def to_h
          {
            "repairs" => repairs.map { |repair|
              { "path" => repair.path, "line" => repair.line, "text" => repair.text,
                "after" => repair.after, "subject" => repair.subject, "note" => repair.note }
            },
            "decisions" => decisions.map { |decision|
              { "path" => decision.path, "line" => decision.line, "subject" => decision.subject,
                "reason" => decision.reason, "kind" => decision.kind,
                "replacement" => decision.replacement, "source" => decision.source }
            },
            "notes" => notes
          }
        end

        def to_s
          lines = ["preflight: #{summary}"]
          details.each { |line| lines << "  #{line}" }
          lines.join("\n")
        end
      end

      # `ruby` is the interpreter the move will run on, as far as the caller knows it — the
      # *lowest* one the rung allows, because this stage runs before the machine is chosen (the
      # choice is itself a `bundle install`, so the Gemfile has to be installable first). It is
      # what a digest entry's `when` is evaluated against, and a caller that cannot name one is
      # told which entries it therefore could not apply rather than being served them silently.
      def initialize(root:, corpus: nil, ruby: nil, rails: nil)
        @root = File.expand_path(root)
        @corpus = corpus
        @ruby = ruby.to_s.strip
        # The release the move *ends at*, which is what makes an entry rung-scoped. Nil in the
        # standalone `preflight` mode, which is asked about a repository rather than about a move —
        # and a rung condition this cannot evaluate is a note at the call site, not a guess.
        @rails = rails.to_s.strip
      end

      def run
        unless File.file?(File.join(@root, "Gemfile")) || File.file?(File.join(@root, "Gemfile.lock"))
          raise NotAnApplication,
            "#{@root} has neither a Gemfile nor a Gemfile.lock, so there is nothing to " \
            "preflight — this tool moves Rails applications"
        end

        repairs = protocol_repairs
        decisions = []
        notes = []
        digest(notes).each do |entry|
          digest_repair(entry, repairs, decisions, notes)
        end
        Result.new(repairs: repairs, decisions: decisions, notes: notes)
      end

      private

      # `git://` was accepted until GitHub turned it off in 2022, and every 2013 Gemfile that
      # pinned a fork carries it — literally, or through Bundler's `github:` shorthand. Both
      # spellings are repaired here, in both files: the lockfile's own `remote:` lines carry
      # the expanded URL, and the Gemfile carries whichever spelling the application wrote.
      def protocol_repairs
        repairs = []
        SOURCES.each do |name|
          path = File.join(@root, name)
          next unless File.file?(path)

          lines = File.binread(path).split("\n", -1)
          changed = false
          lines.each_with_index do |line, index|
            after, subject, note = protocol_line(line)
            next if after.nil?

            lines[index] = after
            changed = true
            repairs << Repair.new(path: name, line: index + 1, text: line, after: after,
              subject: subject, note: note)
          end
          File.binwrite(path, lines.join("\n")) if changed
        end
        repairs
      end

      # One line, repaired for the protocol, or nil when it needs nothing.
      #
      # The two spellings become one answer: an explicit `git:` remote over `https://`. The
      # shorthand is *expanded* rather than swapped, because there is no scheme to swap — and
      # the line's own quoting and every other option it carries (a `branch:`, most often)
      # are kept exactly as written; only the source is rewritten.
      def protocol_line(line)
        if line.include?("git://")
          return [line.gsub("git://", "https://"), "git://",
            "GitHub stopped accepting the git:// protocol in 2022; https:// is the same " \
            "source over the protocol it still speaks"]
        end
        return [nil, nil, nil] unless line.include?("github:")

        after = line.sub(GITHUB_OPTION) do
          quote = Regexp.last_match(1)
          remote = Regexp.last_match(2).strip.delete_suffix(".git")
          %(git: #{quote}https://github.com/#{remote}.git#{quote})
        end
        return [nil, nil, nil] if after == line

        [after, "github:",
          "Bundler expands github: to git://github.com/... — the same protocol GitHub " \
          "stopped accepting in 2022 — so the shorthand becomes the git: remote it stands " \
          "for, over https://"]
      end

      # How many names one digest question may carry. Mirrored from the route
      # (`Upgrade::Migrations::GEMS_LIMIT`) rather than discovered by being refused, and
      # pinned to it by a test: two components, one bound, and a client that sent a prefix
      # silently would be asking an incomplete question that reads as a complete answer.
      DIGEST_GEMS_LIMIT = 300

      # The digest, bounded to the gems this application can be asked about: the ones it
      # declares, plus the ones it merely locked so the answer can say that a move exists
      # and belongs to another gem's line.
      def digest(notes)
        names = declared_gems + (locked_gems - declared_gems)
        if names.size > DIGEST_GEMS_LIMIT
          notes << "#{names.size} gem name(s) would have to be asked about and this client " \
                   "sends at most #{DIGEST_GEMS_LIMIT}: the declared ones and the first of the " \
                   "rest were asked, so a migration for a gem further down the lockfile may " \
                   "not appear here"
          names = names.first(DIGEST_GEMS_LIMIT)
        end

        payload = client.gem_migrations(gems: names)
        payload.fetch("migrations", [])
      rescue Corpus::Unreachable, Corpus::Refused => e
        notes << "the gem-migrations digest was not read (#{e.message}), so only the general " \
                 "preflight repairs were applied; an install that fails may be failing for a " \
                 "reason the digest knows about"
        []
      end

      def client
        @client ||= @corpus || Corpus.new(base: nil)
      end

      # One digest entry, against the application's own Gemfile.
      #
      # The order of the checks is the decision: whether the gem is declared at all comes
      # first (an entry for a gem nobody declared has no line to rewrite), then whether
      # the move is mechanical, then whether the declaration is one this class can
      # rewrite. `declaration_index` finds the line once, so the skip reasons and the
      # rewrite name the same line.
      def digest_repair(entry, repairs, decisions, notes)
        name = entry["gem"].to_s
        # **A condition guards every kind, not only a declaration.** A digest entry is a fact about an
        # era, and the era is not always the one being walked: measured at the 4.2 rung, the digest's
        # `devise ~> 3.0.0` is the line 4.0 and 4.1 need and the wrong one at 4.2. The entry that does
        # not apply says so rather than being applied blind.
        unless holds?(entry)
          notes << "the digest's entry for #{name} was not applied: #{why_not(entry)} " \
                   "(#{condition_sentence(entry)}) — #{entry["note"]}"
          return
        end

        found = declaration(name)
        return declare(entry, found, repairs, decisions, notes) if entry["kind"].to_s == "declared"

        if found.nil?
          return unless locked_gems.include?(name)

          decisions << decision(entry, path: "Gemfile.lock", line: nil,
            reason: "#{name} is in the lockfile but not declared in the Gemfile, so whatever " \
                    "pulls it in is the gem whose line moves: #{entry["note"]}")
          return
        end

        index, line = found
        unless entry["mechanical"] == true
          decisions << decision(entry, path: "Gemfile", line: index + 1, reason: entry["note"])
          return
        end

        skip = unrewritable(line, kind: entry["kind"].to_s)
        if skip
          notes << "Gemfile:#{index + 1} declares #{name} as `#{line.strip}`, which #{skip}; " \
                   "#{entry["note"]}"
          return
        end

        after = rewrite(entry, line)
        if after.nil?
          notes << "the digest says #{name} becomes #{entry["replacement"] || "nothing"}; " \
                   "this tool has no rewrite for that"
          return
        end
        # Already what the digest asks for — a second preflight over the same tree, or a
        # declaration the application updated itself. Nothing changed, so there is nothing
        # to record: a repair list is the lines that moved.
        return if after == line

        lines = File.binread(File.join(@root, "Gemfile")).split("\n", -1)
        if after.empty?
          lines.delete_at(index)
        else
          lines[index] = after
        end
        File.binwrite(File.join(@root, "Gemfile"), lines.join("\n"))
        repairs << Repair.new(path: "Gemfile", line: index + 1, text: line, after: after,
          subject: name, note: entry["note"])
      end

      # **A declaration is the repair, and it is for a gem the application does not hold yet.**
      # The kind exists because the hold the pin keeps cannot see this case: a gem that *arrives*
      # with the framework has no earlier version in the lock to be put back, so the resolver takes
      # its newest — and on an old interpreter that newest can be a release whose code needs a
      # nokogiri the interpreter cannot install. Measured at the 4.2 rung: Rails 4.2 brings in
      # `rails-html-sanitizer`, which brings in loofah 2.21.1, whose code needs `Nokogiri::HTML4`
      # while Ruby 2.1 caps nokogiri at 1.9.1, and `rails:update` died on the constant.
      #
      # The application's own line is the application's: a gem it already declares is left alone
      # (the digest is not asked about a line it did not write). And a condition that cannot be
      # evaluated is a *note*, not a silent pass — the honest half of this is saying which
      # declarations were not applied and why.
      def declare(entry, found, repairs, decisions, notes)
        name = entry["gem"].to_s
        return if found

        unless entry["mechanical"] == true
          decisions << decision(entry, path: "Gemfile", line: nil, reason: entry["note"])
          return
        end

        line = %(gem "#{name}", "#{entry["requirement"]}")
        gemfile = File.join(@root, "Gemfile")
        text = File.binread(gemfile)
        separator = text.empty? || text.end_with?("\n") ? "" : "\n"
        File.binwrite(gemfile, "#{text}#{separator}#{line}\n")
        repairs << Repair.new(path: "Gemfile", line: nil, text: nil, after: line,
          subject: name, note: entry["note"])
      end

      # Whether the entry's condition holds for the interpreter this move will run on. The one
      # condition the digest states so far is a Ruby floor, and no interpreter means the condition
      # cannot be evaluated at all — which is `false` here and a note at the call site.
      # **Whether an entry's condition holds for this move, clause by clause, and every clause must.**
      # The vocabulary is small on purpose — a digest entry is a fact about an era, and an era is named
      # by the two things a move knows about itself:
      #
      # * `ruby_below` — the interpreter the move will run on, which this stage knows as the rung's
      #   floor (see `initialize`: the machine is chosen after this, and the choice is a
      #   `bundle install`);
      # * `rails_below` / `rails_at_least` — the release the move ends at, which is what lets a gem
      #   have to move twice in one walk.
      #
      # A clause this stage cannot evaluate makes the whole entry inapplicable: an unnamed interpreter,
      # a rung in a mode that was not told one, or a clause this build does not know. The call site
      # says which, so a skipped entry is visible rather than silent.
      def holds?(entry)
        condition = entry["when"]
        return true unless condition.is_a?(Hash)

        condition.all? { |clause, value| clause_holds?(clause.to_s, value.to_s.strip) }
      end

      # The clauses this build knows. Named once, because the evaluator and the sentence that says
      # *why* an entry did not apply have to agree about the vocabulary — an unknown clause is a note,
      # not a silent skip.
      KNOWN_CLAUSES = %w[ruby_below rails_below rails_at_least].freeze

      def clause_holds?(clause, value)
        return true if value.empty?
        return false unless KNOWN_CLAUSES.include?(clause)

        named = clause.start_with?("ruby") ? @ruby : @rails
        return false if named.empty?

        clause == "rails_at_least" ? Gem::Version.new(named) >= Gem::Version.new(value) :
          Gem::Version.new(named) < Gem::Version.new(value)
      end

      # **Why an entry did not apply, in the cases that differ.** A condition this move does not meet,
      # a clause this build does not know, and a clause whose fact this stage was never told (no
      # interpreter in a mode that has no machine, no rung in a mode asked about a repository) are
      # three different reasons, and a sentence that said "did not apply" for all of them would hide
      # the one a caller can act on — telling the walker the rung, or the digest author the clause.
      def why_not(entry)
        condition = entry["when"]
        return "this move does not meet it" unless condition.is_a?(Hash)

        unknown = condition.keys.reject { |clause| KNOWN_CLAUSES.include?(clause.to_s) }
        return "it states #{unknown.join(", ")}, which this build does not know" if unknown.any?

        unnamed = condition.keys.select { |clause| (clause.to_s.start_with?("ruby") ? @ruby : @rails).empty? }
        if unnamed.any?
          return "it is scoped by #{unnamed.join(", ")}, and this stage was not told " \
                 "#{unnamed.map { |clause| clause.to_s.start_with?("ruby") ? "the interpreter" : "the rung" }.uniq.join(" or ")}"
        end

        "this move does not meet it"
      end

      # The condition as a reader can check it, for the note that says why an entry did not apply.
      def condition_sentence(entry)
        condition = entry["when"]
        return "none stated" unless condition.is_a?(Hash)

        condition.map { |clause, value| "#{clause} #{value}" }.join(", ")
      end

      # The line the Gemfile declares this gem on, or nil. `DECLARATION` matches the whole
      # line, so a gem whose name is a prefix of another's is never found by the other's
      # name — and a declaration this cannot read (old hash syntax, an unquoted name) is
      # not found either, which is a skip and not a wrong edit.
      def declaration(name)
        path = File.join(@root, "Gemfile")
        return nil unless File.file?(path)

        File.binread(path).split("\n", -1).each_with_index do |line, index|
          match = DECLARATION.match(line)
          return [index, line] if match && match[2] == name
        end
        nil
      end

      # Whether this declaration is one the digest repair may touch, and why not when it is
      # not. The kind matters: a *removal* takes the whole line, so what the line's options
      # say does not change what happens to it, while a *rewrite* has to leave the gem where
      # the application put it — which is why an option that changes behaviour (`require:`,
      # `platforms:`, `group:`) makes the declaration one this class will not rewrite.
      # A declaration spanning several lines is skipped either way: the one line this class
      # sees is not the whole of it, and half a removal is a syntax error.
      def unrewritable(line, kind:)
        return "spans several lines, so the one line this class sees is not the whole" if line.rstrip.end_with?(",")
        return nil if kind == "removed"
        if kind == "require_false"
          # A line that already names its own `require:` has made this decision for itself —
          # either it is already `require: false` (nothing to do) or it asks for something
          # this class will not second-guess. And the option-token check below deliberately
          # does not apply to this kind: the rewrite *appends* an option, so a `group:` or a
          # version on the line is kept, not dropped.
          return "already states its own require:" if line.match?(/require:/)
          return "carries a comment this class will not risk rewriting around" if line.match?(/\s#/)

          return nil
        end
        return "carries a comment this class will not risk rewriting around" if line.match?(/\s#/)

        # The option names, with quoted values removed first so a URL's `https:` is not
        # read as an option called `https`.
        tokens = line.sub(DECLARATION, "").gsub(/"[^"]*"|'[^']*'/, "\"\"")
                     .scan(/([a-z_]+):/).flatten.uniq
        extra = tokens - SOURCE_OPTIONS
        return nil if extra.empty?

        "carries #{extra.sort.join(", ")}, which changes what the application does rather " \
          "than where the gem comes from"
      end

      # The new declaration: the gem the digest names, the requirement it gives for this
      # era, and the application's own indentation. No requirement means the resolver
      # chooses, which is the honest instruction when the digest has no reason to name
      # one. No trailing newline — the file's own line terminator is the file's business,
      # and a rewrite that carried one would add a blank line to the application's Gemfile.
      def rewrite(entry, line)
        indent = DECLARATION.match(line)&.[](1).to_s
        case entry["kind"].to_s
        when "require_false"
          # The gem stays where the application put it and gains one option: Bundler still
          # installs it, and nothing requires it at boot. Appended rather than rebuilt, so a
          # line carrying a `group:` or a version keeps both.
          "#{line.rstrip}, require: false"
        when "replaced", "updated"
          replacement = entry["replacement"].to_s
          return nil if replacement.empty?

          requirement = entry["requirement"].to_s
          if requirement.empty?
            %(#{indent}gem "#{replacement}")
          else
            %(#{indent}gem "#{replacement}", "#{requirement}")
          end
        when "removed"
          # Nothing where the declaration was: the line goes, and the file's own shape
          # (a group block, a comment above) keeps working without it.
          ""
        end
      end

      def declared_gems
        return @declared_gems unless @declared_gems.nil?

        path = File.join(@root, "Gemfile")
        @declared_gems =
          if File.file?(path)
            File.binread(path).split("\n").filter_map do |line|
              match = DECLARATION.match(line)
              match && match[2]
            end.map { |name| name.force_encoding(Encoding::UTF_8) }.uniq
          else
            []
          end
      end

      def locked_gems
        @locked_gems ||= begin
          Lockfile.read(@root).specs.map { |spec| spec.first.to_s }.uniq
        rescue Lockfile::Missing, Lockfile::Unreadable
          []
        end
      end

      def decision(entry, path:, line:, reason:)
        Record::Decision.new(
          path: path, line: line, subject: entry["gem"].to_s,
          reason: reason.to_s, kind: entry["kind"],
          replacement: entry["replacement"], source: entry["source"]
        )
      end
    end
  end
end
