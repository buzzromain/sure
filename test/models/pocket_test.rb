require "test_helper"

# Model-level Pocket invariants not already covered by PocketMovementTest
# (which exercises the add_money!/withdraw_money! gesture, not Pocket's own
# validations or its tag-aggregation query). Reference tests for
# docs/mettre-de-cote-recommandation-produit-technique.md, step 1.
class PocketTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "a Pocket that alone would exceed the account balance is invalid" do
    account = Account.create!(family: families(:dylan_family), accountable: Depository.new,
                               name: "Tight budget", currency: "USD", balance: 300)

    pocket = account.pockets.build(name: "Too much", allocated_amount: 400, currency: "USD")

    assert_not pocket.valid?
    assert pocket.errors.of_kind?(:allocated_amount, :exceeds_account_balance)
  end

  test "tag-fill aggregation cannot cross family lines even when two families use the same tag name" do
    dylan = families(:dylan_family)
    empty = families(:empty)

    dylan_account = Account.create!(family: dylan, accountable: Depository.new, name: "Dylan groceries",
                                     currency: "USD", balance: 1_000)
    empty_account = Account.create!(family: empty, accountable: Depository.new, name: "Empty groceries",
                                     currency: "USD", balance: 1_000)

    dylan_pocket = dylan_account.pockets.create!(name: "Groceries", allocated_amount: 0, currency: "USD",
                                                  link_new_tag: true, fill_direction: "outflows")
    empty_tag = empty.tags.create!(name: "pockets:Groceries", color: Tag::COLORS.first)

    # Same tag NAME, different family, different tag row entirely.
    assert_equal "pockets:Groceries", dylan_pocket.tag.name
    assert_not_equal dylan_pocket.tag_id, empty_tag.id

    empty_entry = Entry.create!(account: empty_account, name: "Empty family groceries", date: Date.current,
                                 amount: 250, currency: "USD", entryable: Transaction.new)
    empty_entry.entryable.tags << empty_tag

    assert_equal 0, dylan_pocket.reload.allocated_amount,
      "a same-named tag in a different family must not fill this pocket"
  end

  # --- convert_to_envelope! (Étape 6, Lot 3) ---

  test "converting a bare pocket with a positive balance records an opening balance and destroys the pocket" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    category = family.categories.create!(name: "Vacations", color: "#6172F3")
    pocket = account.pockets.create!(name: "Trip", allocated_amount: 300, currency: "USD")

    pocket.convert_to_envelope!(category: category)

    adjustment = BudgetAdjustment.find_by!(category: category, kind: "opening_balance")
    assert_equal 300, adjustment.amount
    assert_equal "USD", adjustment.currency
    assert_not Pocket.exists?(name: "Trip")
  end

  test "converting a pocket at a zero balance records no opening balance but still destroys the pocket" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    category = family.categories.create!(name: "Vacations", color: "#6172F3")
    pocket = account.pockets.create!(name: "Empty trip", allocated_amount: 0, currency: "USD")

    assert_no_difference "BudgetAdjustment.count" do
      pocket.convert_to_envelope!(category: category)
    end

    assert_not Pocket.exists?(name: "Empty trip")
  end

  test "converting a pocket with a linked goal re-points the goal at the category instead" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    category = family.categories.create!(name: "Vacations", color: "#6172F3")
    pocket = account.pockets.create!(name: "Trip", allocated_amount: 300, currency: "USD")
    goal = pocket.build_goal(name: "Trip goal", target_amount: 500, currency: "USD", family: family)
    goal.save!

    pocket.convert_to_envelope!(category: category)

    reloaded_goal = Goal.find(goal.id)
    assert_nil reloaded_goal.pocket_id
    assert_equal category.id, reloaded_goal.funding_category_id

    # current_balance for a funding_category-linked goal never bootstraps a
    # Budget on its own (see GoalPocketCompositionTest) -- the current
    # month's household budget has to exist and be initialized (RolloverCalculator
    # only walks budgets with a non-nil budgeted_spending) before the adjustment
    # materializes into adjustments_balance.
    budget = Budget.find_or_bootstrap(family, start_date: Date.current)
    budget.update!(budgeted_spending: 1_000, expected_income: 2_000)
    Budget::RolloverCalculator.new(family: family, user: nil).recompute!
    assert_equal 300, reloaded_goal.reload.current_balance
  end

  test "converting into a category that already funds another goal rolls back and leaves the pocket intact" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    category = family.categories.create!(name: "Vacations", color: "#6172F3")
    family.goals.create!(name: "Existing envelope goal", target_amount: 500, currency: "USD",
                          funding_category: category)
    pocket = account.pockets.create!(name: "Trip", allocated_amount: 300, currency: "USD")
    goal = pocket.build_goal(name: "Trip goal", target_amount: 500, currency: "USD", family: family)
    goal.save!

    assert_raises(ActiveRecord::RecordInvalid) { pocket.convert_to_envelope!(category: category) }

    assert Pocket.exists?(name: "Trip"), "the whole conversion must roll back, not leave the pocket destroyed"
    assert_equal 300, Pocket.find_by!(name: "Trip").allocated_amount
    assert_equal 0, BudgetAdjustment.where(category: category, kind: "opening_balance").count
  end

  test "converting into a category from a different family is refused" do
    family = families(:empty)
    other_family = families(:dylan_family)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    other_category = other_family.categories.create!(name: "Not mine", color: "#6172F3")
    pocket = account.pockets.create!(name: "Trip", allocated_amount: 300, currency: "USD")

    error = assert_raises(Pocket::ConversionRefused) { pocket.convert_to_envelope!(category: other_category) }
    assert_equal :different_families, error.reason
  end

  # --- Reservation review fixes (PR #2892) ---

  test "a tagged split parent does not double-count alongside its own tagged child" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Savings", allocated_amount: 0, currency: "USD",
                                      link_new_tag: true, fill_direction: "inflows")

    entry = create_transaction(account: account, name: "Paycheck", amount: -100, currency: "USD")
    entry.entryable.tags << pocket.tag

    children = entry.split!([
      { name: "Salary", amount: -70, category_id: nil },
      { name: "Bonus", amount: -30, category_id: nil }
    ])
    children.first.entryable.tags << pocket.tag

    assert_equal 70, pocket.reload.allocated_amount,
      "the split parent is excluded once it has children -- only the tagged child (70) should credit " \
      "the pocket, not the parent's full amount plus the child's (170)"
  end

  test "an account drifting into overflow after the fact no longer blocks editing an untouched pocket" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Shared",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Side", allocated_amount: 400, currency: "USD")

    # Nothing stops a Goal from earmarking on top of an existing Pocket --
    # only Pocket's own validation checks Account#reserved_total today. This
    # goal alone pushes the account's total reservations (400 + 700) past its
    # 1,000 balance, without touching the pocket itself.
    goal = Goal.new(family: family, name: "Big goal", target_amount: 700, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 700)
    goal.save!

    pocket.name = "Side (renamed)"
    assert pocket.save, pocket.errors.full_messages.to_sentence
  end

  test "a pocket already over what its account has free can still shrink back toward room" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Shared",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Side", allocated_amount: 400, currency: "USD")

    goal = Goal.new(family: family, name: "Big goal", target_amount: 700, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 700)
    goal.save!

    pocket.allocated_amount = 250
    assert pocket.save, pocket.errors.full_messages.to_sentence
  end

  test "growing an already-overflowing pocket's allocated_amount is still refused" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Shared",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Side", allocated_amount: 400, currency: "USD")

    goal = Goal.new(family: family, name: "Big goal", target_amount: 700, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 700)
    goal.save!

    pocket.allocated_amount = 500
    assert_not pocket.save
    assert pocket.errors.of_kind?(:allocated_amount, :exceeds_account_balance)
  end
end
