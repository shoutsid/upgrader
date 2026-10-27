# frozen_string_literal: true

module Agents
  module Upgrader
    # **An assertion on a redirect's body, repaired to read the location the redirect carries.**
    #
    # Rails 7.1 stopped writing the `You are being redirected` page: `ActionController::Redirecting`
    # now sets an empty body (measured on actionpack 7.1.6, `redirecting.rb:96`, against 7.0.10's
    # HTML), so a spec that asserted *where a redirect sent the caller* through `response.body`
    # starts failing with `expected "" to match "error=invalid_scope"`. Measured on diaspora's
    # 7.1.6 rung: three examples in one OpenID Connect spec, each reading the redirect's target out
    # of the framework's courtesy page rather than out of the response.
    #
    # The repair is a one-word change and it is not a guess about what the example meant:
    #
    # * **the failure says the actual was the empty string**, so the body assertion is failing on
    #   the body the release removed and not on content that came out wrong — a body that says the
    #   wrong thing is a real failure and this module leaves it alone;
    # * **the line the failure names is the assertion itself**, and it is rewritten in place, so the
    #   expectation, its matcher and its expected text are the application's own;
    # * **`response.location` is the same claim read from where the answer lives.** The suite that
    #   already carried this spelling beside the broken ones (`expect(response.location).to
    #   match("error=invalid_request")` in the same diaspora file) is what makes it the
    #   application's idiom rather than this module's invention.
    #
    # What it refuses, and why: a body assertion that failed with content (the expected text is not
    # what came back) is not repaired, because the redirect is not the reason; a line that is not an
    # expectation on `response.body` is not touched, because there is nothing to move; and a file
    # outside `spec/`/`test/` is left alone, because a line there is the application and the
    # assertion belongs to the suite. A rewrite that guessed wrong would still be measured — the
    # suite runs again and a `location` that is nil fails the same expectation — but a rule that
    # cannot be wrong is better than one whose error the next run catches.
    module RedirectBodies
      # **RSpec's own words for an expectation whose actual was the empty string** — the body
      # Rails 7.1 leaves on a redirect. The matcher and the expected text are on the same line and
      # are not read: the assertion is moved, not rewritten.
      EMPTY_BODY = /\Aexpected "" to /

      # The assertion this module moves, and only the receiver of it. A line that mentions
      # `response.body` anywhere else (an `include` over a rendered page, a debug print) has no
      # `expect(` in front of it and is not this family's.
      ASSERTION = /expect\(response\.body\)/

      def self.for(root:, failures:)
        Array(failures).filter_map { |failure| repair(root: root, failure: failure) }
          .uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:)
        return nil unless empty_body?(failure)

        file = failure.file
        return nil if file.nil? || failure.line.nil? || !suite_file?(file)

        full = File.join(root, file)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        index = failure.line - 1
        return nil if index.negative? || index >= lines.size

        text = lines[index].chomp
        return nil unless text.match?(ASSERTION)

        after = text.sub(ASSERTION, "expect(response.location)")
        return nil if after == text

        {
          "path" => file,
          "line" => failure.line,
          "text" => text,
          "after" => after,
          "automatic" => true,
          "subject" => "redirect body",
          "origin" => "suite-repair",
          "note" => "Rails 7.1 stopped writing a body with a redirect, so this assertion read the " \
                    "redirect's target out of a page the framework no longer sends; `response.location` " \
                    "is where the answer is (#{failure.name})"
        }
      end

      def self.empty_body?(failure)
        failure.messages.any? { |message| message.match?(EMPTY_BODY) }
      end

      # A suite's file, in either layout this tool walks: RSpec's `spec/` and Minitest's `test/`.
      # The failure's own `file` has already had its `./` removed (`SuiteFailures::Failure#file`).
      def self.suite_file?(file)
        file.start_with?("spec/", "test/")
      end
    end
  end
end
