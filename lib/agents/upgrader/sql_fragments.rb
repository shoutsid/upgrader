# frozen_string_literal: true

module Agents
  module Upgrader
    # **A raw SQL fragment that Rails 6.1 no longer accepts as an attribute name.**
    #
    # `order`, `pluck`, `select` and `group` used to take a string and pass it through. Rails 6.1
    # added `ActiveRecord::UnknownAttributeReference` for an argument it cannot prove is an
    # attribute, so a suite that was green on 6.0 dies on the same line with:
    #
    #   Query method called with non-attribute argument(s): "SUM((EXTRACT(EPOCH FROM ...)))"
    #
    # The framework's own answer is `Arel.sql(...)` — it says "this string is SQL, not a column
    # name" without changing the SQL. The failure names the fragment and the line, so this is a
    # mechanical repair rather than a decision: wrap the arguments of the failing call that are
    # literal strings or bare local variables, and leave symbols, hashes and expressions alone.
    #
    # Measured on volunteer_portal's 6.0.6.1 -> 6.1.7.10 rung: the resolver's `.order(order)` and
    # the loader's `.pluck('"signups"."user_id"', 'SUM(...)')` produced eight errors, all the same
    # shape, and both lines are in the application's own source.
    module SqlFragments
      MESSAGE = /Query method called with non-attribute argument\(s\):\s*["'](.+)["']/
      CALL = /\.(order|reorder|select|pluck|group)\((.*)\)/

      def self.for(root:, failures:)
        Array(failures).filter_map { |failure| repair(root: root, failure: failure) }
          .uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:)
        fragment = failure.messages.filter_map { |message| message[MESSAGE, 1] }.first
        return nil if fragment.nil? || failure.file.nil? || failure.line.nil?

        full = File.join(root, failure.file)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        index = failure.line - 1
        return nil if index.negative? || index >= lines.size

        text = lines[index].chomp
        call = text.match(CALL)
        return nil if call.nil?

        arguments = split_arguments(call[2])
        rewritten = arguments.map { |argument| wrap(argument) }
        return nil if rewritten == arguments

        after = text.sub(call[0], ".#{call[1]}(#{rewritten.join(",")})")
        return nil if after == text

        {
          "path" => failure.file,
          "line" => failure.line,
          "text" => text,
          "after" => after,
          # **Not `Arel.sql`.** The applier reads a subject as a ladder change and refuses a
          # change it knows is a decision rather than a whole-word rename; `Arel.sql` is exactly
          # one of those, so an edit labelled with it was refused even though the line was the
          # suite's own failure. The subject here is the failure class, not the ladder's change.
          "automatic" => true,
          "subject" => "UnknownAttributeReference",
          "origin" => "suite-repair",
          "note" => "Rails 6.1 refuses a raw SQL fragment in #{call[1]}; Arel.sql marks the " \
                    "same fragment as SQL without changing it (the failure named #{fragment})"
        }
      end

      # The arguments at the call's own depth. A comma inside a string or a nested call is not a
      # separator, which is why this is a small scanner rather than `split(",")`.
      def self.split_arguments(text)
        arguments = []
        current = +""
        depth = 0
        quote = nil
        escaped = false

        text.each_char do |char|
          if quote
            current << char
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == quote
              quote = nil
            end
          elsif ["'", '"'].include?(char)
            quote = char
            current << char
          elsif "([{".include?(char)
            depth += 1
            current << char
          elsif ")]}".include?(char)
            depth -= 1
            current << char
          elsif char == "," && depth.zero?
            arguments << current
            current = +""
          else
            current << char
          end
        end
        arguments << current
        arguments
      end

      # A literal string or a bare local variable is the shape both measured failures use. A
      # symbol is already an attribute; a call, hash or expression is not something this rule can
      # prove is the SQL fragment, so it is left exactly as written.
      def self.wrap(argument)
        value = argument.strip
        return argument if value.empty? || value.start_with?("Arel.sql(")
        return argument unless value.match?(/\A(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\z/) ||
                               value.match?(/\A[a-z_][A-Za-z0-9_]*\z/)

        argument.sub(value, "Arel.sql(#{value})")
      end
    end
  end
end
