require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  # --- Étape 8: reversing a rule-triggered allocation when its entry changes ---

  test "destroying an entry reverses any rule allocation it triggered" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 1_000, currency: "USD", accountable: Depository.new)
    pocket = account.pockets.create!(name: "Savings", currency: "USD")
    rule = Rule.create!(family: family, resource_type: "transaction",
                         conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Paycheck") ],
                         actions: [ Rule::Action.new(action_type: "allocate_to_reserve",
                                                      value: { target_type: "pocket", target_id: pocket.id, amount_mode: "fixed", amount_value: "50" }.to_json) ])
    entry = create_transaction(account: account, name: "Paycheck", amount: -1000)
    rule.apply
    assert_equal 50, pocket.reload.allocated_amount

    entry.destroy!

    assert_equal 0, pocket.reload.allocated_amount
    assert_equal 0, RuleAllocation.count
  end

  test "correcting an entry's amount reverses its rule allocation without destroying the entry" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 1_000, currency: "USD", accountable: Depository.new)
    pocket = account.pockets.create!(name: "Savings", currency: "USD")
    rule = Rule.create!(family: family, resource_type: "transaction",
                         conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Paycheck") ],
                         actions: [ Rule::Action.new(action_type: "allocate_to_reserve",
                                                      value: { target_type: "pocket", target_id: pocket.id, amount_mode: "fixed", amount_value: "50" }.to_json) ])
    entry = create_transaction(account: account, name: "Paycheck", amount: -1000)
    rule.apply
    assert_equal 50, pocket.reload.allocated_amount

    entry.update!(amount: -2000)

    assert entry.persisted?
    assert_equal 0, pocket.reload.allocated_amount
    assert_equal 0, RuleAllocation.count

    # The next application picks the corrected entry back up.
    rule.apply
    assert_equal 50, pocket.reload.allocated_amount
  end
end
