# Materializes BudgetCategory#rolled_over_amount for a single budget chain:
# either a family's household budgets (user nil) or one member's personal
# budgets. Chains never mix — a personal budget only ever inherits from the
# same user's earlier personal budgets.
#
# The amount rolled into month n depends on month n-1, which depends on
# n-2. Computed lazily it would walk the whole chain on every budget render,
# so it is stored instead and recomputed in one forward pass whenever a
# budget is bootstrapped or an allocation changes.
class Budget::RolloverCalculator
  # Arbitrary namespace so the advisory lock below cannot collide with any
  # other pg_advisory_lock user in the application.
  LOCK_NAMESPACE = 1_920_231_276

  # Step 6 of docs/mettre-de-cote-recommandation-produit-technique.md: the
  # unclamped ("signed") leftover_for below replaced an earlier version that
  # floored every carry at zero ("positive_only") — but the floored version
  # already shipped to self-hosted instances tracking main/edge and the
  # v0.7.4-alpha/rc tags. rolled_over_amount is a materialized column
  # recomputed lazily for the WHOLE chain back to the first month rollover
  # was ever enabled (see first_relevant_budget_date/chain below), so
  # recomputing an existing chain under the signed formula would silently
  # reinterpret every historical floored-at-zero month as a carried deficit
  # the moment anything (an edited transaction, a new allocation) next
  # triggered a recompute — inventing overspend history that was never
  # actually tracked as debt. Periods ending before this date keep the old
  # floored behavior; only periods from here on get a genuine signed carry.
  # Bump forward if this lot's merge slips past the date below.
  SIGNED_CARRY_SINCE = Date.new(2026, 10, 1)

  def initialize(family:, user:)
    @family = family
    @user = user
  end

  # The read-then-write below is not atomic on its own: two overlapping
  # recomputes for the same chain can both load it, and the one that started
  # first can land its now-stale carry on top of the other's. `update_only`
  # keeps that from touching allocations, but rolled_over_amount is the very
  # column this writes, so nothing else protects it. A transaction-scoped
  # advisory lock keyed on the chain serializes them.
  #
  # Taken after the cheap guard, so families that never enabled rollover pay
  # one query and never contend, and re-read under the lock because the chain
  # may have changed while we waited for it.
  def recompute!
    return if first_relevant_budget_date.nil?

    BudgetCategory.transaction do
      lock_chain!
      from = first_relevant_budget_date
      recompute_chain!(from) if from
    end
  end

  private
    attr_reader :family, :user

    def lock_chain!
      BudgetCategory.connection.execute(
        BudgetCategory.sanitize_sql_array(
          [ "SELECT pg_advisory_xact_lock(?, hashtext(?))", LOCK_NAMESPACE, chain_key ]
        )
      )
    end

    def chain_key
      "budget_rollover:#{family.id}:#{user&.id}"
    end

    def recompute_chain!(from)
      updates = []
      now = Time.current

      # category_id => [amount, currency]. A budget freezes its currency when
      # it is created, so a family that switches currency leaves a break in the
      # chain: the amounts on either side are not the same unit. Carrying the
      # raw number across would silently reinterpret it, so the carry stops
      # there and the next month starts from zero.
      #
      # A category deleted mid-chain takes its budget_categories rows with it
      # (Category has_many :budget_categories, dependent: :destroy), so it
      # simply drops out of `carry` — its history is gone, which is what
      # deleting a category means.
      carry = {}
      # category_id => [balance, currency]. Independent of `carry` above and
      # never gated by rollover_enabled? -- an opening balance or a
      # reallocated reserve must not vanish just because a category's
      # ordinary monthly-surplus rollover is switched off. See
      # BudgetAdjustment and BudgetCategory#adjustments_balance.
      adjustments_carry = {}
      # End of the previous period actually visited (nil for the first).
      # BudgetAdjustment sums are windowed against this rather than against
      # the previous calendar month, so a gap month (budget never
      # initialized) doesn't drop an adjustment dated inside it -- the next
      # initialized period's window reaches back and absorbs it, same
      # "gap passes through untouched" semantics `carry` already has via
      # `chain`/`initialized_budgets`.
      period_end_before = nil

      chain(from).each do |budget|
        budget.income_statement_accounts = household_account_scope if user.nil?

        next_carry = {}
        next_adjustments_carry = {}
        ring_fenced_children = ring_fenced_children_by_parent(budget)

        budget.budget_categories.each do |budget_category|
          # Subcategories that share their parent's budget have no allocation
          # of their own, so there is nothing for them to carry forward.
          next if budget_category.inherits_parent_budget?

          incoming = incoming_carry(carry, budget_category)
          incoming_adjustments = incoming_adjustments_carry(adjustments_carry, budget_category)
          period_adjustments = adjustments_delta_for(budget_category, since: period_end_before, through: budget.end_date)
          new_adjustments_balance = incoming_adjustments + period_adjustments

          if budget_category[:rolled_over_amount] != incoming || budget_category[:adjustments_balance] != new_adjustments_balance
            updates << budget_category.attributes.merge(
              "rolled_over_amount" => incoming,
              "adjustments_balance" => new_adjustments_balance,
              "updated_at" => now
            )
          end

          # complete_to is only ever decided here, and only once: the
          # controller and propagate_contribution_choice_forward! already
          # handle it directly for a row that already exists (its own stored
          # rolled_over_amount is the correct carry by then). This is the one
          # path where a row can be brand new -- sync_budget_categories just
          # created it, in the same find_or_bootstrap call, with nothing
          # decided yet -- so it's the only place that needs `incoming`
          # before it's persisted. contribution_applied_at guards against
          # ever touching budgeted_spending again on a later recompute,
          # which would otherwise silently overwrite a user's own edit or
          # keep shifting the number as later spending changes what the
          # carry would have been.
          #
          # Written immediately via update_columns, deliberately NOT folded
          # into the batched upsert_all below: that batch's `updates` hashes
          # are full attribute snapshots taken at read time, and widening its
          # update_only to cover budgeted_spending would let a STALE
          # budgeted_spending -- read here, but changed by someone else
          # before this write lands -- clobber their edit on every row, not
          # just complete_to ones. A separate, targeted write has no such
          # blast radius. update_columns also updates this in-memory object,
          # so leftover_for below (which reads budget_category[:budgeted_spending]
          # directly) sees the number just decided rather than the stale 0
          # sync_budget_categories created the row with.
          if budget_category.complete_to? && budget_category.contribution_applied_at.nil?
            target = budget_category.contribution_target_amount(incoming)
            budget_category.update_columns(budgeted_spending: target, contribution_applied_at: now) if target
          end

          # Switching the toggle off has to stop the money in both directions.
          # Gating only what a month receives would let an opted-out month hand
          # its whole allocation to the next one that opts back in, so the
          # surplus a user meant to forfeit would reappear a month later.
          outgoing = if budget_category.rollover_enabled?
            children = ring_fenced_children[budget_category.category_id] || []
            leftover_for(budget, budget_category, incoming, children)
          else
            0
          end

          next_carry[budget_category.category_id] = [ outgoing, budget_category.currency ]
          next_adjustments_carry[budget_category.category_id] = [ new_adjustments_balance, budget_category.currency ]
        end

        carry = next_carry
        adjustments_carry = next_adjustments_carry
        period_end_before = budget.end_date
      end

      # The full attribute set is what makes the INSERT branch legal
      # (budget_id, category_id and currency are NOT NULL), but only the two
      # rollover columns may be written on conflict: a concurrent request that
      # changed an allocation between our read and this write must not have it
      # clobbered by the stale value we loaded.
      if updates.any?
        BudgetCategory.upsert_all(updates, unique_by: :id, update_only: %w[rolled_over_amount adjustments_balance updated_at])
      end
    end


    # Earliest month this chain has anything to say about: rollover switched
    # on, or an amount left behind by a toggle that was switched off and
    # still needs clearing. nil -- the common case, families that never
    # turned rollover on -- costs one query and does nothing.
    def first_relevant_budget_date
      from_rollover = initialized_budgets
        .joins("INNER JOIN budget_categories ON budget_categories.budget_id = budgets.id")
        .where("budget_categories.rollover_enabled OR budget_categories.rolled_over_amount <> 0 OR budget_categories.adjustments_balance <> 0")
        .minimum(:start_date)

      from_adjustments = BudgetAdjustment.where(family_id: family.id, user_id: user&.id).minimum(:effective_on)

      [ from_rollover, from_adjustments ].compact.min
    end

    # Walking back to `oldest_valid_budget_date` every time would read an
    # income statement per month for nothing: months before the first one
    # that uses rollover cannot change any stored amount. Start one
    # initialized month earlier than `from`, which is where its carry comes
    # from.
    def chain(from)
      seed = initialized_budgets.where("start_date < ?", from).maximum(:start_date)

      initialized_budgets
        .where("start_date >= ?", seed || from)
        .order(:start_date)
        .includes(budget_categories: :category)
    end

    # Only initialized budgets take part: a month the user never set up is a
    # gap in the chain, not a month budgeted at zero, so the carry crosses it
    # untouched (same semantics as Budget#most_recent_initialized_budget).
    def initialized_budgets
      family.budgets
        .where(user_id: user&.id)
        .where.not(budgeted_spending: nil)
    end

    def incoming_carry(carry, budget_category)
      return 0 unless budget_category.rollover_enabled?

      amount, currency = carry[budget_category.category_id]
      return 0 if amount.nil? || currency != budget_category.currency

      amount
    end

    # Unlike incoming_carry, never gated by rollover_enabled? -- see
    # adjustments_carry above.
    def incoming_adjustments_carry(adjustments_carry, budget_category)
      amount, currency = adjustments_carry[budget_category.category_id]
      return 0 if amount.nil? || currency != budget_category.currency

      amount
    end

    # Sum of this category's BudgetAdjustments effective in (since, through]
    # -- open on the low end so the very first period a chain walk considers
    # still picks up every adjustment recorded before it, not just ones after
    # some arbitrary boundary.
    def adjustments_delta_for(budget_category, since:, through:)
      scope = BudgetAdjustment.where(family_id: family.id, user_id: user&.id,
                                      category_id: budget_category.category_id,
                                      currency: budget_category.currency)
      scope = scope.where("effective_on > ?", since) if since
      scope.where("effective_on <= ?", through).sum(:amount)
    end

    # The household chain has no owner to scope actuals by, and IncomeStatement
    # falls back to Current.user when nobody says otherwise -- which would make
    # the stored carry depend on whichever member loaded the page, each
    # overwriting the other. Pin it to the whole family so the shared row holds
    # one number. Personal chains already scope to their owner's accounts.
    def household_account_scope
      @household_account_scope ||= family.accounts.included_in_reports
    end

    def ring_fenced_children_by_parent(budget)
      budget.budget_categories
        .select { |bc| bc.subcategory? && !bc.inherits_parent_budget? }
        .group_by { |bc| bc.category.parent_id }
    end

    # budgeted + rolled_over − actual, signed: an overspent envelope carries
    # its deficit into the next period instead of stopping at the month it
    # happened in, matching what BudgetCategory#over_budget?/#available_to_spend
    # already report for the current period. Floored at zero for any period
    # ending before SIGNED_CARRY_SINCE — see the constant's comment above.
    def leftover_for(budget, budget_category, incoming, ring_fenced_children)
      budgeted = (budget_category[:budgeted_spending] || 0) + incoming
      actual = budget.budget_category_actual_spending(budget_category)

      # A parent's allocation already contains its ring-fenced subcategories'
      # allocations, and its actual spending already contains their spending.
      # Those subcategories carry their own surplus forward, so take them out
      # here rather than rolling the same money over twice.
      ring_fenced_children.each do |child|
        budgeted -= (child[:budgeted_spending] || 0)
        actual -= budget.budget_category_actual_spending(child)
      end

      leftover = budgeted - actual
      return leftover if budget.end_date >= SIGNED_CARRY_SINCE

      [ leftover, 0 ].max
    end
end
