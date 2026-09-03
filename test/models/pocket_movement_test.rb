require "test_helper"

# The explicit "add/withdraw" gesture on a pocket, the counterpart to
# tag-fill: a deliberate move of money, not tied to any transaction.
class PocketMovementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "add_money! increases the balance and records a movement" do
    pocket = pocket_with_balance(allocated: 500, account_balance: 5_000)

    pocket.add_money!(100, note: "top-up")

    assert_equal 600, pocket.reload.allocated_amount
    movement = pocket.movements.order(:created_at).last
    assert_equal 100, movement.amount
    assert_equal "top-up", movement.note
  end

  test "withdraw_money! decreases the balance and records a negative movement" do
    pocket = pocket_with_balance(allocated: 500, account_balance: 5_000)

    pocket.withdraw_money!(200)

    assert_equal 300, pocket.reload.allocated_amount
    assert_equal(-200, pocket.movements.order(:created_at).last.amount)
  end

  test "withdrawing more than the pocket holds is refused" do
    pocket = pocket_with_balance(allocated: 500, account_balance: 5_000)

    error = assert_raises(Pocket::MovementRefused) { pocket.withdraw_money!(600) }

    assert_equal :exceeds_balance, error.reason
    assert_equal 500, pocket.reload.allocated_amount
  end

  test "adding past what the account has free is refused" do
    pocket = pocket_with_balance(allocated: 500, account_balance: 1_000)

    error = assert_raises(Pocket::MovementRefused) { pocket.add_money!(600) }

    assert_equal :exceeds_account_balance, error.reason
    assert_equal 500, pocket.reload.allocated_amount
  end

  test "adding is capped by what sibling pockets already hold on the same account" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared", currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Groceries", allocated_amount: 200, currency: "USD")
    account.pockets.create!(name: "Other", allocated_amount: 700, currency: "USD")

    error = assert_raises(Pocket::MovementRefused) { pocket.add_money!(200) }

    assert_equal :exceeds_account_balance, error.reason
  end

  test "a zero or negative amount is refused either direction" do
    pocket = pocket_with_balance(allocated: 500, account_balance: 5_000)

    assert_raises(Pocket::MovementRefused) { pocket.add_money!(0) }
    assert_raises(Pocket::MovementRefused) { pocket.withdraw_money!(-10) }
  end

  test "manual movements and tag-fill add up rather than one overwriting the other" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared", currency: "USD", balance: 5_000)
    pocket = account.pockets.create!(name: "Groceries", allocated_amount: 0, currency: "USD",
                                      link_new_tag: true, fill_direction: "outflows")

    pocket.add_money!(100)
    assert_equal 100, pocket.reload.allocated_amount

    entry = account.entries.create!(name: "Groceries run", date: Date.current, amount: 40,
                                     currency: "USD", entryable: Transaction.new)
    entry.entryable.tags << pocket.tag

    assert_equal 140, pocket.reload.allocated_amount

    pocket.withdraw_money!(20)
    assert_equal 120, pocket.reload.allocated_amount

    entry.entryable.tags.delete(pocket.tag)
    assert_equal 80, pocket.reload.allocated_amount, "removing the tag should only undo the tag's own contribution"
  end

  private
    def pocket_with_balance(allocated:, account_balance:)
      account = Account.create!(family: @family, accountable: Depository.new, name: "Pot #{SecureRandom.hex(4)}",
                                 currency: "USD", balance: account_balance)
      account.pockets.create!(name: "Pocket #{SecureRandom.hex(4)}", allocated_amount: allocated, currency: "USD")
    end
end
