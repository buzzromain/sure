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

  test "create with a target amount creates the pocket and a one_off goal atomically" do
    assert_difference [ "Pocket.count", "Goal.count" ], 1 do
      post account_pockets_path(@account), params: {
        pocket: { name: "Trip", allocated_amount: "100", target_amount: "500" }
      }
    end

    pocket = Pocket.find_by!(name: "Trip")
    goal = pocket.goal
    assert_not_nil goal
    assert_equal "one_off", goal.kind
    assert_equal 500, goal.target_amount
    assert_nil goal.target_date
  end

  test "create with a blank target amount creates only the pocket" do
    assert_difference "Pocket.count", 1 do
      assert_no_difference "Goal.count" do
        post account_pockets_path(@account), params: {
          pocket: { name: "Trip", allocated_amount: "100", target_amount: "" }
        }
      end
    end
  end

  test "an invalid pocket with a target amount rolls back before the goal is ever attempted" do
    assert_no_difference [ "Pocket.count", "Goal.count" ] do
      post account_pockets_path(@account), params: {
        pocket: { name: "", allocated_amount: "100", target_amount: "500" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a negative or zero target amount is treated as no target, not an error" do
    assert_difference "Pocket.count", 1 do
      assert_no_difference "Goal.count" do
        post account_pockets_path(@account), params: {
          pocket: { name: "Trip", allocated_amount: "100", target_amount: "-50" }
        }
      end
    end
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
