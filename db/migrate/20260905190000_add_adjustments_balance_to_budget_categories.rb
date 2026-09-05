class AddAdjustmentsBalanceToBudgetCategories < ActiveRecord::Migration[8.1]
  def change
    # Calculator-maintained running total of BudgetAdjustment amounts
    # effective through this period, for this row's category. Kept in a
    # separate column from rolled_over_amount on purpose: leftover_for
    # (rolled_over_amount's outgoing calculation) is skipped entirely when
    # rollover_enabled? is false, and an opening balance must not vanish
    # just because ordinary rollover is switched off. See
    # Budget::RolloverCalculator#recompute_chain!.
    add_column :budget_categories, :adjustments_balance, :decimal, precision: 19, scale: 4, null: false, default: 0
  end
end
