require "test_helper"

class Rule::ActionExecutor::AllocateToReserveTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", balance: 5_000, currency: "USD", accountable: Depository.new)
    @pocket = @account.pockets.create!(name: "Savings", currency: "USD")
  end

  def build_rule(config)
    Rule.create!(
      family: @family,
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Paycheck") ],
      actions: [ Rule::Action.new(action_type: "allocate_to_reserve", value: config.to_json) ]
    )
  end

  test "fixed amount reserves a flat sum into the pocket, without creating a real transaction" do
    entry = create_transaction(account: @account, name: "Paycheck", amount: -1000)
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "fixed", amount_value: "50")

    assert_no_difference "Transaction.count" do
      rule.apply
    end

    assert_equal 50, @pocket.reload.allocated_amount
    allocation = RuleAllocation.find_by!(rule_action: rule.actions.first, entry: entry)
    assert_equal 50, allocation.amount
    assert_not_nil allocation.pocket_movement
  end

  test "percent mode reserves a percentage of the matched entry's amount" do
    create_transaction(account: @account, name: "Paycheck", amount: -1000)
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "percent", amount_value: "10")

    rule.apply

    assert_equal 100, @pocket.reload.allocated_amount
  end

  test "round_up mode reserves the difference to the next increment" do
    create_transaction(account: @account, name: "Paycheck", amount: -104)
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "round_up", amount_value: "5")

    rule.apply

    assert_equal 1, @pocket.reload.allocated_amount
  end

  test "budget_category target creates a rule_contribution adjustment and recomputes the rollover chain once" do
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: nil)
    budget.update!(budgeted_spending: 1_000, expected_income: 2_000)
    create_transaction(account: @account, name: "Paycheck", amount: -1000)
    rule = build_rule(target_type: "budget_category", target_id: category.id, amount_mode: "fixed", amount_value: "40")

    Budget::RolloverCalculator.any_instance.expects(:recompute!).once

    rule.apply

    adjustment = BudgetAdjustment.find_by!(category: category, kind: "rule_contribution")
    assert_equal 40, adjustment.amount
  end

  test "applying the same rule twice does not double-allocate" do
    create_transaction(account: @account, name: "Paycheck", amount: -1000)
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "fixed", amount_value: "50")

    rule.apply
    rule.apply

    assert_equal 50, @pocket.reload.allocated_amount
    assert_equal 1, RuleAllocation.where(rule_action: rule.actions.first).count
  end

  test "a pending transaction is never allocated" do
    entry = create_transaction(account: @account, name: "Paycheck", amount: -1000)
    entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "fixed", amount_value: "50")

    rule.apply

    assert_equal 0, @pocket.reload.allocated_amount
    assert_equal 0, RuleAllocation.count
  end

  test "a transfer leg is never allocated" do
    create_transaction(account: @account, name: "Paycheck", amount: -1000, kind: "funds_movement")
    rule = build_rule(target_type: "pocket", target_id: @pocket.id, amount_mode: "fixed", amount_value: "50")

    rule.apply

    assert_equal 0, @pocket.reload.allocated_amount
    assert_equal 0, RuleAllocation.count
  end

  test "a target deleted before the rule runs is skipped silently, not raised" do
    create_transaction(account: @account, name: "Paycheck", amount: -1000)
    rule = build_rule(target_type: "pocket", target_id: SecureRandom.uuid, amount_mode: "fixed", amount_value: "50")

    assert_nothing_raised { rule.apply }

    assert_equal 0, RuleAllocation.count
  end
end
