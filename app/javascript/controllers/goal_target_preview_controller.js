import { Controller } from "@hotwired/stimulus"

// Live preview of the months-of-expenses target while a reserve goal is
// still being filled in — server-computed (GoalsController#preview_target),
// never re-derived in JS, so this can't quietly disagree with the real
// figure the save produces.
export default class extends Controller {
  static targets = ["monthsInput", "categoryCheckbox", "uncategorizedCheckbox", "output"]
  static values = {
    url: String,
    currency: String,
    pendingText: String,
  }

  refresh() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.#fetchPreview(), 350)
  }

  disconnect() {
    clearTimeout(this.timeout)
    this.currentRequest?.abort()
  }

  #fetchPreview() {
    const params = new URLSearchParams()
    if (this.hasMonthsInputTarget) params.set("target_months", this.monthsInputTarget.value)
    params.set("currency", this.currencyValue)

    this.categoryCheckboxTargets.forEach((checkbox) => {
      if (checkbox.checked) params.append("expense_category_ids[]", checkbox.value)
    })

    if (this.hasUncategorizedCheckboxTarget && this.uncategorizedCheckboxTarget.checked) {
      params.set("include_uncategorized_expenses", "1")
    }

    // Two requests can be in flight at once (e.g. picking "months of
    // expenses" fires one with no categories checked yet, then checking a
    // category fires a second) and nothing guarantees they resolve in the
    // order they were sent — aborting the previous request keeps only the
    // latest one able to write the output.
    this.currentRequest?.abort()
    const controller = new AbortController()
    this.currentRequest = controller

    fetch(`${this.urlValue}?${params.toString()}`, {
      headers: { Accept: "application/json" },
      signal: controller.signal,
    })
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => {
        if (!this.hasOutputTarget) return
        this.outputTarget.textContent = data?.formatted || this.pendingTextValue
      })
      .catch((error) => {
        if (error.name === "AbortError") return
        if (this.hasOutputTarget) this.outputTarget.textContent = this.pendingTextValue
      })
  }
}
