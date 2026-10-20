# frozen_string_literal: true

require "fileutils"
require "json"

module AgentsFyi
  module Upgrader
    # **The declarations this walker can see, written where the site admin can list them.**
    #
    # The site admin can only read the directory it writes (`UPGRADER_PROJECTS_DIR`); the built-in
    # declarations live in this image and are invisible to it, so its Projects page looked empty even
    # while the walk was running the lighthouse. This feed is the effective catalogue — every
    # declaration `Project.all` sees, with the full fields and where it came from — written beside the
    # progress, delivery and environment feeds. The site admin lists it read-only and, for a built-in,
    # offers "save a copy" into its own directory, which then shadows this one.
    class ProjectsFeed
      FILE = "projects.json"

      def self.path(home) = File.join(Progress.dir(home), FILE)

      def initialize(home:, out: nil, projects: nil)
        @home = home
        @out = out
        @projects = projects
      end

      def path = self.class.path(@home)

      def write
        entries = Array(@projects || Project.all).map do |project|
          {
            "slug" => project.slug.to_s,
            "source" => built_in?(project) ? "built-in" : "site_admin",
            "path" => project.path.to_s,
            "fields" => project.to_h
          }
        end
        write_file(entries)
        entries
      end

      private

      # A project loaded from the image's own directory is built-in; one from the site admin's volume is
      # the operator's copy. The two directories are the only ones `Project.all` reads.
      def built_in?(project)
        path = File.expand_path(project.path.to_s)
        path.start_with?("#{File.expand_path(Project::PROJECTS)}/")
      end

      def write_file(entries)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, JSON.pretty_generate("projects" => entries.sort_by { |entry| entry["slug"] }))
        File.rename(temporary, path)
      rescue SystemCallError => e
        @out&.puts("  projects: not written: #{e.class}: #{e.message}")
      end
    end
  end
end
