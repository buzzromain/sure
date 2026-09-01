class PocketGoalsController < ApplicationController
  before_action :set_pocket

  def new
    @goal = @pocket.build_goal(name: @pocket.name, currency: @pocket.currency, family: Current.family)
    @selectable_categories = selectable_categories
  end

  def create
    @goal = @pocket.build_goal(goal_params)
    @goal.family = Current.family
    @goal.currency = @pocket.currency

    categories = submitted_expense_categories
    Goal.transaction do
      categories.each { |c| @goal.goal_expense_categories.build(category: c) }
      @goal.save!
    end

    redirect_to goal_path(@goal), notice: t("pockets.goals.create.success")
  rescue ActiveRecord::RecordInvalid
    @selectable_categories = selectable_categories
    render :new, status: :unprocessable_entity
  end

  private

    def set_pocket
      @pocket = Pocket.joins(:account).merge(Current.user.accessible_accounts).find(params[:pocket_id])
    end

    def goal_params
      params.require(:goal).permit(:name, :target_amount, :target_date, :kind, :target_mode, :target_months,
                                    :include_uncategorized_expenses)
    end

    def selectable_categories
      Current.family.categories.includes(:subcategories).roots.alphabetically.flat_map do |root|
        [ root ] + root.subcategories.sort_by(&:name)
      end
    end

    def submitted_expense_categories
      ids = Array(params.dig(:goal, :expense_category_ids)).reject(&:blank?)
      return [] if ids.empty?

      Current.family.categories.where(id: ids).to_a
    end
end
