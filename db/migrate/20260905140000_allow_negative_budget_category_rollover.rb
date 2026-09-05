class AllowNegativeBudgetCategoryRollover < ActiveRecord::Migration[7.2]
  def change
    # The calculator now carries a deficit forward instead of flooring it at
    # zero — see Budget::RolloverCalculator#leftover_for and
    # BudgetCategory#percent_of_budget_spent, both updated to treat a
    # negative rolled_over_amount as real data, not an error state.
    remove_check_constraint :budget_categories,
      name: "chk_budget_categories_rolled_over_amount_non_negative"
  end
end
