require "test_helper"

# Model-level Pocket invariants not already covered by PocketMovementTest
# (which exercises the add_money!/withdraw_money! gesture, not Pocket's own
# validations or its tag-aggregation query). Reference tests for
# docs/mettre-de-cote-recommandation-produit-technique.md, step 1.
class PocketTest < ActiveSupport::TestCase
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
end
