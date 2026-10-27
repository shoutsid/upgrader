# frozen_string_literal: true

module Agents
  module Upgrader
    # **A serialized column whose stored class the release will no longer load.**
    #
    # Rails 5.2.8.1 backported the fix for CVE-2022-32224: `serialize` columns are read through
    # `Psych.safe_load`, and the classes it may revive are the release's
    # `ActiveRecord::Base.yaml_column_permitted_classes`, which defaults to an empty list. An
    # application that stores a strong parameter's `ActionController::Parameters` — or any other
    # non-primitive — therefore raises `Psych::DisallowedClass` on a read that worked on 5.2.6.
    # The failure is in the application's data, not in its code: the release changed the reader, and
    # the release also names the setting that lets the application say what its own columns hold.
    #
    # **The fix is the application's own configuration line**, because the list is per application
    # and a global `Psych.unsafe_load` would disable the protection for every column. The edit goes
    # in `config/application.rb` before the first component initializer runs, so it is in force when
    # the first row is read. It is offered only when the failure names the class and the file is a
    # Rails application's — the two facts this family is built from — and it is written through
    # `Applier`, which compares the class line before replacing it, exactly as the route repairs do.
    #
    # The class names are collected across the suite rather than taken from the first block: one
    # column can name one class per example, and a line that permitted only the first would leave
    # the suite red for a reason the record already contained.
    module YamlColumns
      # `Psych::DisallowedClass: Tried to load unspecified class: ActiveSupport::HashWithIndifferentAccess`.
      # The class is a constant path, not a token, so it is captured whole and its spelling is kept.
      UNSPECIFIED = /Tried to load unspecified class:\s*(?<class_name>[A-Z]\w*(?:::[A-Z]\w*)*)/

      # The application class line. It is the anchor because every Rails application has it and a
      # line above or below it is a line this module does not have to guess at.
      APPLICATION = /\A(?<indent>[ \t]*)class Application < Rails::Application\b/

      # The setting already written by hand. A second line would be a duplicate, and a line this
      # module cannot merge into is a person's answer rather than a rewrite.
      SETTING = /\byaml_column_permitted_classes\s*=/

      def self.for(root:, failures:)
        classes = Array(failures).flat_map { |failure| disallowed_classes(failure) }.uniq
        return [] if classes.empty?

        edit(root: root, classes: classes)
      end

      # One edit, or an empty list when the application does not need it or this module cannot make
      # it safely. An empty list is deliberate: the caller then asks the next family or files the
      # failure, rather than writing a second setting over a person's.
      def self.edit(root:, classes:)
        path = "config/application.rb"
        full = File.join(root, path)
        return [] unless File.file?(full)

        lines = File.readlines(full)
        index = lines.index { |line| line.match?(APPLICATION) }
        return [] if index.nil?

        return [] if lines.any? { |line| line.match?(SETTING) }

        text = lines[index].chomp
        indent = APPLICATION.match(text)[:indent]
        classes = Array(classes).uniq.sort
        after = "#{text}\n#{indent}  config.active_record.yaml_column_permitted_classes = " \
                "[#{classes.join(", ")}]"
        [{
          "path" => path,
          "line" => index + 1,
          "text" => text,
          "after" => after,
          "automatic" => true,
          "subject" => "serialized YAML column",
          "origin" => "suite-repair",
          "note" => "The release reads serialized columns through Psych.safe_load, and this " \
                    "application's own column stores #{classes.join(", ")}; the release's " \
                    "permitted-classes setting is how an application says what its columns hold"
        }]
      end

      # Every class a failure names, across both the wrapper and its cause. A failure with no
      # `Psych::DisallowedClass` evidence is not this family's and contributes nothing.
      def self.disallowed_classes(failure)
        return [] unless failure.respond_to?(:messages) && failure.respond_to?(:classes)
        return [] unless failure.classes.include?("Psych::DisallowedClass")

        failure.messages.filter_map { |message| UNSPECIFIED.match(message)&.[](:class_name) }.uniq
      end
    end
  end
end
