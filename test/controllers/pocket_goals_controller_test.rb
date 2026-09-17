require "test_helper"

class PocketGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
    @account = @family.accounts.create!(accountable: Depository.new, name: "Shared Checking",
                                         currency: @family.currency, balance: 5_000, owner: @user)
    @pocket = @account.pockets.create!(name: "Groceries", allocated_amount: 500, currency: @account.currency)
  end

  test "new renders the dialog for a pocket with no goal yet" do
    get new_pocket_goal_url(@pocket)
    assert_response :success
  end

  test "create links a goal to the pocket" do
    assert_difference "Goal.count", 1 do
      post pocket_goal_url(@pocket), params: { goal: { name: "Trip", target_amount: "500" } }
    end

    assert_equal @pocket.reload.goal, Goal.find_by!(name: "Trip")
    assert_redirected_to goal_path(@pocket.goal)
  end

  # Regression: #new used to call Pocket#build_goal unconditionally, which on
  # a has_one already pointing at a persisted goal tries to null out that
  # goal's pocket_id and blows up against must_have_exactly_one_funding_source
  # -- an unrescued ActiveRecord::RecordNotSaved (500), not a redirect.
  test "new redirects to the existing goal instead of crashing when the pocket already has one" do
    existing_goal = @pocket.build_goal(name: "Already there", target_amount: 100, currency: "USD",
                                        family: @family)
    existing_goal.save!

    get new_pocket_goal_url(@pocket)

    assert_redirected_to goal_path(existing_goal)
  end

  test "create redirects to the existing goal instead of crashing when the pocket already has one" do
    existing_goal = @pocket.build_goal(name: "Already there", target_amount: 100, currency: "USD",
                                        family: @family)
    existing_goal.save!

    assert_no_difference "Goal.count" do
      post pocket_goal_url(@pocket), params: { goal: { name: "Second one", target_amount: "500" } }
    end

    assert_redirected_to goal_path(existing_goal)
  end
end
