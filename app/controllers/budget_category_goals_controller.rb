class BudgetCategoryGoalsController < ApplicationController
  include BudgetOwnership

  before_action :set_budget_category

  def new
    @category = @budget_category.category
    @goal = @category.build_funding_goal(name: @category.name, currency: Current.family.currency,
                                          family: Current.family)
    @selectable_categories = selectable_categories
  end

  def create
    @category = @budget_category.category
    @goal = @category.build_funding_goal(goal_params)
    @goal.family = Current.family
    @goal.currency = Current.family.currency

    categories = submitted_expense_categories
    Goal.transaction do
      categories.each { |c| @goal.goal_expense_categories.build(category: c) }
      @goal.save!
    end

    redirect_to goal_path(@goal), notice: t("budget_categories.goals.create.success")
  rescue ActiveRecord::RecordInvalid
    @selectable_categories = selectable_categories
    render :new, status: :unprocessable_entity
  end

  private
    # Mirrors BudgetCategoriesController#set_budget exactly — same
    # owner/household resolution, same "no budget for that period" 404.
    def set_budget_category
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      budget = resolve_budget(start_date)
      raise ActiveRecord::RecordNotFound unless budget

      @budget_category = budget.budget_categories.find(params[:budget_category_id])
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
