class CreateBudgetAdjustments < ActiveRecord::Migration[8.1]
  def change
    # A signed ledger entry against a category's accumulated reserve --
    # money BudgetCategory#budgeted_spending/rolled_over_amount can't
    # represent: an opening balance from savings that predate Sure, or a
    # reallocation of reserve between envelopes (as opposed to
    # BudgetCategory.move_allocation!, which only moves the current
    # month's plan). Scoped by category_id, not budget_category_id --
    # budget_category rows are per-period, but a category's accumulated
    # reserve is a fact that persists across periods, the same way
    # rolled_over_amount conceptually does.
    #
    # Not to be confused with PocketMovement, which journals account-level
    # reservations, not budget adjustments -- deliberately separate tables
    # for deliberately separate kinds of events.
    create_table :budget_adjustments, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: true, foreign_key: true, type: :uuid
      t.references :category, null: false, foreign_key: true, type: :uuid
      t.string :kind, null: false, default: "opening_balance"
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :effective_on, null: false
      # Set only for kind: reallocation, to link its paired debit+credit
      # rows for display/audit. nil for opening_balance.
      t.uuid :group_id
      t.string :note

      t.timestamps
    end

    add_check_constraint :budget_adjustments, "amount <> 0", name: "chk_budget_adjustments_amount_not_zero"
    add_check_constraint :budget_adjustments, "kind IN ('opening_balance', 'reallocation')",
      name: "chk_budget_adjustments_kind_enum"

    # Calculator reads: "every adjustment for this family/user/category up
    # to a given date," ordered by when it takes effect.
    add_index :budget_adjustments, [ :family_id, :user_id, :category_id, :effective_on ],
      name: "index_budget_adjustments_on_scope_and_effective_on"
    add_index :budget_adjustments, :group_id
  end
end
