# Étape 8's idempotency + reversibility anchor for
# Rule::ActionExecutor::AllocateToReserve: ties a rule action's one-time
# effect on a matched transaction (a PocketMovement or a rule_contribution
# BudgetAdjustment -- exactly one of the two) back to the entry that
# triggered it, so a later correction or deletion of that entry can find and
# unwind exactly what it produced.
#
# entry_id is nullable and its FK nullifies on delete (see the migration) --
# same shape as RecurringAllocation's own entry_id, chosen so this row
# survives the entry's deletion long enough for Entry's own before_destroy
# to walk it and reverse the effect, rather than vanishing with the entry the
# way Goal's extra["goal"]["consumed_goal_id"] stamp does.
class RuleAllocation < ApplicationRecord
  include Monetizable

  belongs_to :rule_action, class_name: "Rule::Action"
  belongs_to :entry, optional: true
  belongs_to :pocket_movement, optional: true
  belongs_to :budget_adjustment, optional: true

  monetize :amount

  validates :amount, numericality: { other_than: 0 }
  validates :currency, presence: true
  validate :exactly_one_effect

  # after_destroy, not before: this row's own FK to pocket_movement/
  # budget_adjustment would otherwise block deleting either while this row
  # (still present at before_destroy time) still references it.
  after_destroy :reverse_effect!

  private
    def exactly_one_effect
      return if pocket_movement_id.present? ^ budget_adjustment_id.present?

      errors.add(:base, :exactly_one_effect_required)
    end

    # Centralizes undo so it fires the same way whether triggered by the
    # owning entry's own deletion/correction (Entry's cascade/hook) or by a
    # future explicit "undo this allocation" action -- one place that knows
    # how to unwind either kind of effect.
    def reverse_effect!
      if pocket_movement
        pocket = pocket_movement.pocket
        pocket_movement.destroy!
        pocket.recompute!
      elsif budget_adjustment
        family = budget_adjustment.family
        budget_adjustment.destroy!
        Budget::RolloverCalculator.new(family: family, user: nil).recompute!
      end
    end
end
