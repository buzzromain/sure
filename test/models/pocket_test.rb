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
