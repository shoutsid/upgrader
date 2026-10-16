require "test_helper"

class PostsControllerTest < ActionDispatch::IntegrationTest
  test "the index lists what is there" do
    Post.create!(title: "first")

    get posts_url

    assert_response :success
    assert_select "h1", "Posts"
    assert_select "li", "first"
  end

  test "a post has its own page" do
    post = Post.create!(title: "second")

    get post_url(post)

    assert_response :success
    assert_select "h1", "second"
  end
end
