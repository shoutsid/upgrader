# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **An association whose foreign key the database does not have, repaired from the schema.**
    #
    # Rails 7.0 derives a `has_one`/`has_many` foreign key from `active_record.model_name`, and an
    # STI subclass reports its *base* class's name. Measured on diaspora at the 7.0.10 rung:
    # `StatusMessage < Post` declares `has_one :poll` and `has_one :location`, the tables are
    # `polls.status_message_id` and `locations.status_message_id`, and after the pin every query
    # became `WHERE "polls"."post_id" = $1` — `PG::UndefinedColumn` on 200-odd examples that have
    # nothing to do with polls. The 6.1 release derived the key from `active_record.name`, which is
    # the subclass, so the application was never wrong and there is nothing here to decide.
    #
    # The repair is answered from two facts the application already holds and neither is a guess:
    #
    # * the failure names the table and the column the association asked for (`column polls.post_id
    #   does not exist`), which is the *derived* key;
    # * `db/schema.rb` (or `db/structure.sql`) names the columns the table has, and the subclass's
    #   own name is the column the application has been using all along (`status_message_id`).
    #
    # So an edit is produced only when the missing key is exactly the base class's and the table
    # really has the subclass's — the alternative, inventing a key from a name, is the failure mode
    # this tool is built not to have. Every edit goes through `Applier`, which compares the line the
    # suite reported with the file, and the suite runs again afterwards.
    module Associations
      # `PG::UndefinedColumn: ERROR:  column polls.post_id does not exist`. The quotes are optional
      # because the adapter prints the table bare in this message and quoted in others.
      MISSING_COLUMN = /\bcolumn\s+"?([A-Za-z_]\w*)"?\.(\w+)\s+does not exist/i

      # A declaration this module may write to: one association per line, no foreign key of its own
      # and no form that changes what the key means (`through`, `as`, `polymorphic`, `class_name`).
      ASSOCIATION = /\A(\s*)(has_one|has_many|belongs_to)\s+:(\w+)(.*)\z/

      # The plural spellings a Rails model may use for a table, tried in order; the schema decides
      # which one exists.
      PLURALS = ["%s", "%ss", "%ses", "%sies"].freeze

      def self.for(root:, failures:)
        schema = schema_columns(root)
        return [] if schema.empty?

        Array(failures).flat_map do |failure|
          repair(root: root, failure: failure, schema: schema)
        end.uniq { |edit| [edit["path"], edit["line"], edit["after"]] }
      end

      def self.repair(root:, failure:, schema:)
        pair = failure.messages.filter_map { |message| MISSING_COLUMN.match(message) }.first
        return [] if pair.nil?

        table = pair[1]
        missing = pair[2]
        return [] unless schema.key?(table)

        edits = []
        model_files(root).each do |path|
          owner = class_name(File.read(path))
          next if owner.nil?

          base = base_class(root, owner)
          next unless "#{underscore(base)}_id" == missing

          wanted = "#{underscore(owner)}_id"
          next unless schema[table].include?(wanted)

          edits.concat(edits_for(root: root, path: path, table: table, base: base, owner: owner,
            wanted: wanted, failure: failure))
        end
        edits
      end

      # **The association that asked, and only if the table is the one it points at.** A file is a
      # candidate when one of its associations resolves to the failing table; the edit is the line
      # that declares it, with the column the schema says exists.
      def self.edits_for(root:, path:, table:, base:, owner:, wanted:, failure:)
        relative = path.delete_prefix("#{root}/")
        File.readlines(path).each_with_index.filter_map do |raw, index|
          text = raw.chomp
          found = ASSOCIATION.match(text)
          next if found.nil?
          next unless target_table?(table, found[3])
          next unless plain?(found[4])

          inverse = inverse_of(root, found[3], owner)
          edited = insert_foreign_key(text, wanted, inverse)
          next if edited == text

          {
            "path" => relative,
            "line" => index + 1,
            "text" => text,
            "after" => edited,
            "automatic" => true,
            "subject" => "association foreign key",
            "origin" => "suite-repair",
            "note" => "Rails 7 derives `#{found[2]} :#{found[3]}`'s key from the base class " \
                      "(`#{underscore(base)}_id`, which `#{table}` does not have); this " \
                      "application's table has `#{wanted}`, so the association names it" \
                      "#{inverse ? ", with `inverse_of: :#{inverse}` so the owner is known " \
                      "before the child validates" : ""} (#{failure.name})"
          }
        end
      end

      # `has_one :poll, autosave: true` gains `, foreign_key: :status_message_id`; a trailing comma
      # on a multi-line options hash is removed first so the line does not read `,,`.
      #
      # **The inverse is part of the same repair, and it is not decoration.** Measured on the same
      # rung: with the key named but no `inverse_of`, `status_message.build_poll` leaves
      # `poll.status_message` nil, so the child's `belongs_to` presence validation fails with `Poll
      # status message must exist` on nine examples that had passed on 6.1 — Rails 7.0 no longer
      # infers the inverse through the STI name. It is written only when the child model really
      # declares that `belongs_to`, because `inverse_of` naming an association that does not exist
      # is an `ArgumentError` at boot rather than a repair.
      def self.insert_foreign_key(text, wanted, inverse = nil)
        line = "#{text.rstrip.sub(/,\s*\z/, "")}, foreign_key: :#{wanted}"
        inverse.nil? ? line : "#{line}, inverse_of: :#{inverse}"
      end

      # The child's name for its owner, when it declares one under the owner's own name.
      def self.inverse_of(root, association, owner)
        child = File.join(root, "app", "models", "#{underscore(association)}.rb")
        return nil unless File.file?(child)

        wanted = underscore(owner)
        names = File.read(child).scan(/belongs_to\s+:(\w+)/).flatten
        names.include?(wanted) ? wanted : nil
      end

      # A declaration whose key is its own already, or whose key is not derived from the owner.
      def self.plain?(options)
        return false if options.nil?

        !options.match?(/\bforeign_key:|\bthrough:|\bas:|\bpolymorphic:|class_name:/)
      end

      # Does this association point at `table`? The association's name pluralised is the table a
      # Rails model would use, and the schema decides which pluralisation is real.
      def self.target_table?(table, association)
        PLURALS.any? { |form| format(form, association) == table }
      end

      # `app/models/status_message.rb` declares `StatusMessage`. A file with no class (a concern, a
      # module) is not an owner of an association.
      def self.class_name(text)
        text[/^class\s+([A-Z]\w*)/, 1]
      end

      # The class an association's key is derived from today: the last ancestor that is itself a
      # model in this application.
      def self.base_class(root, owner)
        seen = owner
        loop do
          superclass = superclass_of(root, seen)
          return seen if superclass.nil?

          seen = superclass
        end
      end

      def self.superclass_of(root, name)
        path = File.join(root, "app", "models", "#{underscore(name)}.rb")
        return nil unless File.file?(path)

        found = File.read(path)[/^class\s+#{Regexp.escape(name)}\s*<\s*([A-Z]\w*)/, 1]
        return nil if found.nil? || found == "ApplicationRecord"

        found
      end

      def self.underscore(name)
        name.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # Every model file, in a stable order.
      def self.model_files(root)
        Dir[File.join(root, "app", "models", "**", "*.rb")].sort
      end

      # **The schema of record, read as the column lists it is.** `db/schema.rb` is the dump a Rails
      # application keeps; `db/structure.sql` is the other spelling, and a tree that keeps neither
      # gets no repair rather than a guess about its tables.
      def self.schema_columns(root)
        ruby = File.join(root, "db", "schema.rb")
        return from_schema_rb(File.read(ruby)) if File.file?(ruby)

        sql = File.join(root, "db", "structure.sql")
        return from_structure_sql(File.read(sql)) if File.file?(sql)

        {}
      end

      def self.from_schema_rb(text)
        tables = {}
        current = nil
        text.each_line do |line|
          if (found = line.match(/\A\s*create_table\s+"(\w+)"/))
            current = found[1]
            tables[current] = []
          elsif current && (found = line.match(/\A\s{4}t\.\w+\s+"(\w+)"/))
            tables[current] << found[1]
          elsif !current.nil? && line.match?(/\A\s{2}end\s*\z/)
            current = nil
          end
        end
        tables
      end

      def self.from_structure_sql(text)
        tables = {}
        current = nil
        text.each_line do |line|
          if (found = line.match(/\ACREATE TABLE (?:public\.)?(\w+) \(/))
            current = found[1]
            tables[current] = []
          elsif !current.nil? && (found = line.match(/\A\s+"?(\w+)"?\s/))
            tables[current] << found[1]
          elsif !current.nil? && line.start_with?(");")
            current = nil
          end
        end
        tables
      end
    end
  end
end
