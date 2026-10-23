# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "agents_fyi/upgrader/suite_failures"
require "agents_fyi/upgrader/template_repairs"
require "agents_fyi/upgrader/routes"

# **The two repairs a suite's route failures earn.** The failures come from the 6.0 rung's real
# output (three of its six blocks, copied whole) and the route rows are the application's own (read
# once by hand with `bin/rails runner`); what is synthetic here is the tree, because the rule's
# subject is the *line* rather than the file — every line is the one the application's own template
# has, including the bare `bids_path` that is the collection and not the member route.
class TemplateRepairsTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/rspec_60_biddingapp.txt", __dir__)
  NAV = "          <%=  link_to 'Auction Item', new_category_item_path(@category), " \
        "class: 'btn btn-info', style: 'margin-left: 10px;' %>"

  def setup
    @root = Dir.mktmpdir
    write "app/controllers/bids_controller.rb", <<~RUBY
      class BidsController < ApplicationController
        before_action :set_bid
        before_action :set_item
        before_action :set_category

        private

        def set_category
          @category = Category.find_by_url(params[:category_id])
        end

        def set_item
          @item = Item.find(params[:item_id])
        end

        def set_bid
          @bid = Bid.find(params[:id])
        end
      end
    RUBY
    write "app/views/bids/edit.html.erb",
      "<h1>Editing bid</h1>\n\n<%= render 'form' %>\n\n<%= link_to 'Show', @bid %> |\n" \
      "<%= link_to 'Back', bids_path %>\n"
    write "app/views/bids/show.html.erb",
      "<p id=\"notice\"><%= notice %></p>\n\n<%= link_to 'Edit', edit_bid_path(@bid) %> |\n" \
      "<%= link_to 'Back', bids_path %>\n"
    write "app/views/layouts/_navigation.html.erb", (["x"] * 80 + [NAV]).join("\n") + "\n"
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # Not `failures`: Minitest::Test already owns that name for the assertions that failed.
  def parsed = AgentsFyi::Upgrader::SuiteFailures.parse(File.read(FIXTURE))

  def routes
    [
      row("category_item_bids", "bids", "index", %w[category_id item_id]),
      row("new_category_item_bid", "bids", "new", %w[category_id item_id]),
      row("edit_category_item_bid", "bids", "edit", %w[category_id item_id id]),
      row("category_item_bid", "bids", "show", %w[category_id item_id id]),
      row("categories", "categories", "index", []),
      row("new_category_item", "items", "new", %w[category_id]),
      row("category_items", "items", "index", %w[category_id]),
      row("category_item", "items", "show", %w[category_id id])
    ]
  end

  # A record passed to `link_to` is a polymorphic path, and the record's own route is the nested one
  # the application declares. The controller's variables are the argument list, in the route's order.
  def test_a_link_to_a_record_is_repaired_to_the_nested_route
    edit = repair_for("app/views/bids/edit.html.erb")

    refute_nil edit
    assert_equal 5, edit["line"]
    assert_equal "<%= link_to 'Show', @bid %> |", edit["text"]
    assert_equal "<%= link_to 'Show', category_item_bid_path(@category, @item, @bid) %> |",
      edit["after"]
    assert_equal "suite-repair", edit["origin"]
  end

  # A helper that does not exist is replaced by the one the router declares for that controller and
  # action, with the parts the controller assigns from `params`.
  def test_a_missing_helper_is_repaired_to_the_declared_one
    edit = repair_for("app/views/bids/show.html.erb")

    refute_nil edit
    assert_equal "<%= link_to 'Edit', edit_category_item_bid_path(@category, @item, @bid) %> |",
      edit["after"]
  end

  # **A collection helper and a member helper are different routes, and the declared name is what
  # says which.** `bids_path` is the collection and `bid_path` the member; both dispatch to
  # `BidsController`, so a rule that asked only the controller repaired the collection into the
  # member route — a link that renders and goes to a page with an id in it. The application's router
  # keeps the nested resource's own name as the suffix of the route it becomes, which is the fact
  # that separates them.
  def test_a_bare_helper_is_the_collection_or_the_member_route_the_router_names
    assert_equal "category_item_bids", route_for("bids_path").name
    assert_equal "category_item_bid", route_for("bid_path").name
  end

  # **A bare helper fails as a NameError, not as a NoMethodError.** `link_to 'Back', bids_path` is a
  # call with no receiver, so Ruby answers `undefined local variable or method 'bids_path'` — the
  # spelling the first repair round did not recognise, which left the 6.0 rung's four remaining
  # failures unrepaired and spent the run. The failure is built here rather than copied because
  # the recording is the *first* round's output; this spelling only appears once the line above it
  # has been repaired.
  def test_a_bare_helper_is_recognised_by_the_name_error_ruby_reports
    failure = AgentsFyi::Upgrader::SuiteFailures::Failure.new(
      name: "BidsController GET #edit responds with HTTP 200 status",
      error: "ActionView::Template::Error",
      message: "undefined local variable or method `bids_path' for #<#<Class:0x0>:0x0>",
      frames: [["./app/views/bids/edit.html.erb", 6]]
    )

    edit = AgentsFyi::Upgrader::TemplateRepairs.for(root: @root, failures: [failure],
      routes: routes).first

    refute_nil edit, "the bare helper was not recognised as an undefined route helper"
    assert_equal "<%= link_to 'Back', category_item_bids_path(@category, @item) %>", edit["after"]
  end

  # The same distinction at the line: a bare collection helper is replaced by the declared
  # collection route, with the parents' variables the controller already reads from `params`.
  def test_a_collection_helper_is_repaired_to_the_declared_collection
    after = rewrite("<%= link_to 'Back', bids_path %>", "bids_path")

    assert_equal "<%= link_to 'Back', category_item_bids_path(@category, @item) %>", after
  end

  # The other failure shape: the helper exists and the segment it was given is nil. The line is one
  # ERB output tag, so the tag is what gets the guard.
  def test_a_nil_segment_guards_the_erb_tag_on_the_tagged_variable
    edit = repair_for("app/views/layouts/_navigation.html.erb")

    refute_nil edit
    assert_equal 81, edit["line"]
    assert_equal "          <% if @category %>#{NAV.strip}<% end %>", edit["after"]
  end

  # **A part with no variable is a refusal, not a guess.** The controller is the only thing that
  # says where a route parameter arrives; without it, a repair naming `@category` would be the rule
  # inventing a name that happens to be a convention.
  def test_a_part_the_controller_does_not_assign_is_refused
    write "app/controllers/bids_controller.rb", <<~RUBY
      class BidsController < ApplicationController
        def set_item = @item = Item.find(params[:item_id])
        def set_bid = @bid = Bid.find(params[:id])
      end
    RUBY

    assert_nil repair_for("app/views/bids/edit.html.erb"),
      "a route part the controller never reads from params has no argument to pass"
  end

  private

  def repair_for(file)
    parsed.find { |failure| failure.file == file }.then do |failure|
      AgentsFyi::Upgrader::TemplateRepairs.for(root: @root, failures: [failure], routes: routes).first
    end
  end

  def route_for(helper)
    AgentsFyi::Upgrader::TemplateRepairs.route_for(helper, routes)
  end

  def rewrite(text, helper)
    AgentsFyi::Upgrader::TemplateRepairs.rewrite_helper(root: @root, text: text, helper: helper,
      routes: routes)
  end

  def row(name, controller, action, parts)
    AgentsFyi::Upgrader::Routes::Row.new(name: name, controller: controller, action: action,
      parts: parts)
  end

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
end
