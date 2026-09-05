class AddContributionToBudgetCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :budget_categories, :contribution_mode, :string, null: false, default: "manual"
    add_column :budget_categories, :contribution_amount, :decimal, precision: 19, scale: 4

    add_check_constraint :budget_categories, "contribution_mode IN ('manual', 'fixed')",
      name: "chk_budget_categories_contribution_mode_enum"
  end
end
