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
end
