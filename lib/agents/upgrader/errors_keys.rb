# frozen_string_literal: true

module Agents
  module Upgrader
    # **A call the release removed, on the line the failure names, with the reader that replaced it.**
    #
    # Rails 7.0 removed `ActiveModel::Errors#keys` (6.1 deprecated it in favour of
    # `attribute_names`). The errors object delegates no longer: `resource.errors.keys` raises
    # `NoMethodError: undefined method 'keys' for #<ActiveModel::Errors:…>`, and the same line's
    # `attribute_names` answers the attribute list the code was asking for. Measured on ohana-api's
    # 7.0.10 rung: `app/controllers/concerns/private_registration.rb:24`, reached from the admin
    # sign-up feature spec — the first failure after the environment's translation setting moved.
    #
    # The repair changes the one call on the failing line and leaves the comparison, the receiver
    # and the rest of the expression the application's. It refuses a failure that does not name
    # `ActiveModel::Errors` (a Hash's `keys` is a different question), a line that does not carry
    # the call, and a file the working copy does not have.
    module ErrorsKeys
      # The release's own sentence for the removal. The class is what makes this family safe: a
      # Hash's `keys` is not this failure and is not rewritten.
      REMOVED = /undefined method [`']keys'? for #<ActiveModel::Errors/

      # The call, with or without a receiver. `attribute_names` is the documented reader and it
      # keeps the receiver's spelling — `resource.errors.attribute_names`.
      CALL = /\berrors\.keys\b/

      def self.for(root:, failures:)
        Array(failures).filter_map { |failure| repair(root: root, failure: failure) }
          .uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:)
        return nil unless removed?(failure)

        file = failure.file
        return nil if file.nil? || failure.line.nil?

        full = File.join(root, file)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        index = failure.line - 1
        return nil if index.negative? || index >= lines.size

        text = lines[index].chomp
        return nil unless text.match?(CALL)

        after = text.gsub(CALL, "errors.attribute_names")
        return nil if after == text

        {
          "path" => file,
          "line" => failure.line,
          "text" => text,
          "after" => after,
          "automatic" => true,
          "subject" => "errors.keys",
          "origin" => "suite-repair",
          "note" => "Rails 7.0 removed ActiveModel::Errors#keys; attribute_names is the reader " \
                    "that answers the same list (#{failure.name})"
        }
      end

      def self.removed?(failure) = failure.messages.any? { |message| message.match?(REMOVED) }
    end
  end
end
