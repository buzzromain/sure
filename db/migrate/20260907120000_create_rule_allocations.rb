class CreateRuleAllocations < ActiveRecord::Migration[8.1]
  def change
    # Étape 8's idempotency + reversibility anchor for
    # Rule::ActionExecutor::AllocateToReserve: ties a rule action's one-time
    # effect on a matched transaction (a PocketMovement or a
    # rule_contribution BudgetAdjustment -- exactly one of the two) back to
    # the entry that triggered it. Modeled directly on RecurringAllocation's
    # entry_id/on_delete: :nullify shape: the row survives the entry's
    # deletion rather than vanishing with it (unlike Goal's
    # extra["goal"]["consumed_goal_id"] stamp, which leaves nothing behind
    # to find and reverse), so RuleAllocation#before_destroy can always
    # locate and unwind the effect it produced.
    create_table :rule_allocations, id: :uuid do |t|
      t.references :rule_action, null: false, foreign_key: true, type: :uuid
      t.references :entry, null: true, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :pocket_movement, null: true, foreign_key: true, type: :uuid
      t.references :budget_adjustment, null: true, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false

      t.timestamps
    end

    add_check_constraint :rule_allocations, "amount <> 0", name: "chk_rule_allocations_amount_not_zero"
    # Exactly one of the two effects, never both, never neither.
    add_check_constraint :rule_allocations,
      "(pocket_movement_id IS NOT NULL AND budget_adjustment_id IS NULL) OR " \
      "(pocket_movement_id IS NULL AND budget_adjustment_id IS NOT NULL)",
      name: "chk_rule_allocations_exactly_one_effect"

    # Database-enforced idempotency: a second attempt to allocate the same
    # entry for the same rule action collides here rather than relying on an
    # application-level read-then-write check (see
    # idx_recurring_allocations_entry_once, the same pattern one table over).
    add_index :rule_allocations, [ :rule_action_id, :entry_id ], unique: true,
      where: "entry_id IS NOT NULL", name: "idx_rule_allocations_entry_once"
  end
end
