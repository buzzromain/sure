class Rule::ActionExecutor
  TYPES = [ "select", "function", "text", "allocate_to_reserve" ]

  def initialize(rule)
    @rule = rule
  end

  def key
    self.class.name.demodulize.underscore
  end

  def label
    key.humanize
  end

  def type
    "function"
  end

  def options
    nil
  end

  def execute(scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    raise NotImplementedError, "Action executor #{self.class.name} must implement #execute"
  end

  # Default: assumes options is a flat [label, value] pair list, same
  # behavior Rule::Action#value_display always had before this became
  # overridable. An executor whose options/value don't fit that shape (e.g.
  # AllocateToReserve, whose value is a JSON blob and whose options is two
  # separate lists) overrides this instead of forcing its shape through here.
  def value_display(value)
    return "" if value.blank?
    return "" unless options

    options.find { |option| option.last == value }&.first || ""
  end

  def as_json
    {
      type: type,
      key: key,
      label: label,
      options: options
    }
  end

  protected
    # Helper method to track modified count during enrichment
    # The block should return true if the resource was modified, false otherwise
    # If the block doesn't return a value, we'll check previous_changes as a fallback
    def count_modified_resources(scope)
      modified_count = 0
      scope.each do |resource|
        # Yield the resource and capture the return value if the block returns one
        block_result = yield resource

        # If the block explicitly returned a boolean, use that
        if block_result == true || block_result == false
          was_modified = block_result
        else
          # Otherwise, check previous_changes as fallback
          was_modified = resource.previous_changes.any?

          # For Transaction resources, check the entry if the transaction itself wasn't modified
          if !was_modified && resource.respond_to?(:entry)
            entry = resource.entry
            was_modified = entry&.previous_changes&.any? || false
          end
        end

        modified_count += 1 if was_modified
      end
      modified_count
    end

  private
    attr_reader :rule

    def family
      rule.family
    end
end
