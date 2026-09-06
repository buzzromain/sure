require "test_helper"

# What actually triggers Budget::RolloverCalculator to recompute after a
# transaction retroactively changes -- see RecomputeBudgetRolloverJob for the
# debounce mechanics this schedules into.
class BudgetRolloverRecomputeHookTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "changing a transaction's category schedules a recompute" do
    entry = create_transaction(account: @account, category: categories(:food_and_drink))
    other_category = @family.categories.create!(name: "Recompute test", color: "#6172F3")

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.entryable.update!(category: other_category)
    end
  end

  test "changing a transaction's kind schedules a recompute" do
    entry = create_transaction(account: @account)

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.entryable.update!(kind: "one_time")
    end
  end

  test "destroying a transaction schedules a recompute" do
    entry = create_transaction(account: @account)

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.destroy!
    end
  end

  test "changing an unrelated transaction attribute does not schedule a recompute" do
    entry = create_transaction(account: @account, category: categories(:food_and_drink))

    assert_no_enqueued_jobs(only: RecomputeBudgetRolloverJob) do
      entry.entryable.update!(extra: { "note" => "unrelated" })
    end
  end

  test "changing a transaction entry's amount schedules a recompute" do
    entry = create_transaction(account: @account)

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.update!(amount: entry.amount + 10)
    end
  end

  test "changing a transaction entry's date schedules a recompute" do
    entry = create_transaction(account: @account)

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.update!(date: entry.date - 1.day)
    end
  end

  test "excluding a transaction entry schedules a recompute" do
    entry = create_transaction(account: @account)

    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      entry.update!(excluded: true)
    end
  end

  test "a valuation entry's amount changing does not schedule a recompute" do
    entry = create_valuation(account: @account)

    assert_no_enqueued_jobs(only: RecomputeBudgetRolloverJob) do
      entry.update!(amount: entry.amount + 100)
    end
  end

  test "creating a new transaction schedules a recompute" do
    assert_enqueued_with(job: RecomputeBudgetRolloverJob) do
      create_transaction(account: @account, category: categories(:food_and_drink))
    end
  end
end
