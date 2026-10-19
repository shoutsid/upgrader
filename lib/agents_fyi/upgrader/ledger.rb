# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module AgentsFyi
  module Upgrader
    # What this upgrader has already done, so a service restart is not a redo.
    #
    # `plan` gets to forget: it is invoked, it prints, it exits. `serve` does not. It
    # runs for weeks, it is restarted by a deploy or a power cut, and the thing it must
    # never do is spend a cycle re-deriving a step it settled yesterday — or, worse,
    # report a step settled that never ran. So the work list is durable state, and this
    # module is it, keyed on `(repo, commit, from_version, to_version)`: one minor
    # release of one repository at one commit.
    #
    #
    # * **A verdict is stamped with the machine that produced it.** `unverified` is a fact
    # about the interpreter as much as about the repository — an application that cannot be
    # walked on Ruby 3.3 may be walkable on 2.7, which is the whole reason wants one image per
    # interpreter. A stored verdict whose machine no longer matches this one is re-opened
    # rather than trusted, and a record carrying no stamp at all is read as this machine's,
    # because it makes no claim anybody could contradict. * **A refusal and a failure are
    # settled differently.** A `refused` step is a fact about the move — re-deriving it
    # reaches the same refusal, so it is left alone on the first attempt. A `failed` step is
    # retried, because the usual reason is a release that was briefly unavailable or a network
    # that dropped, and giving up on the first one abandons work that would have succeeded.
    # `MAX_ATTEMPTS` bounds the retrying; the ceiling is folded into `settled?` so there is
    # one answer to "will this be tried again" and no call site re-derives it. * **An
    # unreadable file is set aside, never guessed at.** A partially understood ledger either
    # redoes settled work or, far worse, reports it settled, and deleting the file hides the
    # bug that wrote it. So the copy is renamed beside the original and the reason is kept for
    # whoever logs it.
    class Ledger
      # Bumped when the stored shape changes in a way this module cannot read.
      SCHEMA_VERSION = 1

      # How many times a step may be attempted before the ledger treats it as settled
      # whatever happened. Without it, a step that fails for a reason that never
      # changes would be attempted on every cycle for the life of the service, which is
      # the redo this module exists to prevent.
      MAX_ATTEMPTS = 3

      # The four words a step can end in, spelled once. `Verdict` in the coordinator's
      # `record.rb` is the one place they are *chosen*; they are repeated here because
      # the ledger has to recognise a word it wrote in a previous process — a second
      # list of names for one set of facts is how two readers start disagreeing.
      PASSED = "passed"
      UNVERIFIED = "unverified"
      FAILED = "failed"
      REFUSED = "refused"

      # Which verdicts are final on arrival. `failed` is deliberately absent: it is
      # settled by the attempt ceiling instead, which `settled?` folds in. **`unverified` is
      # deliberately absent too, and it is not merely retried — it never counts toward the ceiling
      # either.** It means *nothing was established*: the suite could not run, or there was no suite,
      # which is a fact about the environment rather than about the move (the first real walk's
      # 4.0.0 -> 4.1.0 came out `unverified` on every attempt because a fresh clone cannot boot its
      # suite without `RAILS_SECRET_TOKEN`, and the deployment had not supplied it). So re-deriving it
      # is not the wasted work this ceiling exists to prevent, and a run of it must not spend the
      # move's attempts: three environment failures would otherwise settle a move for ever, which is
      # what happened here — the corpus published "`unverified` rather than passed, so the target stays
      # queued and will be attempted again" while the ledger refused to try. A word this version does
      # not know is treated as not settled, which is the safe direction — the work is redone rather
      # than assumed done.
      SETTLED_VERDICTS = [PASSED, REFUSED].freeze

      Entry = Struct.new(
        :repo, :commit, :from_version, :to_version,
        :verdict, :baseline, :image, :machine, :era, :attempts, :note, :recorded_at,
        keyword_init: true
      )

      # The ledger at `path`, with an unreadable file set aside rather than raising.
      def self.load(path)
        new(path: path).read!
      end

      # The interpreter — and the image, when a container names one — a verdict was
      # produced on. Both halves are load-bearing: the interpreter decides which Rails
      # releases can be installed at all, and the image decides whether a native
      # extension has a compiler. A stamp that named only the interpreter was how a
      # fact about a machine outlived the machine.
      def self.machine
        stamp = "ruby #{RUBY_VERSION}"
        image = ENV["UPGRADER_IMAGE"].to_s.strip
        image.empty? ? stamp : "#{stamp} (#{image})"
      end

      # The stamp this ledger's entries are written with when a caller does not name one.
      # Public because the *step* has to ask the same question before it runs anything: "is
      # what this ledger already holds a verdict from the machine I am about to use", and the
      # ledger is the one place this process's own identity is decided.
      attr_reader :path, :machine

      def initialize(path:, machine: self.class.machine)
        @path = path.to_s
        @machine = machine
        @entries = {}
        @set_aside_reason = nil
      end

      # Why the file on disk was not read, or nil when it was. `read!` performs the
      # move; this only reports it, so a service can log the reason the work it thought
      # was done is about to be redone.
      def set_aside!
        @set_aside_reason
      end

      # Read what is on disk into memory. Called once by `load`; callable again to pick
      # up a file another process replaced, in which case entries already in memory
      # that the file still holds are overwritten by it.
      def read!
        return self unless File.file?(@path)

        payload = parse_file
        return self if payload.nil?

        unless payload.is_a?(Hash) && payload["schema_version"] == SCHEMA_VERSION
          version = payload.is_a?(Hash) ? payload["schema_version"].inspect : "none"
          put_aside!(
            suffix: "unknown-schema-#{version}",
            reason: "the ledger calls itself schema #{version} and this reader understands " \
                    "#{SCHEMA_VERSION}"
          )
          return self
        end

        begin
          Array(payload["entries"]).each { |entry| store(entry) }
        rescue ArgumentError, TypeError => e
          @entries.clear
          put_aside!(suffix: "corrupt", reason: "an entry could not be read (#{e.message})")
        end
        self
      end

      # The four facts that name a piece of work, joined for use as a hash key.
      #
      # Tabs because none of the four can contain one — a URL, a commit id and two
      # version strings — and the four are compared **exactly**: two refs are two
      # pieces of work, and normalising a commit or a path into another would settle a
      # step nobody walked.
      def key(repo:, commit:, from_version:, to_version:)
        [repo.to_s, commit.to_s, from_version.to_s, to_version.to_s].join("\t")
      end

      def find(repo:, commit:, from_version:, to_version:)
        @entries[key(repo: repo, commit: commit, from_version: from_version, to_version: to_version)]
      end

      # Whether this step should be left alone, now or forever. One answer, so the
      # planner asks rather than re-deriving it.
      #
      # `machine` is the stamp the caller *expects* the step to be produced under — the era
      # the interpreter selection would pick first, or this process for a native run. It is
      # a parameter rather than `@machine` because the steps a walk records are not all
      # produced by the process doing the walking: an application walked as Rails 5.0 on
      # Ruby 2.2 and then read by a process on 3.3 has a stamp this ledger's own identity
      # cannot speak for, and comparing the wrong two stamps settles work that would be
      # re-derived (or, worse, re-opens every cycle).
      def settled?(repo:, commit:, from_version:, to_version:, machine: nil)
        entry = find(repo: repo, commit: commit, from_version: from_version, to_version: to_version)
        return false if entry.nil?
        return false unless same_machine?(entry.machine, machine.nil? ? @machine : machine)
        # **Nothing established is not work done**, so an `unverified` move is re-opened whatever the
        # ceiling says — including an entry written by the version that counted these attempts, which
        # is why this is checked rather than left to `SETTLED_VERDICTS` alone.
        return false if entry.verdict.to_s == UNVERIFIED

        SETTLED_VERDICTS.include?(entry.verdict) || entry.attempts.to_i >= MAX_ATTEMPTS
      end

      # **A run that established nothing does not spend one of the move's attempts.** `passed`,
      # `failed` and `refused` all established something about the move — the last two are why the
      # ceiling exists — while `unverified` established that the *environment* could not measure it,
      # which is not evidence that re-deriving the move is wasted. Counting it is what settled the
      # first real walk's first rung for ever.
      def spends_an_attempt?(verdict) = verdict.to_s != UNVERIFIED

      def attempts(repo:, commit:, from_version:, to_version:)
        entry = find(repo: repo, commit: commit, from_version: from_version, to_version: to_version)
        entry.nil? ? 0 : entry.attempts.to_i
      end

      # Write down what happened, and persist it.
      #
      # It persists immediately rather than waiting for a caller to remember: a verdict
      # held in memory until the end of a cycle is a verdict lost by the container that
      # is stopped mid-cycle, and the work it describes is an hour of installing gems.
      # `save!` is still public — it is the one write, and a caller that changed
      # something else can flush it.
      def record(repo:, commit:, from_version:, to_version:, verdict:, baseline: nil, image: nil,
                 machine: nil, era: nil, note: "")
        identifier = key(repo: repo, commit: commit, from_version: from_version, to_version: to_version)
        previous = @entries[identifier]
        entry = Entry.new(
          repo: repo, commit: commit, from_version: from_version, to_version: to_version,
          verdict: verdict.to_s,
          baseline: baseline,
          image: image,
          machine: machine.to_s.empty? ? @machine : machine,
          era: era,
          attempts: (previous.nil? ? 0 : previous.attempts.to_i) + (spends_an_attempt?(verdict) ? 1 : 0),
          note: note.to_s,
          recorded_at: Time.now.utc.iso8601
        )
        @entries[identifier] = entry
        save!
        entry
      end

      def size
        @entries.size
      end

      def entries
        @entries.keys.sort.map { |identifier| @entries[identifier] }
      end

      # Write the ledger so that a crash cannot leave it half-written.
      #
      # To a neighbour and renamed: `File.rename` is atomic within one filesystem, so a
      # reader sees the old ledger or the new one and never a truncated one. The mode is
      # set before the rename rather than after, so the file is never briefly readable
      # by another account. One process owns the file — `serve` is the only writer — so
      # there is no lock here; two writers would want a lock, and would want it at the
      # document level rather than around this method.
      def save!
        FileUtils.mkdir_p(File.dirname(@path))
        temporary = "#{@path}.tmp-#{Process.pid}"
        begin
          File.write(temporary, JSON.pretty_generate(document))
          File.chmod(0o600, temporary)
          File.rename(temporary, @path)
        rescue StandardError
          # A half-written neighbour is litter, and the next save would overwrite it
          # anyway — but a crash is also when somebody is reading the directory.
          File.delete(temporary) if File.exist?(temporary)
          raise
        end
        nil
      end

      private

      def parse_file
        JSON.parse(File.read(@path))
      rescue JSON::ParserError, TypeError, SystemCallError => e
        put_aside!(suffix: "corrupt", reason: "it could not be parsed (#{e.class})")
        nil
      end

      def same_machine?(stamp, expected)
        # No stamp is not a claim: a record from before the stamp existed says nothing
        # about a machine, so there is nothing in it to contradict.
        stamp.to_s.empty? || stamp == expected
      end

      def store(entry)
        raise ArgumentError, "an entry is not an object" unless entry.is_a?(Hash)

        recorded = Entry.new(
          repo: required(entry, "repo"),
          commit: required(entry, "commit"),
          from_version: required(entry, "from_version"),
          to_version: required(entry, "to_version"),
          verdict: required(entry, "verdict"),
          baseline: entry["baseline"],
          image: entry["image"],
          machine: entry["machine"].to_s,
          era: entry["era"].to_s,
          attempts: entry["attempts"].to_i,
          note: entry["note"].to_s,
          recorded_at: entry["recorded_at"].to_s
        )
        @entries[
          key(
            repo: recorded.repo, commit: recorded.commit,
            from_version: recorded.from_version, to_version: recorded.to_version
          )
        ] = recorded
      end

      # The four facts a record cannot be placed without. Missing one is not a field to
      # default: it is an entry this reader cannot attribute, which makes the whole file
      # untrustworthy rather than just that line.
      def required(entry, name)
        value = entry[name]
        raise ArgumentError, "an entry has no #{name}" unless value.is_a?(String) && !value.empty?

        value
      end

      def put_aside!(suffix:, reason:)
        aside = "#{@path}.#{suffix}-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
        # A rename that fails leaves the file where it is, which is the right outcome:
        # the evidence is still there and so is the reason it matters.
        begin
          File.rename(@path, aside)
        rescue SystemCallError
          aside = @path
        end
        @set_aside_reason = "#{reason}; the file was kept as #{aside} and the ledger starts empty"
      end

      def document
        {
          "schema_version" => SCHEMA_VERSION,
          "machine" => @machine,
          # Sorted, so two saves of the same state are the same bytes: a ledger that is
          # backed up and diffed is a ledger whose only changes are real ones.
          "entries" => @entries.keys.sort.map { |identifier| as_json(@entries[identifier]) }
        }
      end

      def as_json(entry)
        {
          "repo" => entry.repo,
          "commit" => entry.commit,
          "from_version" => entry.from_version,
          "to_version" => entry.to_version,
          "verdict" => entry.verdict,
          "baseline" => entry.baseline,
          "image" => entry.image,
          "machine" => entry.machine,
          "era" => entry.era,
          "attempts" => entry.attempts,
          "note" => entry.note,
          "recorded_at" => entry.recorded_at
        }
      end
    end
  end
end
