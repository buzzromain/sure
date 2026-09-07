require "test_helper"

class PocketsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
    @account = @family.accounts.create!(accountable: Depository.new, name: "Shared Checking",
                                         currency: @family.currency, balance: 5_000, owner: @user)
    @pocket = @account.pockets.create!(name: "Groceries", allocated_amount: 500, currency: @account.currency)
  end

  test "new renders the form without crashing" do
    get new_account_pocket_path(@account)
    assert_response :success
  end

  test "edit renders the form without crashing" do
    get edit_account_pocket_path(@account, @pocket)
    assert_response :success
  end

  test "move renders the dialog" do
    get move_account_pocket_path(@account, @pocket)
    assert_response :success
  end

  test "create_movement with direction add increases the balance" do
    post move_account_pocket_path(@account, @pocket), params: { direction: "add", pocket_movement: { amount: "100" } }

    assert_redirected_to account_path(@account, tab: :pockets)
    assert_equal 600, @pocket.reload.allocated_amount
  end

  test "create_movement with direction withdraw decreases the balance" do
    post move_account_pocket_path(@account, @pocket), params: { direction: "withdraw", pocket_movement: { amount: "200" } }

    assert_redirected_to account_path(@account, tab: :pockets)
    assert_equal 300, @pocket.reload.allocated_amount
  end

  test "withdrawing more than the pocket holds is refused with a readable message" do
    post move_account_pocket_path(@account, @pocket), params: { direction: "withdraw", pocket_movement: { amount: "9999" } }

    assert_redirected_to account_path(@account, tab: :pockets)
    assert_equal I18n.t("pockets.move.errors.exceeds_balance"), flash[:alert]
    assert_equal 500, @pocket.reload.allocated_amount
  end

  test "a member without manage access cannot move money" do
    sign_in users(:family_member)

    post move_account_pocket_path(@account, @pocket), params: { direction: "add", pocket_movement: { amount: "50" } }

    assert_equal 500, @pocket.reload.allocated_amount
  end

  test "convert_to_envelope renders the dialog" do
    get convert_to_envelope_account_pocket_path(@account, @pocket)
    assert_response :success
  end

  test "create_envelope_conversion records an opening balance and removes the pocket" do
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")

    post convert_to_envelope_account_pocket_path(@account, @pocket), params: { category_id: category.id }

    assert_redirected_to account_path(@account, tab: :pockets)
    assert_not Pocket.exists?(@pocket.id)
    adjustment = BudgetAdjustment.find_by(category: category, kind: "opening_balance")
    assert_not_nil adjustment
    assert_equal 500, adjustment.amount
  end

  # Simulates the race must_have_exactly_one_funding_source can't catch: two
  # concurrent conversions onto the same category both pass validation
  # before either commits. Stubbed directly rather than constructed via real
  # concurrency -- see the model-level DB test in pocket_test.rb for proof
  # the unique index itself refuses the second row.
  test "converting into a category already funding another goal re-renders the form instead of raising" do
    # The race only bites when this pocket has a linked goal -- a bare
    # pocket's conversion never touches Goal at all, so nothing collides
    # with the unique funding_category_id index.
    linked_goal = @pocket.build_goal(name: "Groceries goal", target_amount: 800, currency: @family.currency,
                                      family: @family)
    linked_goal.save!
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")
    @family.goals.create!(name: "Existing envelope goal", target_amount: 500, currency: @family.currency,
                           funding_category: category)

    post convert_to_envelope_account_pocket_path(@account, @pocket), params: { category_id: category.id }

    assert_response :unprocessable_entity
    assert Pocket.exists?(@pocket.id), "the pocket must survive a rolled-back conversion"
  end

  test "a member without manage access cannot convert a pocket" do
    sign_in users(:family_member)
    category = @family.categories.create!(name: "Vacations", color: "#6172F3")

    post convert_to_envelope_account_pocket_path(@account, @pocket), params: { category_id: category.id }

    assert Pocket.exists?(@pocket.id)
  end
end
