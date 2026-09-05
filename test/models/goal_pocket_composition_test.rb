require "test_helper"

# Reference invariants for "mettre de côté" (docs/mettre-de-cote-recommandation-produit-technique.md),
# fixed BEFORE any production code changes so the rest of that document's
# implementation plan has a contract to work against.
#
# Two tests here are deliberately RED today — titled "KNOWN GAP" — because they
# assert the target behaviour from the design doc's §5.1, not what the code
# currently does. They exist to be turned green by Step 2 of that plan (a
# shared Account-level reservation view for Pocket + GoalAccount), not to be
# "fixed" by editing the assertion.
class GoalPocketCompositionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  # --- KNOWN GAP (Step 2): Pocket and GoalAccount caps don't see each other ---

  test "KNOWN GAP: a Pocket can still reserve past what a Goal already earmarked on the same account" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared pot",
                               currency: "USD", balance: 1_000)
    goal = Goal.new(family: @family, name: "Taxes", target_amount: 700, currency: "USD")
    goal.goal_accounts.build(account: account, allocated_amount: 700)
    goal.save!

    pocket = account.pockets.build(name: "Emergency", allocated_amount: 500, currency: "USD")

    assert_not pocket.valid?,
      "Pocket#total_pockets_within_account_balance only sums account.pockets — it does not " \
      "see the Goal's 700 already earmarked here, so a 500 Pocket is accepted on an account " \
      "with only 300 actually free. Fix in Step 2 (docs/mettre-de-cote-recommandation-produit-technique.md §5.1: " \
      "\"réserver davantage vérifie la capacité restante commune aux Pockets et aux Goals\")."
  end

  test "KNOWN GAP: Goal#backing_within ignores a composed Pocket's balance" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Pocket-backed reserve",
                               currency: "USD", balance: 900)
    pocket = account.pockets.create!(name: "Sinking fund", allocated_amount: 900, currency: "USD")
    goal = Goal.create!(family: @family, name: "Composed", target_amount: 900, currency: "USD", pocket: pocket)

    assert_equal 900, goal.current_balance, "current_balance does read the composed pocket"
    assert_equal 900, goal.backing_within([ account.id ]),
      "backing_within falls back to linked_accounts, which is empty for a pocket-composed goal " \
      "(no goal_accounts required — see Goal#must_have_at_least_one_linked_account), so it reports 0 " \
      "instead of the pocket's balance. The budget reads backing_within, not current_balance, so this " \
      "understates what a pocket-composed goal already reserves."
  end

  # --- Already-true invariants, fixed here as regression coverage ---

  test "a pocket-composed goal does not double-reserve through a leftover goal_accounts link" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "New home",
                               currency: "USD", balance: 900)
    other_account = Account.create!(family: @family, accountable: Depository.new, name: "Old direct link",
                                     currency: "USD", balance: 500)
    pocket = account.pockets.create!(name: "Composed", allocated_amount: 900, currency: "USD")

    goal = Goal.new(family: @family, name: "Composed with leftovers", target_amount: 900, currency: "USD",
                     pocket: pocket)
    goal.goal_accounts.build(account: other_account, allocated_amount: 500)
    goal.save!

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
end
