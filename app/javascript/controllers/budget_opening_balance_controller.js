import { Controller } from "@hotwired/stimulus"

// Drives the single "record an opening balance" dialog shared by every
// category row. No destination to filter -- unlike the move dialogs, this
// only ever credits the row that opened it -- so there is nothing here
// budget_move_controller's #refreshOptions has that this needs.
export default class extends Controller {
  static targets = ["dialog", "categoryId", "categoryName", "amount", "note", "submit"]

  open({ params }) {
    this.categoryIdTarget.value = params.categoryId
    this.categoryNameTarget.textContent = params.categoryName
    this.amountTarget.value = ""
    this.noteTarget.value = ""

    this.dialogTarget.showModal()
    this.amountTarget.focus()
  }

  close() {
    this.#dialogController()?.close() ?? this.dialogTarget.close()
  }

  submitEnd(event) {
    if (event.detail?.success) this.close()
  }

  #dialogController() {
    return this.application.getControllerForElementAndIdentifier(this.dialogTarget, "DS--dialog")
  }
}
