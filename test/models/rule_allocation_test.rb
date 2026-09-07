require "test_helper"

class RuleAllocationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", balance: 1_000, currency: "USD", accountable: Depository.new)
    @rule = Rule.create!(family: @family, resource_type: "transaction",
                          conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Paycheck") ],
                          actions: [ Rule::Action.new(action_type: "allocate_to_reserve", value: "{}") ])
    @rule_action = @rule.actions.first
    @entry = create_transaction(account: @account, name: "Paycheck", amount: -1000)
  end

  test "requires exactly one effect, never both, never neither" do
    pocket = @account.pockets.create!(name: "Trip", currency: "USD")
    movement = pocket.movements.create!(amount: 10)
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    adjustment = BudgetAdjustment.record_rule_contribution!(category: category, amount: 10, family: @family, currency: "USD")

    neither = RuleAllocation.new(rule_action: @rule_action, entry: @entry, amount: 10, currency: "USD")
    assert_not neither.valid?
    assert neither.errors.of_kind?(:base, :exactly_one_effect_required)

    both = RuleAllocation.new(rule_action: @rule_action, entry: @entry, amount: 10, currency: "USD",
                               pocket_movement: movement, budget_adjustment: adjustment)
    assert_not both.valid?
    assert both.errors.of_kind?(:base, :exactly_one_effect_required)
  end

  test "destroying a pocket-targeted allocation destroys its movement and recomputes the pocket" do
    pocket = @account.pockets.create!(name: "Trip", currency: "USD")
    pocket.add_money!(50)
    movement = pocket.movements.order(:created_at).last
    allocation = RuleAllocation.create!(rule_action: @rule_action, entry: @entry, amount: 50, currency: "USD",
                                         pocket_movement: movement)

    allocation.destroy!

    assert_not PocketMovement.exists?(movement.id)
    assert_equal 0, pocket.reload.allocated_amount
  end

  test "destroying a budget-category-targeted allocation destroys its adjustment and recomputes the rollover chain" do
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: nil)
    budget.update!(budgeted_spending: 1_000, expected_income: 2_000)
    adjustment = BudgetAdjustment.record_rule_contribution!(category: category, amount: 75, family: @family, currency: "USD")
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!
    budget_category = budget.budget_categories.find_by!(category: category)
    assert_equal 75, budget_category.reload.adjustments_balance

    allocation = RuleAllocation.create!(rule_action: @rule_action, entry: @entry, amount: 75, currency: "USD",
                                         budget_adjustment: adjustment)

    allocation.destroy!

    assert_not BudgetAdjustment.exists?(adjustment.id)
    assert_equal 0, budget_category.reload.adjustments_balance
  end
end
