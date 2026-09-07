class AddRuleContributionKindToBudgetAdjustments < ActiveRecord::Migration[8.1]
  def change
    # A third BudgetAdjustment kind for Étape 8's rule-triggered contribution
    # (fixed/percent/round-up on a matching transaction) -- deliberately not
    # reused as "opening_balance", which is a one-time backfill: keeping this
    # kind distinct lets a future targeted undo (e.g. "reverse only what this
    # rule ever contributed") find its own rows without touching genuine
    # opening balances. group_id stays required only for reallocation (see
    # BudgetAdjustment's own validations), unaffected by this change.
    remove_check_constraint :budget_adjustments, name: "chk_budget_adjustments_kind_enum"
    add_check_constraint :budget_adjustments, "kind IN ('opening_balance', 'reallocation', 'rule_contribution')",
      name: "chk_budget_adjustments_kind_enum"
  end
end
