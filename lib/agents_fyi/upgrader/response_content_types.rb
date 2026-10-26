# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **An assertion that read a MIME type out of a header the release now returns whole.**
    #
    # Rails 6.1's `ActionDispatch::Response#content_type` returns the Content-Type header as sent —
    # `application/json; charset=utf-8` — where 6.0 and earlier stripped the charset. That release
    # said so in 6.0's own deprecation ("Rails 6.1 will return Content-Type header without
    # modification"), and the value the old code returned lives on as `#media_type`. So a spec
    # written against the old reader — `expect(response.content_type).to eq("application/json")` —
    # fails on a response that is correct, with the release's own answer printed underneath the
    # expectation.
    #
    # Measured on ohana-api's 6.1.7.10 rung: eight examples, all in `spec/api/`, every one
    # `expected: "application/json"` against `got: "application/json; charset=utf-8"`.
    #
    # The repair moves the receiver of the assertion rather than rewriting what it claims:
    # `response.media_type` is the value the assertion was written against, the matcher and the
    # expected text stay the application's, and the line edited is the one the failure names. What
    # it refuses, and why:
    #
    # * **A failure that is not an equality mismatch** is not this family's. RSpec prints
    #   `expected: …` / `got: …` for `eq`; a raised exception or a matcher's own sentence is a
    #   different question, and the content-type reader is not the reason for it.
    # * **A line outside `spec/`/`test/`** is the application, not a test of it. A controller that
    #   read the response's content type is code whose meaning the move changed, and choosing
    #   between `media_type` and the whole header there is a person's decision.
    # * **A file the tree does not have** is a refusal rather than a crash, the same rule every
    #   suite-repair family follows.
    #
    # The rewrite cannot hide a real failure: if the response's type actually changed (a controller
    # started rendering HTML), the same assertion fails again on `media_type` and the walk reports
    # the rung as failed.
    module ResponseContentTypes
      # RSpec's `eq` diff, which is the only failure shape this family repairs. The expected value
      # is not read: the line's own assertion is the claim, and the reader is what moved.
      EQUALITY = /\Aexpected(?::|\s)/

      # The receiver and its call, as an expression. `response.content_type` in a comment or a
      # string is not this family's line either — the assertion and the call have to be on it.
      READER = /\bresponse\.content_type\b/
      EXPECTATION = /\bexpect\s*\(/

      def self.for(root:, failures:)
        Array(failures).filter_map { |failure| repair(root: root, failure: failure) }
          .uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:)
        return nil unless failure.messages.any? { |message| message.match?(EQUALITY) }

        file = failure.file
        return nil if file.nil? || failure.line.nil? || !suite_file?(file)

        full = File.join(root, file)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        index = failure.line - 1
        return nil if index.negative? || index >= lines.size

        text = lines[index].chomp
        return nil unless text.match?(EXPECTATION) && text.match?(READER)

        after = text.gsub(READER, "response.media_type")
        return nil if after == text

        {
          "path" => file,
          "line" => failure.line,
          "text" => text,
          "after" => after,
          "automatic" => true,
          "subject" => "response content type",
          "origin" => "suite-repair",
          "note" => "Rails 6.1 returns the Content-Type header whole from `content_type`, " \
                    "charset included; `media_type` is the value this assertion was written " \
                    "against (#{failure.name})"
        }
      end

      # A suite's file, in either layout this tool walks: RSpec's `spec/` and Minitest's `test/`.
      # The failure's own `file` has already had its `./` removed (`SuiteFailures::Failure#file`).
      def self.suite_file?(file) = file.start_with?("spec/", "test/")
    end
  end
end
