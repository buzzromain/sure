class AddContributionAppliedAtAndCompleteToMode < ActiveRecord::Migration[8.1]
  def change
    # Only complete_to ever uses this: fixed/manual apply synchronously (the
    # controller or sync_budget_categories sets budgeted_spending directly),
    # complete_to needs a guarded once-per-period application inside
    # Budget::RolloverCalculator, whose write path runs across many recompute
    # calls that must not re-touch a period once it's been decided.
    add_column :budget_categories, :contribution_applied_at, :datetime

    remove_check_constraint :budget_categories, name: "chk_budget_categories_contribution_mode_enum"
    add_check_constraint :budget_categories, "contribution_mode IN ('manual', 'fixed', 'complete_to')",
      name: "chk_budget_categories_contribution_mode_enum"
  end
end
