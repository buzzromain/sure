require "test_helper"

class BudgetCategoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)

    # Create parent category with unique name
    @parent_category = Category.create!(
      name: "Test Food & Groceries #{Time.now.to_f}",
      family: @family,
      color: "#4da568",
      lucide_icon: "utensils"
    )

    # Create subcategories with unique names
    @subcategory_with_limit = Category.create!(
      name: "Test Restaurants #{Time.now.to_f}",
      parent: @parent_category,
      family: @family
    )

    @subcategory_inheriting = Category.create!(
      name: "Test Groceries #{Time.now.to_f}",
      parent: @parent_category,
      family: @family
    )

    # Create budget categories
    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 1000,
      currency: "USD"
    )

    @subcategory_with_limit_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_with_limit,
      budgeted_spending: 300,
      currency: "USD"
    )

    @subcategory_inheriting_bc = BudgetCategory.create!(
      budget: @budget,
      category: @subcategory_inheriting,
      budgeted_spending: 0,  # Inherits from parent
      currency: "USD"
    )
  end

  # A reservation that silently omits an obligation reads as money still free to
  # spend, so one with no rate is counted and reported instead of skipped.
  test "bills_reserved counts an obligation it cannot convert" do
    foreign = @family.recurring_transactions.create!(
      name: "Tokyo storage", account: accounts(:depository), amount: 50_000,
      currency: "JPY", bill_type: "bill", category_id: @parent_category.id,
      expected_day_of_month: 3, anchor_date: @budget.start_date,
      last_occurrence_date: @budget.start_date, next_expected_date: @budget.start_date,
      status: "active", manual: true
    )
    # Creating a series generates its own occurrences; clear them so this test
    # asserts against exactly one known row.
    foreign.recurring_occurrences.destroy_all
    foreign.recurring_occurrences.create!(
      family: @family, original_due_on: @budget.start_date + 3,
      due_on: @budget.start_date + 3, currency: "JPY", expected_amount: 50_000
    )
    assert_equal 0, ExchangeRate.where(from_currency: "JPY", to_currency: "USD").count,
      "the scenario depends on there being no rate to find"

    assert_equal 1, @parent_budget_category.bills_reserved_unconvertible_count,
      "the JPY obligation must be reported rather than dropped from the reservation"
  end

  # A foreign obligation is still owed out of this category, so it is converted
  # rather than skipped. The old behaviour reserved nothing for it at all.
  test "bills_reserved converts a foreign obligation it has a rate for" do
    # exchange_to defaults to today's rate, matching how every other bills
    # total converts.
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.1,
                         date: Date.current)
    eur = @family.recurring_transactions.create!(
      name: "Berlin storage", account: accounts(:depository), amount: 100,
      currency: "EUR", bill_type: "bill", category_id: @parent_category.id,
      expected_day_of_month: 3, anchor_date: @budget.start_date,
      last_occurrence_date: @budget.start_date, next_expected_date: @budget.start_date,
      status: "active", manual: true
    )
    eur.recurring_occurrences.destroy_all
    eur.recurring_occurrences.create!(
      family: @family, original_due_on: @budget.start_date + 3,
      due_on: @budget.start_date + 3, currency: "EUR", expected_amount: 100
    )

    assert_equal 110, @parent_budget_category.bills_reserved.amount
    assert_equal 0, @parent_budget_category.bills_reserved_unconvertible_count
  end

  test "bills_reserved sums obligations in the budget currency" do
    bill = @family.recurring_transactions.create!(
      name: "Groceries plan", account: accounts(:depository), amount: 120,
      currency: "USD", bill_type: "bill", category_id: @parent_category.id,
      expected_day_of_month: 3, anchor_date: @budget.start_date,
      last_occurrence_date: @budget.start_date, next_expected_date: @budget.start_date,
      status: "active", manual: true
    )
    bill.recurring_occurrences.destroy_all
    bill.recurring_occurrences.create!(
      family: @family, original_due_on: @budget.start_date + 3,
      due_on: @budget.start_date + 3, currency: "USD", expected_amount: 120
    )

    assert_equal 120, @parent_budget_category.bills_reserved.amount
    assert_equal 0, @parent_budget_category.bills_reserved_unconvertible_count
  end

  test "subcategory with zero budget inherits from parent" do
    assert @subcategory_inheriting_bc.inherits_parent_budget?
    refute @subcategory_with_limit_bc.inherits_parent_budget?
    refute @parent_budget_category.inherits_parent_budget?
  end

  test "parent_budget_category returns parent for subcategories" do
    assert_equal @parent_budget_category, @subcategory_inheriting_bc.parent_budget_category
    assert_equal @parent_budget_category, @subcategory_with_limit_bc.parent_budget_category
    assert_nil @parent_budget_category.parent_budget_category
  end

  test "display_budgeted_spending shows parent budget for inheriting subcategories" do
    assert_equal 1000, @subcategory_inheriting_bc.display_budgeted_spending
    assert_equal 300, @subcategory_with_limit_bc.display_budgeted_spending
    assert_equal 1000, @parent_budget_category.display_budgeted_spending
  end

  test "inheriting subcategory shares parent available_to_spend" do
    # Mock the actual spending values
    # Parent's actual_spending from income_statement includes all children
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(150)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(50)

    # Parent available calculation:
    # shared_pool = 1000 (parent budget) - 300 (subcategory with limit budget) = 700
    # shared_pool_spending = 150 (total) - 100 (subcategory with limit spending) = 50
    # available = 700 - 50 = 650
    assert_equal 650, @parent_budget_category.available_to_spend

    # Inheriting subcategory shares parent's available (650)
    assert_equal 650, @subcategory_inheriting_bc.available_to_spend

    # Subcategory with limit: 300 (its budget) - 100 (its spending) = 200
    assert_equal 200, @subcategory_with_limit_bc.available_to_spend
  end

  test "adjustments_balance adds into available_to_spend without leaking across parent/child" do
    @parent_budget_category.update_column(:adjustments_balance, 100)
    @subcategory_with_limit_bc.update_column(:adjustments_balance, 50)
    # Ignored: an inheriting subcategory has no reserve of its own to report.
    @subcategory_inheriting_bc.update_column(:adjustments_balance, 999)

    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(150)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(50)

    # parent_budget = 1000 + 0 (rollover disabled) + 100 (own adjustment) = 1100
    # shared_pool = 1100 - 300 (subcategory_with_limit's budgeted_spending only) = 800
    # shared_pool_spending = 150 - 100 = 50
    # available = 800 - 50 = 750 -- the child's own 50 adjustment never enters this.
    assert_equal 750, @parent_budget_category.available_to_spend

    # Delegates wholly to the parent -- its own (ignored) 999 plays no part.
    assert_equal 750, @subcategory_inheriting_bc.available_to_spend

    # 300 (budget) + 0 (rollover) + 50 (its own adjustment) - 100 (spending) = 250
    assert_equal 250, @subcategory_with_limit_bc.available_to_spend

    assert @parent_budget_category.adjusted?
    assert @subcategory_with_limit_bc.adjusted?
    # Gated the same way as adjustments_balance itself.
    assert_not @subcategory_inheriting_bc.adjusted?
  end

  # Step 3: rolled_over_amount can now be negative (the DB check constraint
  # that used to forbid it is gone). percent_of_budget_spent must never
  # return nil or a raw negative number once the effective budget itself
  # goes to or below zero — see the plan for the exact fallthrough each of
  # these two tests used to hit before the fix.
  test "percent_of_budget_spent returns 100, not nil, once its own budget is negative and something was spent" do
    @subcategory_with_limit_bc.update!(rollover_enabled: true)
    @subcategory_with_limit_bc.update_column(:rolled_over_amount, -500) # budgeted 300 - 500 = -200

    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(50)

    assert_equal 100, @subcategory_with_limit_bc.percent_of_budget_spent
    assert_equal 100, @subcategory_with_limit_bc.bar_width_percent
    assert_not @subcategory_with_limit_bc.near_limit?, "over_budget? already covers this, near_limit? must not also fire"
  end

  test "percent_of_budget_spent returns 0, not nil, when its own budget is negative but nothing was spent yet" do
    @subcategory_with_limit_bc.update!(rollover_enabled: true)
    @subcategory_with_limit_bc.update_column(:rolled_over_amount, -500)

    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(0)

    assert_equal 0, @subcategory_with_limit_bc.percent_of_budget_spent
  end

  test "percent_of_budget_spent returns 100, not a negative number, once the inherited parent budget is negative" do
    @parent_budget_category.update!(rollover_enabled: true)
    @parent_budget_category.update_column(:rolled_over_amount, -1_500) # budgeted 1000 - 1500 = -500

    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(80)

    assert_equal 100, @subcategory_inheriting_bc.percent_of_budget_spent
  end

  test "percent_of_budget_spent for inheriting subcategory uses parent budget" do
    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # 100 / 1000 (parent budget) = 10%
    assert_equal 10.0, @subcategory_inheriting_bc.percent_of_budget_spent
  end

  test "parent with no subcategories works as before" do
    # Create a standalone parent category without subcategories
    standalone_category = Category.create!(
      name: "Test Entertainment #{Time.now.to_f}",
      family: @family,
      color: "#a855f7",
      lucide_icon: "drama"
    )

    standalone_bc = BudgetCategory.create!(
      budget: @budget,
      category: standalone_category,
      budgeted_spending: 500,
      currency: "USD"
    )

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(standalone_bc).returns(200)

    # Should work exactly as before: 500 - 200 = 300
    assert_equal 300, standalone_bc.available_to_spend
    assert_equal 40.0, standalone_bc.percent_of_budget_spent
  end

  test "uncategorized budget category returns no subcategories" do
    uncategorized_bc = BudgetCategory.uncategorized
    uncategorized_bc.budget = @budget

    # Before the fix, this would return all top-level categories because
    # category.id is nil, causing WHERE parent_id IS NULL to match all roots
    assert_empty uncategorized_bc.subcategories
  end

  test "parent with only inheriting subcategories shares entire budget" do
    # Set subcategory_with_limit to also inherit
    @subcategory_with_limit_bc.update!(budgeted_spending: 0)

    # Mock spending
    @budget.stubs(:budget_category_actual_spending).with(@parent_budget_category).returns(200)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_with_limit_bc).returns(100)
    @budget.stubs(:budget_category_actual_spending).with(@subcategory_inheriting_bc).returns(100)

    # All should show same available: 1000 - 200 = 800
    assert_equal 800, @parent_budget_category.available_to_spend
    assert_equal 800, @subcategory_with_limit_bc.available_to_spend
    assert_equal 800, @subcategory_inheriting_bc.available_to_spend
  end

  test "update_budgeted_spending! preserves positive parent reserve when subcategory becomes individual" do
    @subcategory_inheriting_bc.update_budgeted_spending!(200)

    assert_equal 1200, @parent_budget_category.reload.budgeted_spending
    assert_equal 200, @subcategory_inheriting_bc.reload.budgeted_spending
    refute @subcategory_inheriting_bc.reload.inherits_parent_budget?
  end

  test "update_budgeted_spending! lowers parent when subcategory returns to shared" do
    @subcategory_with_limit_bc.update_budgeted_spending!(0)

    assert_equal 700, @parent_budget_category.reload.budgeted_spending
    assert @subcategory_with_limit_bc.reload.inherits_parent_budget?
  end

  test "update_budgeted_spending! does not preserve a negative parent reserve" do
    # Create an artificial inconsistent parent total to verify recovery behavior.
    @parent_budget_category.update!(budgeted_spending: 50)
    @subcategory_inheriting_bc.update!(budgeted_spending: 50)

    @subcategory_with_limit_bc.update_budgeted_spending!(20)

    assert_equal 70, @parent_budget_category.reload.budgeted_spending
    assert_equal 20, @subcategory_with_limit_bc.reload.budgeted_spending
    assert_equal 50, @subcategory_inheriting_bc.reload.budgeted_spending
  end

  test "budgeted? returns true only when display_budgeted_spending > 0" do
    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(100)
    assert @subcategory_with_limit_bc.budgeted?

    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(0)
    refute @subcategory_with_limit_bc.budgeted?

    @subcategory_with_limit_bc.stubs(:display_budgeted_spending).returns(nil)
    refute @subcategory_with_limit_bc.budgeted?
  end

  test "unbudgeted_with_spending? is true only when not budgeted and has spending" do
    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:actual_spending).returns(10)
    assert @subcategory_with_limit_bc.unbudgeted_with_spending?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(true)
    assert_not @subcategory_with_limit_bc.unbudgeted_with_spending?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:actual_spending).returns(0)
    assert_not @subcategory_with_limit_bc.unbudgeted_with_spending?

    @subcategory_with_limit_bc.stubs(:actual_spending).returns(nil)
    assert_not @subcategory_with_limit_bc.unbudgeted_with_spending?
  end

  test "over_budget_with_budget? requires both budgeted and over_budget" do
    @subcategory_with_limit_bc.stubs(:budgeted?).returns(true)
    @subcategory_with_limit_bc.stubs(:over_budget?).returns(true)
    assert @subcategory_with_limit_bc.over_budget_with_budget?

    @subcategory_with_limit_bc.stubs(:over_budget?).returns(false)
    assert_not @subcategory_with_limit_bc.over_budget_with_budget?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:over_budget?).returns(true)
    assert_not @subcategory_with_limit_bc.over_budget_with_budget?
  end

  test "on_track? is true only when budgeted and not over_budget" do
    @subcategory_with_limit_bc.stubs(:budgeted?).returns(true)
    @subcategory_with_limit_bc.stubs(:over_budget?).returns(false)
    assert @subcategory_with_limit_bc.on_track?

    @subcategory_with_limit_bc.stubs(:over_budget?).returns(true)
    assert_not @subcategory_with_limit_bc.on_track?

    @subcategory_with_limit_bc.stubs(:budgeted?).returns(false)
    @subcategory_with_limit_bc.stubs(:over_budget?).returns(false)
    assert_not @subcategory_with_limit_bc.on_track?
  end

  test "any_over_budget? is true if either condition is true" do
    @subcategory_with_limit_bc.stubs(:unbudgeted_with_spending?).returns(true)
    @subcategory_with_limit_bc.stubs(:over_budget_with_budget?).returns(false)
    assert @subcategory_with_limit_bc.any_over_budget?

    @subcategory_with_limit_bc.stubs(:unbudgeted_with_spending?).returns(false)
    @subcategory_with_limit_bc.stubs(:over_budget_with_budget?).returns(true)
    assert @subcategory_with_limit_bc.any_over_budget?

    @subcategory_with_limit_bc.stubs(:unbudgeted_with_spending?).returns(false)
    @subcategory_with_limit_bc.stubs(:over_budget_with_budget?).returns(false)
    assert_not @subcategory_with_limit_bc.any_over_budget?
  end

  test "visible_on_track? behavior for different category types" do
    # 1. not on_track => always false
    @subcategory_with_limit_bc.stubs(:on_track?).returns(false)
    assert_not @subcategory_with_limit_bc.visible_on_track?

    # 2. normal category (not subcategory) => true if on_track
    @parent_budget_category.stubs(:on_track?).returns(true)
    assert @parent_budget_category.visible_on_track?

    # 3. subcategory inheriting, no spending => hidden
    @subcategory_inheriting_bc.stubs(:on_track?).returns(true)
    @subcategory_inheriting_bc.stubs(:actual_spending).returns(0)
    assert_not @subcategory_inheriting_bc.visible_on_track?

    # 4. subcategory inheriting, has spending => visible
    @subcategory_inheriting_bc.stubs(:actual_spending).returns(10)
    assert @subcategory_inheriting_bc.visible_on_track?
  end

  test "suggested_daily_spending uses budget.end_date for custom month periods" do
    @family.update!(month_start_day: 15)

    # Today (Jun 1) is in the calendar month after the budget period start (May 15).
    # The pre-fix helper compared start_date.month to Date.current.month and returned nil here.
    travel_to Date.new(2026, 6, 1) do
      @budget.update!(start_date: Date.new(2026, 5, 15), end_date: Date.new(2026, 6, 14))
      @parent_budget_category.stubs(:actual_spending).returns(0)

      suggestion = @parent_budget_category.suggested_daily_spending

      assert suggestion, "expected suggested_daily_spending when current period spans calendar months"
      assert_equal 14, suggestion[:days_remaining]
    end
  end

  test "suggested_daily_spending is nil for a category backing a maintained reserve" do
    Goal.create!(family: @family, name: "Emergency fund", target_amount: 5000, currency: "USD",
                 kind: "maintained", funding_category: @parent_category)

    assert_nil @parent_budget_category.suggested_daily_spending
  end

  # --- move_allocation! (Lot A2) ---

  test "moving money between two top-level envelopes conserves the total" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 200, currency: "USD")
    before = @budget.reload.allocated_spending

    BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: 50)

    assert_equal 950, @parent_budget_category.reload.budgeted_spending
    assert_equal 250, destination.reload.budgeted_spending
    assert_equal before, @budget.reload.allocated_spending, "allocated_spending must be invariant"
  end

  # Deliberately a leaf as the source: only there does "the whole allocation"
  # mean the whole of it. A parent's figure already contains its individually
  # funded children's, so its boundary is its own reserve — covered separately
  # below. This test used to move a parent's gross amount and pass, which is
  # exactly the money-teleports-back bug.
  test "moving the whole allocation is allowed, moving one cent more is not" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")
    source = @subcategory_with_limit_bc.reload
    whole = source.budgeted_spending

    assert_raises(BudgetCategory::InvalidMove) do
      BudgetCategory.move_allocation!(from: source, to: destination, amount: whole + 0.01)
    end

    BudgetCategory.move_allocation!(from: source, to: destination, amount: whole)
    assert_equal 0, source.reload.budgeted_spending
    assert_equal whole, destination.reload.budgeted_spending
  end

  test "an amount larger than the source allocation is refused" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")

    error = assert_raises(BudgetCategory::InvalidMove) do
      BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: 1001)
    end

    assert_equal :insufficient_funds, error.reason
    assert_equal 1000, @parent_budget_category.reload.budgeted_spending
  end

  test "a zero or negative amount is refused" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")

    [ 0, -50 ].each do |amount|
      error = assert_raises(BudgetCategory::InvalidMove) do
        BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: amount)
      end
      assert_equal :non_positive_amount, error.reason
    end
  end

  test "categories from two different budgets cannot exchange money" do
    other_budget = Budget.create!(
      family: @family,
      start_date: @budget.start_date - 1.month,
      end_date: @budget.start_date - 1.day,
      currency: @budget.currency
    )
    foreign_category = Category.create!(name: "Test Foreign #{Time.now.to_f}", family: @family, color: "#e99537")
    foreign = BudgetCategory.create!(budget: other_budget, category: foreign_category, budgeted_spending: 100, currency: other_budget.currency)

    error = assert_raises(BudgetCategory::InvalidMove) do
      BudgetCategory.move_allocation!(from: @parent_budget_category, to: foreign, amount: 10)
    end

    assert_equal :different_budgets, error.reason
  end

  test "a category cannot move money to itself" do
    error = assert_raises(BudgetCategory::InvalidMove) do
      BudgetCategory.move_allocation!(from: @parent_budget_category, to: @parent_budget_category, amount: 10)
    end

    assert_equal :same_category, error.reason
  end

  # sync_parent_budgeted_spending! rebuilds a parent from its children, so a
  # parent <-> child move would be re-derived away.
  test "money cannot move between a parent and its own subcategory, in either direction" do
    [ [ @parent_budget_category, @subcategory_with_limit_bc ],
      [ @subcategory_with_limit_bc, @parent_budget_category ] ].each do |from, to|
      error = assert_raises(BudgetCategory::InvalidMove) do
        BudgetCategory.move_allocation!(from: from, to: to, amount: 50)
      end
      assert_equal :parent_child, error.reason
    end
  end

  test "Uncategorized can neither give nor receive" do
    [ [ BudgetCategory.uncategorized, @parent_budget_category ],
      [ @parent_budget_category, BudgetCategory.uncategorized ] ].each do |from, to|
      error = assert_raises(BudgetCategory::InvalidMove) do
        BudgetCategory.move_allocation!(from: from, to: to, amount: 10)
      end
      assert_equal :uncategorized, error.reason
    end
  end

  # A subcategory's allocation is folded into its parent's, so moving money
  # out of one must pull the parent down by the same amount and leave the
  # budget total untouched.
  test "a move out of a subcategory keeps its parent consistent" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")
    before = @budget.reload.allocated_spending

    BudgetCategory.move_allocation!(from: @subcategory_with_limit_bc, to: destination, amount: 100)

    assert_equal 200, @subcategory_with_limit_bc.reload.budgeted_spending
    assert_equal 100, destination.reload.budgeted_spending
    assert_equal 900, @parent_budget_category.reload.budgeted_spending,
                 "the parent must absorb its subcategory's decrease"
    assert_equal before, @budget.reload.allocated_spending, "allocated_spending must be invariant"
  end

  # A parent's budgeted_spending already contains its individually funded
  # subcategories', so treating the gross figure as movable let a move spend
  # money a child had ring-fenced. The parent dropped below the sum of its
  # children, and the next edit to any child rebuilt it — the money appeared
  # to teleport back.
  test "a parent can only send away its own reserve, not its children's money" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")
    parent_gross = @parent_budget_category.reload.budgeted_spending
    ring_fenced = @subcategory_with_limit_bc.reload.budgeted_spending
    reserve = parent_gross - ring_fenced

    assert_operator ring_fenced, :>, 0, "fixture should ring-fence part of the parent"

    error = assert_raises(BudgetCategory::InvalidMove) do
      BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: reserve + 1)
    end
    assert_equal :insufficient_funds, error.reason

    assert_equal parent_gross, @parent_budget_category.reload.budgeted_spending
  end

  test "a parent may still send away every penny of its own reserve" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")
    reserve = @parent_budget_category.reload.budgeted_spending - @subcategory_with_limit_bc.reload.budgeted_spending
    before_total = @budget.reload.allocated_spending

    BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: reserve)

    assert_equal reserve, destination.reload.budgeted_spending
    assert_equal before_total, @budget.reload.allocated_spending, "allocated_spending must be invariant"
  end

  test "a move between two subcategories of the same parent leaves the parent alone" do
    before_parent = @parent_budget_category.reload.budgeted_spending
    before_total = @budget.reload.allocated_spending
    @subcategory_inheriting_bc.update_budgeted_spending!(100)

    BudgetCategory.move_allocation!(from: @subcategory_with_limit_bc, to: @subcategory_inheriting_bc, amount: 50)

    assert_equal 250, @subcategory_with_limit_bc.reload.budgeted_spending
    assert_equal 150, @subcategory_inheriting_bc.reload.budgeted_spending
    assert_equal before_parent + 100, @parent_budget_category.reload.budgeted_spending
    assert_equal before_total + 100, @budget.reload.allocated_spending
  end

  # The rollover chain is the caller's job, never the move's: taking the
  # calculator's advisory lock while these row locks are held would invert
  # the lock order and deadlock two concurrent moves.
  test "move_allocation! does not recompute the rollover chain itself" do
    other_parent = Category.create!(name: "Test Transport #{Time.now.to_f}", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other_parent, budgeted_spending: 0, currency: "USD")

    Budget::RolloverCalculator.any_instance.expects(:recompute!).never

    BudgetCategory.move_allocation!(from: @parent_budget_category, to: destination, amount: 10)
  end

  test "contribution_amount is required and must be positive in fixed mode" do
    @parent_budget_category.contribution_mode = "fixed"

    assert_not @parent_budget_category.valid?
    assert_includes @parent_budget_category.errors[:contribution_amount], "is not a number"

    @parent_budget_category.contribution_amount = -10
    assert_not @parent_budget_category.valid?
    assert_includes @parent_budget_category.errors[:contribution_amount], "must be greater than 0"

    @parent_budget_category.contribution_amount = 100
    assert @parent_budget_category.valid?, @parent_budget_category.errors.full_messages.to_sentence
  end

  test "contribution_amount is cleared outside fixed mode rather than rejected" do
    @parent_budget_category.update!(contribution_mode: "fixed", contribution_amount: 100)

    @parent_budget_category.update!(contribution_mode: "manual")

    assert_nil @parent_budget_category.reload.contribution_amount
  end

  test "complete_to requires a linked funding goal" do
    @parent_budget_category.contribution_mode = "complete_to"

    assert_not @parent_budget_category.valid?
    assert_includes @parent_budget_category.errors[:contribution_mode],
      "Link a goal to this category before completing to it."
  end

  test "contribution_target_amount for complete_to tops up to the linked goal's target, never negative" do
    Goal.create!(family: @family, name: "Complete to test", target_amount: 500, currency: "USD",
                 funding_category: @parent_category)
    @parent_budget_category.contribution_mode = "complete_to"

    assert_equal 500, @parent_budget_category.contribution_target_amount(0)
    assert_equal 200, @parent_budget_category.contribution_target_amount(300)
    assert_equal 0, @parent_budget_category.contribution_target_amount(600)
  end

  test "contribution_target_amount defaults its carry to this row's own stored rolled_over_amount" do
    Goal.create!(family: @family, name: "Complete to test", target_amount: 500, currency: "USD",
                 funding_category: @parent_category)
    @parent_budget_category.update!(contribution_mode: "complete_to", rollover_enabled: true)
    @parent_budget_category.update_column(:rolled_over_amount, 150)

    assert_equal 350, @parent_budget_category.contribution_target_amount
  end

  test "contribution_target_amount returns nil for complete_to without a linked goal, or a currency mismatch" do
    @parent_budget_category.contribution_mode = "complete_to"
    assert_nil @parent_budget_category.contribution_target_amount, "no goal linked at all"

    # Goal itself already refuses a currency mismatch against the family
    # (funding_category_must_match_family_currency) — bypassing validation
    # here to exercise contribution_target_amount's OWN guard directly,
    # since it can't assume how a mismatched state might otherwise arise
    # (legacy data, a family currency change after the fact).
    mismatched_goal = Goal.new(family: @family, name: "Currency mismatch", target_amount: 500, currency: "EUR",
                               funding_category: @parent_category)
    mismatched_goal.save!(validate: false)

    assert_nil @parent_budget_category.contribution_target_amount,
      "goal linked but currency differs from the category's USD"
  end
end

class BudgetCategoryRolloverTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    @account = create_account(owner: nil)
  end

  test "carries a surplus into the next month" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    recompute!

    assert_equal 0, stored_rollover(first)
    assert_equal 70, stored_rollover(second)
    assert_equal 170, budget_category_for(second).available_to_spend
  end

  test "an overspent month rolls over as a negative, and a fresh allocation only partly offsets it" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(150, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    recompute!

    assert_equal(-50, stored_rollover(second))
    assert_equal 50, budget_category_for(second).available_to_spend
  end

  test "a category without the toggle never accumulates a rollover" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100, rollover: false)

    recompute!

    assert_equal 0, stored_rollover(second)
    assert_equal 100, budget_category_for(second).available_to_spend
  end

  test "a subcategory inheriting its parent's budget is excluded" do
    subcategory = @family.categories.create!(name: "Flights", parent: @category, color: "#6172F3")

    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    first.budget_categories.find_by!(category: subcategory).update!(budgeted_spending: 0, rollover_enabled: true)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)
    second_subcategory = second.budget_categories.find_by!(category: subcategory)
    second_subcategory.update!(budgeted_spending: 0, rollover_enabled: true)

    recompute!

    assert_equal 0, second_subcategory.reload[:rolled_over_amount]
    assert_equal 0, second_subcategory.rolled_over_amount
  end

  test "a parent's rollover excludes what its ring-fenced subcategories carry themselves" do
    subcategory = @family.categories.create!(name: "Hotels", parent: @category, color: "#6172F3")

    first = initialized_budget(2.months.ago)
    allocate(first, 300)
    first.budget_categories.find_by!(category: subcategory).update!(budgeted_spending: 100, rollover_enabled: true)
    spend(20, budget: first, category: subcategory)

    second = initialized_budget(1.month.ago)
    allocate(second, 300)
    second_subcategory = second.budget_categories.find_by!(category: subcategory)
    second_subcategory.update!(budgeted_spending: 100, rollover_enabled: true)

    recompute!

    # Subcategory keeps its own 100 - 20 = 80; the parent only carries the
    # 300 - 100 = 200 shared pool it never spent from.
    assert_equal 80, second_subcategory.reload[:rolled_over_amount]
    assert_equal 200, stored_rollover(second)
  end

  test "accumulates across three consecutive months" do
    first = initialized_budget(3.months.ago)
    allocate(first, 50)

    second = initialized_budget(2.months.ago)
    allocate(second, 50)

    third = initialized_budget(1.month.ago)
    allocate(third, 50)

    recompute!

    assert_equal 0, stored_rollover(first)
    assert_equal 50, stored_rollover(second)
    assert_equal 100, stored_rollover(third)
    assert_equal 150, budget_category_for(third).available_to_spend
  end

  test "a gap month does not reset the chain" do
    first = initialized_budget(3.months.ago)
    allocate(first, 100)
    spend(20, budget: first)

    # Bootstrapped but never initialized: a month the user skipped, not a
    # month budgeted at zero.
    Budget.find_or_bootstrap(@family, start_date: 2.months.ago)

    third = initialized_budget(1.month.ago)
    allocate(third, 100)

    recompute!

    assert_equal 80, stored_rollover(third)
  end

  test "one member's personal chain does not contaminate another's" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)
    ann = users(:ann)
    josh_account = create_account(owner: josh, name: "Josh Checking")

    josh_first = initialized_budget(2.months.ago, user: josh)
    allocate(josh_first, 100)
    create_transaction(account: josh_account, date: josh_first.start_date, amount: 30, category: @category)

    ann_first = initialized_budget(2.months.ago, user: ann)
    allocate(ann_first, 40)

    josh_second = initialized_budget(1.month.ago, user: josh)
    allocate(josh_second, 100)

    ann_second = initialized_budget(1.month.ago, user: ann)
    allocate(ann_second, 40)

    recompute!(user: josh)
    recompute!(user: ann)

    assert_equal 70, stored_rollover(josh_second)
    assert_equal 40, stored_rollover(ann_second)
  end

  test "flipping the toggle off clears the stored amount" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    second_category = allocate(second, 100)

    recompute!
    assert_equal 70, stored_rollover(second)

    second_category.update!(rollover_enabled: false)
    recompute!

    assert_equal 0, stored_rollover(second)
  end

  test "recompute does not clobber an allocation changed underneath it" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    # Stand in for a concurrent request: the calculator has already loaded the
    # chain when someone else moves the allocation, so its in-memory copy is
    # stale by the time it writes. `budget_category_actual_spending` is a
    # public seam it goes through on every row, just before the upsert.
    Budget.any_instance.stubs(:budget_category_actual_spending).with do |_budget_category|
      budget_category_for(second).update_column(:budgeted_spending, 250)
      true
    end.returns(30)

    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    assert_equal 70, stored_rollover(second)
    assert_equal 250, budget_category_for(second).budgeted_spending
  end

  test "the household carry is the same whoever triggers the recompute" do
    # Owned by josh, so ann's finance accounts don't include it. Before the
    # account scope was pinned, IncomeStatement fell back to Current.user and
    # each member's page view overwrote the shared row with their own number.
    josh_account = create_account(owner: users(:josh), name: "Josh only")

    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    create_transaction(account: josh_account, date: first.start_date, amount: 30, category: @category)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    Current.stubs(:user).returns(users(:ann))
    recompute!
    assert_equal 70, stored_rollover(second)

    Current.stubs(:user).returns(users(:josh))
    recompute!
    assert_equal 70, stored_rollover(second)
  end

  test "the carry stops at a currency change rather than crossing it" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)

    @family.update!(currency: "EUR")
    second = initialized_budget(1.month.ago)
    assert_equal "EUR", second.currency
    allocate(second, 100)

    recompute!

    assert_equal 0, stored_rollover(second)
  end

  test "an opening balance is available immediately and carries forward regardless of rollover" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100, rollover: false)

    BudgetAdjustment.record_opening_balance!(category: @category, amount: 250, family: @family, currency: "USD", effective_on: first.start_date)

    second = initialized_budget(1.month.ago)
    allocate(second, 100, rollover: false)

    recompute!

    # Effective within the first period already, so it shows up there too.
    assert_equal 250, stored_adjustments_balance(first)
    assert_equal 350, budget_category_for(first).available_to_spend

    # Carries forward into the next month even though rollover is off --
    # only the ordinary surplus carry is gated by the toggle.
    assert_equal 0, stored_rollover(second)
    assert_equal 250, stored_adjustments_balance(second)
    assert_equal 350, budget_category_for(second).available_to_spend
  end

  test "a reallocation moves adjustments_balance and available_to_spend on both sides" do
    other_category = @family.categories.create!(name: "Car repairs", color: "#6172F3")

    # Current month, not a past one: reallocate! stamps effective_on as
    # today, so the period it lands in must actually contain today.
    budget = initialized_budget(Date.current)
    allocate(budget, 0, rollover: false)
    other_bc = budget.budget_categories.find_by!(category: other_category)
    other_bc.update!(rollover_enabled: false)

    BudgetAdjustment.record_opening_balance!(category: @category, amount: 200, family: @family, currency: "USD", effective_on: budget.start_date)
    recompute!
    assert_equal 200, stored_adjustments_balance(budget)

    BudgetAdjustment.reallocate!(from_category: @category, to_category: other_category, amount: 80, family: @family)
    recompute!

    assert_equal 120, stored_adjustments_balance(budget)
    assert_equal 80, other_bc.reload[:adjustments_balance]
    assert_equal 120, budget_category_for(budget).available_to_spend
    assert_equal 80, other_bc.available_to_spend
  end

  test "adjustments are excluded from the carry across a currency change, same as rollover" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100, rollover: false)
    BudgetAdjustment.record_opening_balance!(category: @category, amount: 250, family: @family, currency: "USD", effective_on: first.start_date)

    @family.update!(currency: "EUR")
    second = initialized_budget(1.month.ago)
    allocate(second, 100, rollover: false)

    recompute!

    assert_equal 0, stored_adjustments_balance(second)
  end

  test "a gap month does not drop an adjustment dated inside it" do
    first = initialized_budget(3.months.ago)
    allocate(first, 100, rollover: false)

    # Bootstrapped but never initialized -- a month the user skipped.
    gap = Budget.find_or_bootstrap(@family, start_date: 2.months.ago)
    BudgetAdjustment.record_opening_balance!(category: @category, amount: 250, family: @family, currency: "USD", effective_on: gap.start_date)

    third = initialized_budget(1.month.ago)
    allocate(third, 100, rollover: false)

    recompute!

    assert_equal 250, stored_adjustments_balance(third)
  end

  test "one member's personal chain's adjustments do not contaminate another's" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)
    ann = users(:ann)

    josh_first = initialized_budget(1.month.ago, user: josh)
    allocate(josh_first, 100, rollover: false)
    BudgetAdjustment.record_opening_balance!(category: @category, amount: 300, family: @family, user: josh, currency: "USD", effective_on: josh_first.start_date)

    ann_first = initialized_budget(1.month.ago, user: ann)
    allocate(ann_first, 40, rollover: false)

    Budget::RolloverCalculator.new(family: @family, user: josh).recompute!
    Budget::RolloverCalculator.new(family: @family, user: ann).recompute!

    assert_equal 300, stored_adjustments_balance(josh_first)
    assert_equal 0, stored_adjustments_balance(ann_first)
  end

  test "deleting a category removes it from every month of the chain" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    recompute!
    assert_equal 70, stored_rollover(second)

    assert_difference "BudgetCategory.count", -2 do
      @category.destroy!
    end

    # Nothing to chain any more, and recomputing must not resurrect it.
    assert_nothing_raised { recompute! }
    assert_empty BudgetCategory.where(category_id: @category.id)
  end

  test "consumption is measured against the allocation plus the carry" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(50, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100)
    spend(30, budget: second)

    recompute!

    # 30 spent out of 100 allocated + 50 carried.
    assert_equal 50, stored_rollover(second)
    assert_in_delta 20.0, budget_category_for(second).percent_of_budget_spent, 0.01
  end

  test "a category funded only by the carry is not flagged as unbudgeted" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(50, budget: first)

    # Nothing allocated this month -- the envelope lives entirely off what
    # it carried. The zero-budget guards must look at 0 + 50, not at 0.
    second = initialized_budget(1.month.ago)
    allocate(second, 0)
    spend(20, budget: second)

    recompute!
    budget_category = budget_category_for(second)

    assert_equal 50, stored_rollover(second)
    assert_in_delta 40.0, budget_category.percent_of_budget_spent, 0.01
    assert_equal 30, budget_category.available_to_spend

    assert budget_category.budgeted?
    assert_not budget_category.over_budget?
    assert_not budget_category.unbudgeted_with_spending?
    assert_not budget_category.any_over_budget?
    assert budget_category.on_track?
  end

  test "an inheriting subcategory measures itself against its parent's carry" do
    subcategory = @family.categories.create!(name: "Flights", parent: @category, color: "#6172F3")

    first = initialized_budget(2.months.ago)
    allocate(first, 200)
    spend(50, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 200)
    second_subcategory = second.budget_categories.find_by!(category: subcategory)
    second_subcategory.update!(budgeted_spending: 0)
    spend(40, budget: second, category: subcategory)

    recompute!

    assert_equal 150, stored_rollover(second)
    assert second_subcategory.reload.inherits_parent_budget?

    # 40 spent against the parent's 200 allocated + 150 carried.
    assert_in_delta 11.43, second_subcategory.percent_of_budget_spent, 0.01
    assert second_subcategory.budgeted?
  end

  test "the carry survives a month the user merely opens" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    # The user does nothing but open the next month. Bootstrapping created
    # its rows; without inheritance they'd default the toggle off and drop
    # the carry on the floor.
    second = initialized_budget(1.month.ago)
    second_category = budget_category_for(second)
    assert second_category.rollover_enabled?, "a new month inherits the standing rollover choice"

    second_category.update!(budgeted_spending: 100)
    recompute!

    assert_equal 70, stored_rollover(second)
  end

  test "turning the toggle off overrides the inherited choice from there on" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 100, rollover: false)
    recompute!

    assert_equal 0, stored_rollover(second)

    third = initialized_budget(0.months.ago)
    assert_not budget_category_for(third).rollover_enabled?,
      "the later month inherits the off state, not the older on state"
  end

  test "opting out of a month forfeits its surplus even if a later month opts back in" do
    first = initialized_budget(3.months.ago)
    allocate(first, 100)
    spend(30, budget: first)

    # The user deliberately switches the envelope off for this month.
    second = initialized_budget(2.months.ago)
    allocate(second, 100, rollover: false)

    # ...and switches it back on the month after. The 100 they gave up must
    # not come back: an opted-out month neither receives nor sends.
    third = initialized_budget(1.month.ago)
    allocate(third, 100)

    recompute!

    assert_equal 0, stored_rollover(second)
    assert_equal 0, stored_rollover(third)
    assert_equal 100, budget_category_for(third).available_to_spend
  end

  test "the chain is locked before anything is written, and per chain" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)

    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(30, budget: first)
    second = initialized_budget(1.month.ago)
    allocate(second, 100)

    household_sql = capture_sql { recompute! }

    lock = household_sql.index { |sql| sql.include?("pg_advisory_xact_lock") }
    write = household_sql.index { |sql| sql.include?("INSERT INTO \"budget_categories\"") }

    assert lock, "the chain must be locked before its derived carry is written"
    assert write, "expected this recompute to write"
    assert lock < write, "the lock has to be taken before the read-then-write, not after"

    # A different chain must not queue behind this one: the key names the
    # (family, owner) pair, so household and personal recomputes are free to
    # run at the same time.
    josh_first = initialized_budget(2.months.ago, user: josh)
    josh_first.budget_categories.find_by!(category: @category).update!(budgeted_spending: 100, rollover_enabled: true)
    josh_sql = capture_sql { recompute!(user: josh) }

    assert_not_equal household_sql[lock],
                     josh_sql.find { |sql| sql.include?("pg_advisory_xact_lock") },
                     "each chain gets its own lock key"
  end

  test "one member's rollover choice does not leak into another's budget" do
    @family.update!(personal_budgets: true)
    josh = users(:josh)
    ann = users(:ann)

    josh_first = initialized_budget(2.months.ago, user: josh)
    josh_first.budget_categories.find_by!(category: @category).update!(budgeted_spending: 100, rollover_enabled: true)

    # Categories are family-wide, budgets are not: Ann's new month must not
    # pick up Josh's choice.
    ann_second = initialized_budget(1.month.ago, user: ann)
    josh_second = initialized_budget(1.month.ago, user: josh)

    assert josh_second.budget_categories.find_by!(category: @category).rollover_enabled?
    assert_not ann_second.budget_categories.find_by!(category: @category).rollover_enabled?
  end

  # Inheritance at row creation only covers months that do not exist yet. A
  # month opened BEFORE the user made the choice was created with the flag off
  # and had nothing to inherit, so the chain died there.
  test "switching rollover on reaches months that were already open" do
    first = initialized_budget(2.months.ago)
    later = initialized_budget(1.month.ago)
    allocate(first, 100, rollover: false)
    allocate(later, 100, rollover: false)

    budget_category_for(first).update!(rollover_enabled: true)
    budget_category_for(first).propagate_rollover_choice_forward!

    assert budget_category_for(later).reload.rollover_enabled?
  end

  test "switching it off reaches them too, and never runs backwards" do
    first = initialized_budget(2.months.ago)
    middle = initialized_budget(1.month.ago)
    allocate(first, 100)
    allocate(middle, 100)

    budget_category_for(middle).update!(rollover_enabled: false)
    budget_category_for(middle).propagate_rollover_choice_forward!

    assert_not budget_category_for(middle).reload.rollover_enabled?
    assert budget_category_for(first).reload.rollover_enabled?,
           "an earlier month keeps the choice it was given"
  end

  # --- Recurring contribution (fixed mode only — see plan for why complete_to/capped are deferred) ---

  test "a fixed contribution is inherited and already funds a newly opened month" do
    first = initialized_budget(1.month.ago)
    budget_category_for(first).update!(contribution_mode: "fixed", contribution_amount: 100)

    second = initialized_budget(Date.current)
    second_bc = budget_category_for(second)

    assert_equal "fixed", second_bc.contribution_mode
    assert_equal 100, second_bc.contribution_amount
    assert_equal 100, second_bc.budgeted_spending,
      "the recurring amount funds the month at creation, not on a later save"
  end

  test "propagate_contribution_choice_forward! reaches months already open, config and allocation both" do
    first = initialized_budget(2.months.ago)
    second = initialized_budget(1.months.ago)
    allocate(first, 0)
    allocate(second, 0)

    budget_category_for(first).update!(contribution_mode: "fixed", contribution_amount: 100)
    budget_category_for(first).propagate_contribution_choice_forward!

    second_bc = budget_category_for(second).reload
    assert_equal "fixed", second_bc.contribution_mode
    assert_equal 100, second_bc.budgeted_spending,
      "a month already open when the rule was set still picks it up"

    budget_category_for(first).update!(contribution_amount: 150)
    budget_category_for(first).propagate_contribution_choice_forward!

    assert_equal 150, budget_category_for(second).reload.budgeted_spending,
      "raising the recurring amount reaches a month already following it, or the change is invisible"
  end

  test "turning the recurring contribution off leaves a future month's already-set allocation alone" do
    first = initialized_budget(2.months.ago)
    second = initialized_budget(1.months.ago)
    allocate(first, 0)
    allocate(second, 0)

    budget_category_for(first).update!(contribution_mode: "fixed", contribution_amount: 100)
    budget_category_for(first).propagate_contribution_choice_forward!
    assert_equal 100, budget_category_for(second).reload.budgeted_spending

    budget_category_for(first).update!(contribution_mode: "manual")
    budget_category_for(first).propagate_contribution_choice_forward!

    second_bc = budget_category_for(second).reload
    assert_equal "manual", second_bc.contribution_mode
    assert_equal 100, second_bc.budgeted_spending,
      "turning the rule off doesn't retroactively erase a number it already produced"
  end

  test "a new month inheriting complete_to computes and locks in its contribution exactly once" do
    Goal.create!(family: @family, name: "Goal", target_amount: 500, currency: "USD", funding_category: @category)

    first = initialized_budget(1.month.ago)
    first_bc = budget_category_for(first)
    first_bc.update!(rollover_enabled: true, contribution_mode: "complete_to")
    # Mirrors what the controller does immediately when a user sets
    # complete_to on an EXISTING period (see BudgetCategoriesController#update):
    # compute now, using this row's own already-correct carry (0, nothing
    # precedes it), and stamp it. Without this, the calculator's own
    # "catch up a row nothing ever explicitly applied" behaviour would apply
    # here too on the next recompute below -- correct in general, but not
    # what this test is trying to isolate, and it would rewrite a month that
    # already has real spending against it.
    first_bc.update_columns(budgeted_spending: first_bc.contribution_target_amount, contribution_applied_at: Time.current)
    spend(20, budget: first)
    # leftover_for(first) = 500 (just applied) - 20 spent = 480, carried forward.

    second = initialized_budget(Date.current)
    # initialized_budget sets Budget#budgeted_spending (the family's monthly
    # income target, unrelated to any category) via .update! AFTER
    # find_or_bootstrap has already returned -- so `second` isn't
    # "initialized" yet, and invisible to the chain, during find_or_bootstrap's
    # own internal recompute!. This explicit call is what a real user's next
    # page load does naturally, once their month is actually set up.
    recompute!
    second_bc = budget_category_for(second)

    assert_equal "complete_to", second_bc.contribution_mode
    assert_equal 480, second_bc.rolled_over_amount
    assert_equal 20, second_bc.budgeted_spending, "500 target - 480 already carried = 20"
    assert_not_nil second_bc.contribution_applied_at

    # A later recompute -- e.g. triggered by editing an unrelated category
    # elsewhere in the family -- must never touch it again, even though the
    # incoming carry it was computed from could have changed by then.
    second_bc.update_column(:budgeted_spending, 999)
    recompute!

    assert_equal 999, budget_category_for(second).reload.budgeted_spending,
      "contribution_applied_at must stop the calculator from ever overwriting this again"
  end

  test "propagate_contribution_choice_forward! computes each future month's own contribution, not one shared value" do
    Goal.create!(family: @family, name: "Goal", target_amount: 500, currency: "USD", funding_category: @category)

    first = initialized_budget(2.months.ago)
    second = initialized_budget(1.months.ago)
    allocate(first, 0)
    allocate(second, 0)
    budget_category_for(second).update_column(:rolled_over_amount, 300)

    budget_category_for(first).update!(contribution_mode: "complete_to")
    budget_category_for(first).propagate_contribution_choice_forward!

    second_bc = budget_category_for(second).reload
    assert_equal "complete_to", second_bc.contribution_mode
    assert_equal 200, second_bc.budgeted_spending, "500 target - 300 already carried on THIS month = 200"
    assert_not_nil second_bc.contribution_applied_at
  end

  # Reference test for docs/mettre-de-cote-recommandation-produit-technique.md,
  # step 1: fixes today's flooring behaviour before step 4 considers a signed
  # activity figure. If this ever needs to change, it is because step 4 is
  # underway, not because the test was wrong.
  test "a refund with no matching expense in the same period floors actual_spending at zero" do
    budget = initialized_budget(Date.current)
    allocate(budget, 100)
    create_transaction(account: @account, date: budget.start_date, amount: -100, category: @category)

    assert_equal 0, budget.budget_category_actual_spending(budget_category_for(budget)),
      "a bare refund must not recredit the envelope as a signed -100 today " \
      "(Budget#budget_category_actual_spending floors expense - refund at 0)"
  end

  # Step 3: RolloverCalculator#leftover_for no longer floors at zero.
  test "an overspend carries forward as a negative rollover across two transitions" do
    first = initialized_budget(2.months.ago)
    allocate(first, 100)
    spend(150, budget: first)

    second = initialized_budget(1.month.ago)
    allocate(second, 0)

    recompute!

    assert_equal(-50, stored_rollover(second))
    second_bc = budget_category_for(second)
    assert second_bc.rolled_over?, "a negative carry is still a carry, not the absence of one"
    assert second_bc.over_budget?, "over_budget? must fire from the carry alone, with no spending this period"
    assert_equal(-50, second_bc.available_to_spend)
    assert_equal 0, second_bc.percent_of_budget_spent, "nothing was spent THIS period, so 0% of it, despite the deficit"

    third = initialized_budget(Date.current)
    allocate(third, 0)

    recompute!

    assert_equal(-50, stored_rollover(third),
      "the deficit survives untouched into a third period with nothing to close it")
  end

  private
    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        payload = args.last
        statements << payload[:sql] unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def create_account(owner:, name: "Rollover Checking")
      @family.accounts.create!(
        accountable: Depository.new,
        name: name,
        currency: "USD",
        balance: 10_000,
        status: "active",
        owner: owner
      )
    end

    def initialized_budget(date, user: nil)
      Budget.find_or_bootstrap(@family, start_date: date, user: user).tap do |budget|
        budget.update!(budgeted_spending: 5_000, expected_income: 7_000)
      end
    end

    def allocate(budget, amount, rollover: true)
      budget.budget_categories.find_by!(category: @category).tap do |budget_category|
        budget_category.update!(budgeted_spending: amount, rollover_enabled: rollover)
      end
    end

    def spend(amount, budget:, category: @category)
      create_transaction(account: @account, date: budget.start_date, amount: amount, category: category)
    end

    def recompute!(user: nil)
      Budget::RolloverCalculator.new(family: @family, user: user).recompute!
    end

    def budget_category_for(budget)
      BudgetCategory.find_by!(budget_id: budget.id, category: @category)
    end

    def stored_adjustments_balance(budget)
      budget_category_for(budget)[:adjustments_balance]
    end

    def stored_rollover(budget)
      budget_category_for(budget)[:rolled_over_amount]
    end
end
