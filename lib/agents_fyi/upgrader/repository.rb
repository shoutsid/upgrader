# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **One repository reference, one meaning.**
    #
    # A declaration may name an application as `owner/name` — what a person types, and what the
    # lighthouse declares — or as the git URL a clone needs; the service's queue carries URLs
    # normalized by its own identity rule; and a ledger key must not depend on which of those a
    # command happened to use. This module is the one place that decides what a reference is, so
    # `plan`, `step`, `serve` and a declaration cannot disagree about which repository they mean.
    #
    # The spellings are deliberate. A path is only a path when it *says* so (`/`, `./`, `../`, `~`),
    # because a bare `storefront` is ambiguous and a person's shorthand must not become a directory
    # of the walker's working directory. A bare `owner/name` is GitHub's clone URL; anything else is
    # returned as written, and `Source` says why it cannot use it.
    module Repository
      GITHUB = "https://github.com/%s.git"

      # The clone URL for a reference, or the reference itself when it already names one.
      def self.normalize(reference)
        text = reference.to_s.strip
        return text if text.empty? || path?(text)
        return canonical_url(text) if url?(text)

        shorthand?(text) ? format(GITHUB, text) : text
      end

      # **A GitHub URL gets its `.git` suffix, because the queue and a declaration must be the same
      # identity.** The service's `identity` strips `.git` from a target's `repo_url`; a declaration
      # expands `owner/name` to the `.git` form; and the ledger and the kept tree are keyed on the
      # reference string the step was handed. Leaving `https://github.com/o/n` and
      # `https://github.com/o/n.git` as two references made a queue row clone the baseline again
      # while the ledger held that repository's twelve settled moves under the other spelling.
      #
      # A non-GitHub remote is left exactly as written: a mirror may not accept the suffix, and the
      # service's own identity rule does not rewrite it either.
      def self.canonical_url(text)
        return text unless github?(text)

        trimmed = text.chomp("/")
        trimmed.end_with?(".git") ? trimmed : "#{trimmed}.git"
      end

      # A spec and its optional ref: `owner/name@v1`, `./app@main`, `git@…`. Split before deciding,
      # because a path may carry an `@` of its own, and an ssh URL has one before the path.
      def self.split(spec)
        text = spec.to_s
        return [text, nil] if text.start_with?("git@")

        repository, ref = text.split("@", 2)
        [normalize(repository), ref]
      end

      def self.path?(reference) = reference.to_s.start_with?("/", "./", "../", "~")

      def self.url?(reference)
        text = reference.to_s
        text.include?("://") || text.start_with?("git@") || text.end_with?(".git")
      end

      def self.shorthand?(reference) = reference.to_s.match?(%r{\A[\w.-]+/[\w.-]+\z})

      def self.github?(reference) = reference.to_s.match?(%r{\A(https://|http://|git://|git@)github\.com[:/]})

      # The identity two spellings of one repository share: a URL without its suffix or case. A path
      # keeps its case, because on the machine it names two paths that differ in case are two paths.
      def self.name(reference)
        normalized = normalize(reference)
        return normalized if path?(normalized)

        normalized.chomp("/").delete_suffix(".git").downcase
      end
    end
  end
end
