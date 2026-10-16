class PostsController < ApplicationController
  def index
    @posts = Post.order(:id)
  end

  def show
    @post = Post.find(params[:id])
  end
end
