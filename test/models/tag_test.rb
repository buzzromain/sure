require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    assert_difference "Tag.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    old_tag.transactions.each do |txn|
      txn.reload
      assert_includes txn.tags, new_tag
      assert_not_includes txn.tags, old_tag
    end
  end

  test "rejects the reserved Untagged filter sentinel as a name" do
    tag = families(:dylan_family).tags.new(name: Tag::UNTAGGED_FILTER_VALUE, color: "#e99537")

    assert_not tag.valid?
    assert_includes tag.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic Untagged tag and the name for real tags" do
    assert_equal Tag::UNTAGGED_FILTER_VALUE, Tag.untagged.filter_value
    assert_equal tags(:one).name, tags(:one).filter_value
  end

  test "destroying a tag a Pocket auto-fills from releases the pocket instead of raising" do
    family = families(:empty)
    account = Account.create!(family: family, accountable: Depository.new, name: "Checking",
                               currency: "USD", balance: 1_000)
    pocket = account.pockets.create!(name: "Groceries", allocated_amount: 0, currency: "USD",
                                      link_new_tag: true, fill_direction: "outflows")
    tag = pocket.tag

    tag.destroy!

    assert_nil pocket.reload.tag_id
    assert_equal 0, pocket.allocated_amount
    assert_not Tag.exists?(tag.id)
  end
end
