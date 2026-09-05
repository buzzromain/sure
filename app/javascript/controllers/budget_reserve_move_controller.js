import { Controller } from "@hotwired/stimulus"

// Reserve equivalent of budget_move_controller: drives the single reserve
// dialog shared by every category row, filling in the source and refreshing
// which destinations the server would actually accept. See that controller
// for the full reasoning -- this is the same shape applied to
// adjustments_balance instead of budgeted_spending.
export default class extends Controller {
  static targets = [
    "dialog",
    "fromId",
    "fromName",
    "available",
    "toSelect",
    "amount",
    "submit",
    "noDestination",
  ]

  open({ params }) {
    this.fromIdTarget.value = params.fromId
    this.fromNameTarget.textContent = params.fromName
    this.availableTarget.textContent = params.available
    this.amountTarget.value = ""

    this.#refreshOptions(String(params.fromId), String(params.categoryId), String(params.parentId || ""))
    this.dialogTarget.showModal()
    this.amountTarget.focus()
  }

  close() {
    this.#dialogController()?.close() ?? this.dialogTarget.close()
  }

  submitEnd(event) {
    if (event.detail?.success) this.close()
  }

  #refreshOptions(fromId, categoryId, parentId) {
    let firstEnabled = null

    for (const option of this.toSelectTarget.options) {
      const optionCategoryId = option.dataset.categoryId
      const optionParentId = option.dataset.parentId || ""

      option.disabled =
        option.value === fromId ||
        optionCategoryId === parentId ||
        optionParentId === categoryId

      if (!option.disabled && firstEnabled === null) firstEnabled = option
    }

    if (firstEnabled) this.toSelectTarget.value = firstEnabled.value

    const hasDestination = firstEnabled !== null
    this.submitTarget.disabled = !hasDestination
    this.toSelectTarget.disabled = !hasDestination
    this.amountTarget.disabled = !hasDestination
    this.noDestinationTarget.classList.toggle("hidden", hasDestination)
  }

  #dialogController() {
    return this.application.getControllerForElementAndIdentifier(this.dialogTarget, "DS--dialog")
  }
}
