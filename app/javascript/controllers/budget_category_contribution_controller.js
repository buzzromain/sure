import { Controller } from "@hotwired/stimulus"

// A fixed or complete_to contribution IS the period's allocation (see
// BudgetCategoriesController#update), so the manually-entered amount field
// only makes sense for `fixed`. Hidden fields are disabled too, same
// reasoning as goal_kind_controller: a disabled field isn't submitted, so
// switching modes never carries a stale value from a field the user can no
// longer see. `budgetedField` stays visible but disabled for `complete_to`,
// rather than hidden -- there's still a real number to show (what this
// period ended up funded at), the user just can't type over it, since the
// server derives it from the linked goal's target.
export default class extends Controller {
  static targets = ["modeSelect", "amountField", "budgetedField"]

  connect() {
    this.refresh()
  }

  refresh() {
    const mode = this.modeSelectTarget.value
    const fixed = mode === "fixed"

    this.#toggle(this.amountFieldTarget, fixed)
    this.#toggle(this.budgetedFieldTarget, !fixed)

    if (!fixed) {
      this.budgetedFieldTarget.querySelectorAll("input").forEach((input) => {
        input.disabled = mode === "complete_to"
      })
    }
  }

  #toggle(field, show) {
    field.classList.toggle("hidden", !show)
    field.querySelectorAll("input").forEach((input) => { input.disabled = !show })
  }
}
