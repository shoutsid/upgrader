# frozen_string_literal: true

module Agents
  module Upgrader
    # **A spec that identifies a link by a translation the application never defines, once the rung
    # makes that call raise.**
    #
    # Rails 7.1 made `config.i18n.raise_on_missing_translations` apply to every `I18n.t`, not only
    # to the ones a view or a controller translates. Measured on ohana-api's 7.1.6 rung: after the
    # rspec line moved (the `Object#with` and resolver families), 1,554 examples ran with **one**
    # failure, and it was a spec's own call — `not_to have_link I18n.t('admin.navigation.locations'),
    # href: admin_locations_path` — where the application's navigation renders
    # `admin.buttons.locations` and has never had an `admin.navigation.locations` at all. Until 7.1
    # the call answered a `translation missing:` string, so the matcher compared the link's text
    # against a sentence that could not be any link's text and passed for a reason the spec did not
    # mean. The rung is what turned a vacuous assertion into a raised one.
    #
    # **The repair keeps the half of the assertion that identifies something.** The spec already
    # names the link's destination (`href:`), and that is a fact about the page rather than a
    # string the application has to supply; the label is the half that cannot exist. So the edit
    # drops the impossible argument and leaves `have_link href: …`, which is a stronger assertion
    # than the one that was passing — every link to that path, not only one whose text is a
    # string the application never had.
    #
    # What it refuses, and each refusal is a case where the edit would guess:
    #
    # * a failure that is not `I18n::MissingTranslationData` — another red suite must not have its
    #   specs rewritten;
    # * a missing key raised anywhere but in a spec's own file — in a view or a model the string is
    #   the application *saying* something, and dropping it would change what the page is;
    # * a matcher with no `href:` — with neither the text nor a destination there is nothing left
    #   to identify the link, and a `have_link` with no arguments checks only that some link exists;
    # * a key that is not a literal in the call — a computed key is not a fact this repair can read.
    module MissingTranslations
      RAISED = "I18n::MissingTranslationData"

      # `have_link I18n.t('key'), href: …` or `have_link(I18n.t("key"), href: …)`.
      #
      # The call has to be the matcher's first argument, because that is the one Capybara reads as
      # the link's text; a call in another position is an option value and not the same repair. The
      # comma is part of the match so removing the argument cannot leave `have_link , href:` behind,
      # and the parenthesis is captured so a parenthesised matcher stays one.
      LINK = /\bhave_link(?<opening>\s*\(?)\s*I18n\.t\(\s*(?<quote>['"])(?<key>[^'"]+)\k<quote>\s*\)\s*,\s*(?<rest>href:.*)\z/

      def self.for(root:, failures:)
        Array(failures).filter_map do |failure|
          next unless missing_translation?(failure)

          edit(root: root, failure: failure)
        end
      end

      def self.missing_translation?(failure)
        failure.classes.include?(RAISED) && failure.file.to_s.start_with?("spec/")
      end

      def self.edit(root:, failure:)
        return nil if failure.line.nil?

        path = failure.file.to_s
        full = File.join(root, path)
        return nil unless File.file?(full)

        lines = File.readlines(full)
        text = lines[failure.line - 1].to_s.chomp
        found = LINK.match(text)
        return nil if found.nil?

        opening = found[:opening].include?("(") ? "(" : " "
        prefix = text[0...found.begin(0)]

        {
          "path" => path,
          "line" => failure.line,
          "text" => text,
          "after" => "#{prefix}have_link#{opening}#{found[:rest]}",
          "automatic" => true,
          "subject" => "missing translation #{found[:key]}",
          "origin" => "suite-repair",
          "note" => "Rails 7.1 raises on a missing translation wherever `I18n.t` is called, and " \
                    "`#{found[:key]}` is a key this application never defines — the assertion's " \
                    "text could never have been a link's. The link is identified by the `href` " \
                    "the assertion already names, so that is what it keeps"
        }
      end
    end
  end
end
