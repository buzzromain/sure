require "test_helper"

# Reference invariants for "mettre de côté" (docs/mettre-de-cote-recommandation-produit-technique.md).
# The first two tests below were introduced in Step 1 as deliberately red
# "KNOWN GAP" tests; Step 2 (shared Account#reserved_total for Pocket +
# GoalAccount, and a pocket-aware Goal#backing_within) turned them green —
# the assertions are unchanged, only the framing is, since they already
# described the target behaviour.
class GoalPocketCompositionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  # --- Pocket and GoalAccount share one reservation total (Account#reserved_total) ---

  test "a Pocket cannot reserve past what a Goal already earmarked on the same account" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared pot",
                               currency: "USD", balance: 1_000)
    goal = Goal.new(family: @family, name: "Taxes", target_amount: 700, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 700)
    goal.save!

    pocket = account.pockets.build(name: "Emergency", allocated_amount: 500, currency: "USD")

    assert_not pocket.valid?,
      "only 300 is actually free after the Goal's 700 earmark on this account"
    assert pocket.errors.of_kind?(:allocated_amount, :exceeds_account_balance)
  end

  test "Goal#backing_within reads a composed Pocket's balance" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Pocket-backed reserve",
                               currency: "USD", balance: 900)
    pocket = account.pockets.create!(name: "Sinking fund", allocated_amount: 900, currency: "USD")
    goal = Goal.create!(family: @family, name: "Composed", target_amount: 900, currency: "USD", pocket: pocket)

    assert_equal 900, goal.current_balance
    assert_equal 900, goal.backing_within([ account.id ]),
      "the budget reads backing_within, not current_balance, to know what a goal already reserves"
    assert_equal 0, goal.backing_within([ Account.create!(family: @family, accountable: Depository.new,
                                                            name: "Unrelated", currency: "USD",
                                                            balance: 0).id ]),
      "a pocket-composed goal backs only the account its pocket actually lives on"
  end

  # --- Already-true invariants, fixed here as regression coverage ---

  test "a pocket-composed goal does not double-reserve through a leftover goal_accounts link" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "New home",
                               currency: "USD", balance: 900)
    other_account = Account.create!(family: @family, accountable: Depository.new, name: "Old direct link",
                                     currency: "USD", balance: 500)
    pocket = account.pockets.create!(name: "Composed", allocated_amount: 900, currency: "USD")

    goal = Goal.create!(family: @family, name: "Composed with leftovers", target_amount: 900, currency: "USD",
                         pocket: pocket)
    # Simulates a leftover row from before must_have_exactly_one_funding_source
    # existed (or direct data manipulation) — created directly on the join
    # model so it bypasses Goal's own validation, which now refuses to save a
    # goal in this state going forward.
    GoalAccount.create!(goal: goal, account: other_account, allocated_amount: 500)

    assert_equal 900, Goal.find(goal.id).current_balance,
      "current_balance must read the pocket only, not the pocket PLUS a stale goal_accounts link"
  end

  test "a virtual allocation never modifies the account's real balance" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Balance guard",
                               currency: "USD", balance: 1_000)

    pocket = account.pockets.create!(name: "Side", allocated_amount: 200, currency: "USD")
    pocket.add_money!(100)
    assert_equal 1_000, account.reload.balance
    pocket.withdraw_money!(50)
    assert_equal 1_000, account.reload.balance

    goal = Goal.new(family: @family, name: "Direct", target_amount: 500, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 500)
    goal.save!
    entry = create_transaction(account: account, amount: 100, currency: "USD")
    goal.consume!(100, transaction: entry.entryable)
    assert_equal 1_000, account.reload.balance
  end

  test "target_amount is neither a bank balance nor a cap on how much a goal can hold" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Overfunded",
                               currency: "USD", balance: 2_000)
    goal = Goal.new(family: @family, name: "Overfunded goal", target_amount: 100, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 500)
    goal.save!

    reloaded = Goal.find(goal.id)
    assert_equal 500, reloaded.current_balance
    assert_equal 0, reloaded.remaining_amount, "already past target, nothing further to find"
  end

  # --- "assurance annuelle déjà financée" scenario (maintained goal) ---

  test "a maintained goal's reserve shrinks when the account it backs actually pays out, without consume!" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Insurance reserve",
                               currency: "USD", balance: 1_200)
    goal = Goal.new(family: @family, name: "Home insurance", kind: "maintained", target_amount: 1_200,
                     currency: "USD")
    goal.goal_accounts.build(account: account) # whole-account link: tracks the account balance directly
    goal.save!

    fresh = Goal.find(goal.id)
    assert_equal 1_200, fresh.current_balance
    assert_equal 0, fresh.remaining_amount
    assert_equal :funded, fresh.status

    # The premium is paid: the money actually leaves the account.
    account.update!(balance: 0)

    after_payment = Goal.find(goal.id)
    assert_equal 0, after_payment.current_balance
    assert_equal 1_200, after_payment.remaining_amount,
      "the reserve needs reconstituting for next year, not a re-financed premium in the same month"
    assert_equal :depleted, after_payment.status

    # consume! is refused outright for a maintained goal: this is balance
    # tracking, not a spend to record against a target.
    assert_raises(Goal::ConsumptionRefused) { after_payment.consume!(1_200) }
  end

  # --- A goal linked to a budget category's rollover envelope (funding_category) ---

  test "a goal linked to a funding_category reads the current month's envelope balance" do
    family = families(:empty)
    category = family.categories.create!(name: "Insurance", color: "#6172F3")

    budget = Budget.find_or_bootstrap(family, start_date: Date.current)
    budget.update!(budgeted_spending: 3_000, expected_income: 5_000)
    bc = budget.budget_categories.find_by!(category: category)
    bc.update!(budgeted_spending: 100, rollover_enabled: true)
    bc.update_column(:rolled_over_amount, 200)

    goal = Goal.new(family: family, name: "Annual insurance", target_amount: 1_200, currency: "USD",
                     funding_category: category)
    goal.save!

    assert_equal 300, Goal.find(goal.id).current_balance, "100 budgeted + 200 carried, nothing spent yet"
  end

  test "reading a funding_category-linked goal's balance never bootstraps a Budget" do
    family = families(:empty)
    category = family.categories.create!(name: "Insurance", color: "#6172F3")

    goal = Goal.new(family: family, name: "Annual insurance", target_amount: 1_200, currency: "USD",
                     funding_category: category)
    goal.save!

    assert_no_difference [ "Budget.count", "BudgetCategory.count" ] do
      assert_equal 0, Goal.find(goal.id).current_balance,
        "no Budget exists for this month yet, so the envelope reads as empty rather than bootstrapping one"
    end
  end

  test "a funding_category-linked goal backs no account" do
    family = families(:empty)
    category = family.categories.create!(name: "Insurance", color: "#6172F3")
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    goal = Goal.new(family: family, name: "Annual insurance", target_amount: 1_200, currency: "USD",
                     funding_category: category)
    goal.save!

    assert_equal 0, goal.backing_within([ account.id ]),
      "a budget envelope isn't held in any one account, by design"
  end

  # `validates :funding_category_id, uniqueness: true` only catches this at
  # the Rails layer -- two concurrent requests can both pass it before either
  # commits. Bypassing validation here is how the test forces the real
  # backstop, the unique index, to be what actually refuses the second row.
  test "the DB itself refuses two goals funded by the same category" do
    family = families(:empty)
    category = family.categories.create!(name: "Insurance", color: "#6172F3")
    family.goals.create!(name: "First", target_amount: 1_200, currency: "USD", funding_category: category)

    dupe = family.goals.new(name: "Second", target_amount: 500, currency: "USD", funding_category: category)

    assert_raises(ActiveRecord::RecordNotUnique) { dupe.save!(validate: false) }
  end

  test "combining a pocket and a funding_category on the same goal is refused" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Side", allocated_amount: 500, currency: "USD")

    goal = Goal.new(family: @family, name: "Two sources", target_amount: 500, currency: "USD",
                     pocket: pocket, funding_category: categories(:food_and_drink))

    assert_not goal.valid?
    assert goal.errors.of_kind?(:base, :funding_source_must_be_exclusive)
  end

  test "combining a pocket and goal_accounts on the same goal is refused (preexisting gap, closed here)" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Side", allocated_amount: 500, currency: "USD")

    goal = Goal.new(family: @family, name: "Two sources", target_amount: 500, currency: "USD", pocket: pocket)
    goal.goal_accounts.build(account: account, allocated_amount: 200)

    assert_not goal.valid?
    assert goal.errors.of_kind?(:base, :funding_source_must_be_exclusive)
  end

  test "a funding_category in a different currency than the goal is refused" do
    goal = Goal.new(family: @family, name: "Mismatched currency", target_amount: 500, currency: "EUR",
                     funding_category: categories(:food_and_drink))

    assert_not goal.valid?
    assert goal.errors.of_kind?(:funding_category, :currency_mismatch)
  end

  test "consume! is refused for a funding_category-linked goal, same as for a pocket-composed one" do
    family = families(:empty)
    category = family.categories.create!(name: "Insurance", color: "#6172F3")
    goal = Goal.new(family: family, name: "Annual insurance", target_amount: 1_200, currency: "USD",
                     funding_category: category)
    goal.save!

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(50) }
    assert_equal :no_linked_account, error.reason
  end
end
