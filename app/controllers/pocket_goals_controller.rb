class PocketGoalsController < ApplicationController
  before_action :set_pocket
  before_action :redirect_if_goal_exists

  def new
    @goal = @pocket.build_goal(name: @pocket.name, currency: @pocket.currency, family: Current.family)
  end

  def create
    @goal = @pocket.build_goal(goal_params)
    @goal.family = Current.family
    @goal.currency = @pocket.currency
    @goal.save!

    redirect_to goal_path(@goal), notice: t("pockets.goals.create.success")
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  private

    def set_pocket
      @pocket = Pocket.joins(:account).merge(Current.user.accessible_accounts).find(params[:pocket_id])
    end

    # The pocket card hides this route's entry point once a goal exists
    # (app/views/pockets/_pocket.html.erb), but nothing stops a stale page or
    # a direct hit. Without this guard, #new's build_goal on the already-full
    # has_one tries to null out the existing goal's pocket_id and blows up
    # against must_have_exactly_one_funding_source with an unrescued
    # ActiveRecord::RecordNotSaved (500) -- send the user to the goal that's
    # already there instead.
    def redirect_if_goal_exists
      return unless @pocket.goal

      redirect_to goal_path(@pocket.goal), notice: t("pockets.goals.already_exists")
    end

    def goal_params
      params.require(:goal).permit(:name, :target_amount, :target_date, :kind, :target_mode, :target_months)
    end
end
