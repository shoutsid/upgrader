require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "a post needs a title" do
    assert_not Post.new.valid?
    assert Post.new(title: "hello").valid?
  end
end
