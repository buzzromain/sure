require "application_system_test_case"

class BudgetCategoryAdjustmentsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @budget = budgets(:one)

    @category = @family.categories.create!(name: "Emergency fund #{Time.now.to_f}", color: "#4da568", lucide_icon: "shield")
    @other_category = @family.categories.create!(name: "Car repairs #{Time.now.to_f}", color: "#6172F3", lucide_icon: "car")

    @budget_category = BudgetCategory.create!(budget: @budget, category: @category, budgeted_spending: 0, currency: @budget.currency)
    @other_budget_category = BudgetCategory.create!(budget: @budget, category: @other_category, budgeted_spending: 0, currency: @budget.currency)

    sign_in @user
  end

  test "recording an opening balance and moving reserve between envelopes" do
    visit budget_budget_categories_path(@budget)

    row_selector = "##{ActionView::RecordIdentifier.dom_id(@budget_category, :form)}"
    other_row_selector = "##{ActionView::RecordIdentifier.dom_id(@other_budget_category, :form)}"

    within(row_selector) { find("[aria-label='#{I18n.t('budget_categories.opening_balance.button_title')}']").click }

    within "dialog", visible: true do
      fill_in I18n.t("budget_categories.opening_balance.amount_label"), with: "200"
      click_on I18n.t("budget_categories.opening_balance.submit")
    end

    # assert_selector polls until the turbo-stream replace has actually
    # landed -- a plain find(...).has_text?(...) resolves the element once
    # the id exists (true immediately, replace keeps the id) and does not
    # reliably wait for the fresh content to land inside it.
    assert_selector row_selector, text: "200"

    within(row_selector) { find("[aria-label='#{I18n.t('budget_categories.move_reserve.button_title')}']").click }

    within "dialog", visible: true do
      fill_in I18n.t("budget_categories.move_reserve.amount_label"), with: "80"
      select @other_category.display_name, from: I18n.t("budget_categories.move_reserve.to_label")
      click_on I18n.t("budget_categories.move_reserve.submit")
    end

    assert_selector row_selector, text: "120"
    assert_selector other_row_selector, text: "80"

    assert_equal 120, @budget_category.reload[:adjustments_balance].to_i
    assert_equal 80, @other_budget_category.reload[:adjustments_balance].to_i
  end
end
