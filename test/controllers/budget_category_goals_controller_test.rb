require "test_helper"

class BudgetCategoryGoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)

    @budget = budgets(:one)
    @family = @budget.family
    @category = @family.categories.create!(name: "Insurance controller test #{Time.now.to_f}", color: "#6172F3")
    @budget_category = BudgetCategory.create!(budget: @budget, category: @category, budgeted_spending: 100,
                                               currency: "USD")
  end

  test "new renders the form" do
    get new_budget_budget_category_goal_path(@budget, @budget_category)

    assert_response :success
  end

  test "create with valid params links a goal to the category and redirects to it" do
    assert_difference "Goal.count", 1 do
      post budget_budget_category_goal_path(@budget, @budget_category), params: {
        goal: {
          name: "Annual insurance",
          target_amount: "1200",
          kind: "one_off"
        }
      }
    end

    goal = Goal.order(:created_at).last
    assert_equal @category, goal.funding_category
    assert_redirected_to goal_path(goal)
  end

  test "create with invalid params re-renders the form" do
    assert_no_difference "Goal.count" do
      post budget_budget_category_goal_path(@budget, @budget_category), params: {
        goal: { name: "", target_amount: "1200", kind: "one_off" }
      }
    end

    assert_response :unprocessable_entity
  end

  # Simulates the race the uniqueness *validation* can't catch: two
  # concurrent "Add a goal" submissions on the same envelope both pass Rails
  # validation before either commits, so the second one's actual failure
  # arrives as a bare RecordNotUnique from the unique index, not a populated
  # @goal.errors. Stubbed directly rather than constructed via real
  # concurrency -- see the model-level DB test for proof the constraint
  # itself works; this proves the controller doesn't 500 when it fires.
  test "a duplicate funding_category race re-renders the form instead of raising" do
    Goal.any_instance.stubs(:save!).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    assert_no_difference "Goal.count" do
      post budget_budget_category_goal_path(@budget, @budget_category), params: {
        goal: { name: "Annual insurance", target_amount: "1200", kind: "one_off" }
      }
    end

    assert_response :unprocessable_entity
  end
end
