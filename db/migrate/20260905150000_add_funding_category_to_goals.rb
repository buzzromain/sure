class AddFundingCategoryToGoals < ActiveRecord::Migration[8.1]
  def change
    # Points at the Category itself, never at a BudgetCategory row: a
    # BudgetCategory belongs to one specific month's Budget and its identity
    # changes every period, so a stable reference has to sit one level up.
    add_reference :goals, :funding_category, type: :uuid, foreign_key: { to_table: :categories }, null: true
  end
end
