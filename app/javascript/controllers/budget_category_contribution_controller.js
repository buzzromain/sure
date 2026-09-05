import { Controller } from "@hotwired/stimulus"

// A fixed contribution IS the period's allocation (see
// BudgetCategoriesController#update), so only one of the two amount fields
// makes sense to show at a time. Disabled rather than just hidden, same
// reasoning as goal_kind_controller: a disabled field isn't submitted, so
// switching modes never carries a stale value from the field the user can no
// longer see.
export default class extends Controller {
  static targets = ["modeSelect", "amountField", "budgetedField"]

  connect() {
    this.refresh()
  }

  refresh() {
    const fixed = this.modeSelectTarget.value === "fixed"

    this.#toggle(this.amountFieldTarget, fixed)
    this.#toggle(this.budgetedFieldTarget, !fixed)
  }

  #toggle(field, show) {
    field.classList.toggle("hidden", !show)
    field.querySelectorAll("input").forEach((input) => { input.disabled = !show })
  }
}
