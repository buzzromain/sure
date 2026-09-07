import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--actions"
export default class extends Controller {
  static values = { actionExecutors: Array };
  static targets = [
    "destroyField",
    "actionValue",
    "selectTemplate",
    "textTemplate",
    "allocateToReserveTemplate",
    "allocateToReserveTargetType",
    "allocateToReserveTargetId",
    "allocateToReserveAmountMode",
    "allocateToReserveAmountValue",
    "allocateToReserveValue",
  ];

  remove(e) {
    e.preventDefault();
    e.stopPropagation();

    if (e.params.destroy) {
      this.destroyFieldTarget.value = true;
      this.element.classList.add("hidden");
    } else {
      this.element.remove();
    }
  }

  handleActionTypeChange(e) {
    const actionExecutor = this.actionExecutorsValue.find(
      (executor) => executor.key === e.target.value,
    );

    // Clear any existing input elements first
    this.#clearFormFields();

    if (actionExecutor.type === "select") {
      this.#buildSelectFor(actionExecutor);
    } else if (actionExecutor.type === "text") {
      this.#buildTextInputFor();
    } else if (actionExecutor.type === "allocate_to_reserve") {
      this.#buildAllocateToReserveFor();
    } else {
      // Hide for any type that doesn't need a value (e.g. function)
      this.#hideActionValue();
    }
  }

  // Bound via data-action on each of the four allocate_to_reserve sub-fields
  // (none of them submit directly -- their combined state is what actually
  // gets submitted, in the hidden allocateToReserveValue field).
  syncAllocateToReserveValue(e) {
    if (e && e.target === this.allocateToReserveTargetTypeTarget) {
      this.#refreshAllocateToReserveTargetOptions();
    }

    this.allocateToReserveValueTarget.value = JSON.stringify({
      target_type: this.allocateToReserveTargetTypeTarget.value,
      target_id: this.allocateToReserveTargetIdTarget.value,
      amount_mode: this.allocateToReserveAmountModeTarget.value,
      amount_value: this.allocateToReserveAmountValueTarget.value,
    });
  }

  #hideActionValue() {
    this.actionValueTarget.classList.add("hidden");
  }

  #clearFormFields() {
    // Remove all children from actionValueTarget
    this.actionValueTarget.innerHTML = "";
  }

  #buildSelectFor(actionExecutor) {
    // Clone the select template
    const template = this.selectTemplateTarget.content.cloneNode(true);
    const selectEl = template.querySelector("select");

    // Add options to the select element
    if (selectEl) {
      selectEl.innerHTML = "";
      if (!actionExecutor.options || actionExecutor.options.length === 0) {
        selectEl.disabled = true;
        const optionEl = document.createElement("option");
        optionEl.textContent = "(none)";
        selectEl.appendChild(optionEl);
      } else {
        selectEl.disabled = false;
        for (const option of actionExecutor.options) {
          const optionEl = document.createElement("option");
          optionEl.value = option[1];
          optionEl.textContent = option[0];
          selectEl.appendChild(optionEl);
        }
      }
    }

    // Add the template content to the actionValue target and ensure it's visible
    this.actionValueTarget.appendChild(template);
    this.actionValueTarget.classList.remove("hidden");
  }

  #buildTextInputFor() {
    // Clone the text template
    const template = this.textTemplateTarget.content.cloneNode(true);

    // Ensure the input is always empty
    const inputEl = template.querySelector("input");
    if (inputEl) inputEl.value = "";

    // Add the template content to the actionValue target and ensure it's visible
    this.actionValueTarget.appendChild(template);
    this.actionValueTarget.classList.remove("hidden");
  }

  #buildAllocateToReserveFor() {
    // Unlike selectTemplate/textTemplate, this one is already fully
    // populated server-side (both target_type and its matching target_id
    // options) -- one action_type, one dedicated template, no need to build
    // options here the way the generic select template does.
    const template =
      this.allocateToReserveTemplateTarget.content.cloneNode(true);

    this.actionValueTarget.appendChild(template);
    this.actionValueTarget.classList.remove("hidden");
    this.syncAllocateToReserveValue();
  }

  #refreshAllocateToReserveTargetOptions() {
    const actionExecutor = this.actionExecutorsValue.find(
      (executor) => executor.key === "allocate_to_reserve",
    );
    if (!actionExecutor) return;

    const targetType = this.allocateToReserveTargetTypeTarget.value;
    const options =
      targetType === "budget_category"
        ? actionExecutor.options.budget_categories
        : actionExecutor.options.pockets;

    const selectEl = this.allocateToReserveTargetIdTarget;
    selectEl.innerHTML = "";
    for (const option of options || []) {
      const optionEl = document.createElement("option");
      optionEl.value = option[1];
      optionEl.textContent = option[0];
      selectEl.appendChild(optionEl);
    }
  }
}
