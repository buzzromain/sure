# Étape 8's allocation-rule action: on each matching transaction, reserves a
# fixed amount, a percentage, or a round-up into a Pocket, or contributes the
# same into a budget envelope (a rule_contribution BudgetAdjustment) --
# never a real Transaction/Entry, so the family's actual income/expense
# totals are never touched (a "percentage of salary" rule can never turn
# part of that salary into an artificial expense; it just never creates a
# transaction at all).
#
# `value` carries more than one parameter, unlike every other executor here,
# so it's a JSON-encoded string rather than a single id -- no new column on
# rule_actions for what is, so far, the one action type that needs this
# shape. Configuration UI is a separate follow-up; this executor is the
# mechanism it will eventually drive.
class Rule::ActionExecutor::AllocateToReserve < Rule::ActionExecutor
  AMOUNT_MODES = %w[fixed percent round_up].freeze
  TARGET_TYPES = %w[pocket budget_category].freeze

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    config = parse_config(value)
    return 0 unless config

    target = resolve_target(config)
    return 0 unless target

    # no_duplicate_actions caps a rule at one action per action_type, so this
    # is the one action row this execution run belongs to -- execute() isn't
    # handed the Rule::Action itself, only its value, so this is how
    # RuleAllocation gets the rule_action_id it needs.
    action = rule.actions.find_by(action_type: key)
    return 0 unless action

    budget_target_touched = false

    modified = count_modified_resources(transaction_scope.with_entry) do |txn|
      next false if txn.pending? || txn.transfer?

      amount = compute_amount(txn.entry.amount, config)
      next false unless amount&.positive?

      allocated = allocate!(action: action, entry: txn.entry, target: target, target_type: config["target_type"], amount: amount)
      budget_target_touched ||= allocated.present? && config["target_type"] == "budget_category"
      allocated.present?
    end

    # adjustments_balance is calculator-derived, same as
    # BudgetCategoriesController#record_opening_balance's own callers --
    # one recompute for the whole run, not one per matched transaction.
    Budget::RolloverCalculator.new(family: family, user: nil).recompute! if budget_target_touched

    modified
  end

  private
    def parse_config(value)
      return nil if value.blank?

      config = JSON.parse(value)
      return nil unless AMOUNT_MODES.include?(config["amount_mode"]) && TARGET_TYPES.include?(config["target_type"])
      return nil unless config["amount_value"].present? && config["amount_value"].to_d.positive?

      config
    rescue JSON::ParserError
      nil
    end

    def resolve_target(config)
      if config["target_type"] == "pocket"
        family.pockets.find_by(id: config["target_id"])
      else
        family.categories.find_by(id: config["target_id"])
      end
    end

    def compute_amount(entry_amount, config)
      base = entry_amount.abs.to_d
      amount_value = config["amount_value"].to_d

      case config["amount_mode"]
      when "fixed"
        amount_value
      when "percent"
        (base * amount_value / 100).round(2)
      when "round_up"
        remainder = base % amount_value
        remainder.zero? ? nil : (amount_value - remainder)
      end
    end

    # One DB transaction: the PocketMovement/BudgetAdjustment and the
    # RuleAllocation that anchors it either land together or not at all. A
    # concurrent second attempt at the same (rule_action, entry) pair -- the
    # same rule re-applied before this one committed -- collides on
    # idx_rule_allocations_entry_once and rolls back harmlessly.
    def allocate!(action:, entry:, target:, target_type:, amount:)
      ActiveRecord::Base.transaction do
        pocket_movement = nil
        budget_adjustment = nil

        if target_type == "pocket"
          note = "rule:#{action.id}:#{entry.id}"
          target.add_money!(amount, note: note)
          pocket_movement = target.movements.find_by!(note: note)
        else
          budget_adjustment = BudgetAdjustment.record_rule_contribution!(
            category: target, amount: amount, family: family, currency: entry.currency
          )
        end

        RuleAllocation.create!(
          rule_action: action, entry: entry, amount: amount, currency: entry.currency,
          pocket_movement: pocket_movement, budget_adjustment: budget_adjustment
        )
      end
    # RecordNotUnique: a concurrent application of the same rule already
    # allocated this exact entry -- expected, not an error. MovementRefused/
    # RecordInvalid: this one transaction's allocation can't go through (e.g.
    # the pocket's account doesn't have room) -- skip it, not the entire
    # remaining batch, which is what letting it raise through
    # count_modified_resources' each-based loop would do.
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid, Pocket::MovementRefused
      nil
    end
end
