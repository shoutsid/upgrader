# frozen_string_literal: true

require "json"

module Agents
  module Upgrader
    # **A dry-run pull request from a stored record.** A walk is expensive; a review of what it
    # produced should not be. `Preview` reads a record (the JSON `step --record` writes, or the
    # record the corpus stored) and renders the same body `Publish` would open, without a git
    # checkout, a network, a token, or a push.
    #
    # It is the replay seam: the three applications' records can be rendered side by side with the
    # declarations they were walked from, and a change to the renderer is judged by what a reviewer
    # would read rather than by a mock of the API call.
    module Preview
      # `base_ref` is what the chain would have targeted when the record does not carry a delivery
      # base. It is a preview fact, not a walk fact, so it is a parameter rather than a record field.
      def self.render(record, base_ref: nil, report_base: nil)
        Publish.new(
          root: Dir.pwd, repository: record.repository,
          from_version: record.from_version, to_version: record.to_version,
          record: record, token: "", base_ref: base_ref, report_base: report_base
        ).preview_body
      end

      def self.from_json(text, **arguments)
        render(Record.from_h(JSON.parse(text)), **arguments)
      end

      def self.from_file(path, **arguments)
        from_json(File.read(path, encoding: "utf-8"), **arguments)
      end
    end
  end
end
