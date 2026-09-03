require "test_helper"

# A maintained reserve's earmark, moved by real transactions in either
# direction — the counterpart to goal_consumption_history_test.rb's
# consume!/release_consumption!, which only ever draws a one-off goal down.
class GoalReserveAdjustmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a spend on the account draws the earmark down" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = spend(account, 300, 1.day.ago)

    reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)

    assert_equal 1_700, reserve.reload.goal_accounts.first.allocated_amount
    assert_equal 0, reserve.consumed_amount, "a reserve is drawn down and refilled, never spent"
  end

  test "a deposit on the account tops the earmark up" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = deposit(account, 300, 1.day.ago)

    reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)

    assert_equal 2_300, reserve.reload.goal_accounts.first.allocated_amount
  end

  test "drawing down more than the earmark holds is refused" do
    reserve, account = reserve_with_earmark(earmark: 200, balance: 5_000)
    entry = spend(account, 300, 1.day.ago)

    error = assert_raises(Goal::ConsumptionRefused) do
      reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)
    end
    assert_equal :exceeds_earmark, error.reason
  end

  test "topping up past what the account actually holds is refused" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 2_500)
    entry = deposit(account, 1_000, 1.day.ago)

    error = assert_raises(Goal::ConsumptionRefused) do
      reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)
    end
    assert_equal :exceeds_account_balance, error.reason
  end

  test "topping up is capped by what other goals have already earmarked on the same account" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared", currency: "USD", balance: 2_500)
    reserve = @family.goals.create!(name: "Reserve", target_amount: 5_000, currency: "USD", kind: "maintained") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end
    @family.goals.create!(name: "Other", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end
    entry = deposit(account, 600, 1.day.ago)

    error = assert_raises(Goal::ConsumptionRefused) do
      reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)
    end
    assert_equal :exceeds_account_balance, error.reason
  end

  test "a one-off goal refuses adjust_reserve!" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Trip Pot", currency: "USD", balance: 5_000)
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    error = assert_raises(Goal::ConsumptionRefused) { goal.adjust_reserve!(-100, account: account) }
    assert_equal :not_maintained, error.reason
  end

  test "a whole-account link has no earmark to move" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Whole Pot", currency: "USD", balance: 5_000)
    reserve = @family.goals.create!(name: "Reserve", target_amount: 5_000, currency: "USD", kind: "maintained") do |g|
      g.goal_accounts.build(account: account) # no allocated_amount: whole-account link
    end

    error = assert_raises(Goal::ConsumptionRefused) { reserve.adjust_reserve!(-100, account: account) }
    assert_equal :no_earmark, error.reason
  end

  test "releasing a draw-down restores the earmark" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)

    reserve.release_reserve_adjustment!(entry.entryable)

    assert_equal 2_000, reserve.reload.goal_accounts.first.allocated_amount
  end

  test "releasing a top-up removes it again" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = deposit(account, 300, 1.day.ago)
    reserve.adjust_reserve!(-entry.amount, account: account, transaction: entry.entryable)

    reserve.release_reserve_adjustment!(entry.entryable)

    assert_equal 2_000, reserve.reload.goal_accounts.first.allocated_amount
  end

  test "releasing a transaction this reserve never claimed is refused" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = spend(account, 300, 1.day.ago)

    assert_raises(Goal::ConsumptionRefused) { reserve.release_reserve_adjustment!(entry.entryable) }
  end

  # --- via the tag callback, end to end ---

  test "tagging a spend draws the reserve down; untagging restores it" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = spend(account, 300, 1.day.ago)

    entry.entryable.tags << reserve.tag
    assert_equal 1_700, reserve.reload.goal_accounts.first.allocated_amount

    entry.entryable.tags.delete(reserve.tag)
    assert_equal 2_000, reserve.reload.goal_accounts.first.allocated_amount
  end

  test "tagging a deposit tops the reserve up; untagging removes it" do
    reserve, account = reserve_with_earmark(earmark: 2_000, balance: 5_000)
    entry = deposit(account, 300, 1.day.ago)

    entry.entryable.tags << reserve.tag
    assert_equal 2_300, reserve.reload.goal_accounts.first.allocated_amount

    entry.entryable.tags.delete(reserve.tag)
    assert_equal 2_000, reserve.reload.goal_accounts.first.allocated_amount
  end

  test "tagging on a whole-account reserve silently does nothing" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Whole Pot", currency: "USD", balance: 5_000)
    reserve = @family.goals.create!(name: "Reserve", target_amount: 5_000, currency: "USD", kind: "maintained") do |g|
      g.goal_accounts.build(account: account)
    end
    entry = spend(account, 300, 1.day.ago)

    entry.entryable.tags << reserve.tag

    assert_nil entry.entryable.reload.extra&.dig("goal", "consumed_goal_id")
  end

  private
    def reserve_with_earmark(earmark:, balance:)
      account = Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
      reserve = @family.goals.create!(
        name: "Reserve #{SecureRandom.hex(4)}", target_amount: earmark + 3_000, currency: "USD", kind: "maintained"
      ) { |g| g.goal_accounts.build(account: account, allocated_amount: earmark) }
      [ reserve, account ]
    end

    def spend(account, amount, date)
      account.entries.create!(
        name: "Spend #{SecureRandom.hex(3)}", date: date, amount: amount,
        currency: account.currency, entryable: Transaction.new
      )
    end

    def deposit(account, amount, date)
      account.entries.create!(
        name: "Deposit #{SecureRandom.hex(3)}", date: date, amount: -amount,
        currency: account.currency, entryable: Transaction.new
      )
    end
end
