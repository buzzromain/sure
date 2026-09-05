require "test_helper"

class BudgetAdjustmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)

    @source = Category.create!(name: "Emergency fund #{Time.now.to_f}", family: @family, color: "#4da568", lucide_icon: "shield")
    @destination = Category.create!(name: "Car repairs #{Time.now.to_f}", family: @family, color: "#6172F3", lucide_icon: "car")

    @budget = budgets(:one)
    @source_bc = BudgetCategory.create!(budget: @budget, category: @source, budgeted_spending: 0, currency: "USD")
    @destination_bc = BudgetCategory.create!(budget: @budget, category: @destination, budgeted_spending: 0, currency: "USD")
  end

  test "amount cannot be zero" do
    adjustment = BudgetAdjustment.new(family: @family, category: @source, kind: :opening_balance,
                                       amount: 0, currency: "USD", effective_on: Date.current)
    assert_not adjustment.valid?
  end

  test "effective_on is required" do
    adjustment = BudgetAdjustment.new(family: @family, category: @source, kind: :opening_balance,
                                       amount: 100, currency: "USD")
    assert_not adjustment.valid?
  end

  test "reallocation requires a group_id, opening_balance forbids one" do
    reallocation = BudgetAdjustment.new(family: @family, category: @source, kind: :reallocation,
                                         amount: 100, currency: "USD", effective_on: Date.current)
    assert_not reallocation.valid?
    assert reallocation.errors.of_kind?(:group_id, :blank)

    opening_balance = BudgetAdjustment.new(family: @family, category: @source, kind: :opening_balance,
                                            amount: 100, currency: "USD", effective_on: Date.current, group_id: SecureRandom.uuid)
    assert_not opening_balance.valid?
    assert opening_balance.errors.of_kind?(:group_id, :present)
  end

  test "a category from another family is rejected" do
    other_family = families(:empty)
    foreign_category = Category.create!(name: "Foreign", family: other_family, color: "#4da568", lucide_icon: "shield")

    adjustment = BudgetAdjustment.new(family: @family, category: foreign_category, kind: :opening_balance,
                                       amount: 100, currency: "USD", effective_on: Date.current)
    assert_not adjustment.valid?
  end

  test "record_opening_balance! persists a simple credit, twice if called twice" do
    BudgetAdjustment.record_opening_balance!(category: @source, amount: 200, family: @family, currency: "USD")
    BudgetAdjustment.record_opening_balance!(category: @source, amount: 50, family: @family, currency: "USD")

    assert_equal 2, BudgetAdjustment.where(category: @source, kind: :opening_balance).count
    assert_equal 250, BudgetAdjustment.where(category: @source).sum(:amount)
  end

  test "reallocate! writes a paired debit and credit that sum to zero" do
    BudgetAdjustment.record_opening_balance!(category: @source, amount: 200, family: @family, currency: "USD")
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    debit, credit = BudgetAdjustment.reallocate!(from_category: @source, to_category: @destination, amount: 80, family: @family)

    assert_equal(-80, debit.amount)
    assert_equal(80, credit.amount)
    assert_equal debit.group_id, credit.group_id
    assert_equal "reallocation", debit.kind
    assert_equal 0, BudgetAdjustment.where(group_id: debit.group_id).sum(:amount)
  end

  test "reallocate! refuses a non-positive amount" do
    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @source, to_category: @destination, amount: 0, family: @family)
    end
    assert_equal :non_positive_amount, error.reason
  end

  test "reallocate! refuses the same category on both sides" do
    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @source, to_category: @source, amount: 10, family: @family)
    end
    assert_equal :same_category, error.reason
  end

  test "reallocate! refuses a category and its own subcategory" do
    child = Category.create!(name: "Repairs sub #{Time.now.to_f}", family: @family, parent: @destination, color: "#6172F3", lucide_icon: "car")

    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @destination, to_category: child, amount: 10, family: @family)
    end
    assert_equal :parent_child, error.reason
  end

  test "reallocate! refuses a category belonging to another family" do
    other_family = families(:empty)
    foreign_category = Category.create!(name: "Foreign", family: other_family, color: "#4da568", lucide_icon: "shield")

    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @source, to_category: foreign_category, amount: 10, family: @family)
    end
    assert_equal :different_families, error.reason
  end

  test "reallocate! refuses more than the source has in reserve" do
    BudgetAdjustment.record_opening_balance!(category: @source, amount: 50, family: @family, currency: "USD")
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @source, to_category: @destination, amount: 51, family: @family)
    end
    assert_equal :insufficient_reserve, error.reason
  end

  test "reallocate! re-checks the reserve so a second call cannot double-spend it" do
    BudgetAdjustment.record_opening_balance!(category: @source, amount: 100, family: @family, currency: "USD")
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    BudgetAdjustment.reallocate!(from_category: @source, to_category: @destination, amount: 100, family: @family)
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!

    error = assert_raises(BudgetAdjustment::InvalidReallocation) do
      BudgetAdjustment.reallocate!(from_category: @source, to_category: @destination, amount: 1, family: @family)
    end
    assert_equal :insufficient_reserve, error.reason
  end
end
