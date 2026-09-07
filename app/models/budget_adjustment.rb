# A signed ledger entry against a category's accumulated reserve -- money
# BudgetCategory#budgeted_spending/rolled_over_amount can't represent: an
# opening balance from savings that predate Sure, or a reallocation of
# reserve between envelopes (as opposed to BudgetCategory.move_allocation!,
# which only moves the current month's plan). Scoped by category_id, not
# budget_category_id: a category's accumulated reserve is a fact that
# persists across periods, the same way rolled_over_amount conceptually
# does. Materialized into BudgetCategory#adjustments_balance by
# Budget::RolloverCalculator.
#
# Not PocketMovement: that journals account-level reservations, a different
# kind of event deliberately kept in its own table.
class BudgetAdjustment < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :user, optional: true
  belongs_to :category

  enum :kind, { opening_balance: "opening_balance", reallocation: "reallocation", rule_contribution: "rule_contribution" },
    default: :opening_balance

  monetize :amount

  validates :amount, numericality: { other_than: 0 }
  validates :currency, presence: true
  validates :effective_on, presence: true
  validates :group_id, presence: true, if: :reallocation?
  validates :group_id, absence: true, unless: :reallocation?
  validate :category_belongs_to_family

  class InvalidReallocation < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(I18n.t("budget_adjustments.reallocate.errors.#{reason}"))
    end
  end

  class << self
    # A one-time credit for money already sitting in an envelope before Sure
    # started tracking it. Deliberately just a ledger row, not a state
    # machine -- no "already recorded" guard, the same way a bank doesn't
    # refuse a second deposit. A correction is another adjustment, not an
    # edit to this one.
    def record_opening_balance!(category:, amount:, family:, currency:, user: nil, effective_on: Date.current, note: nil)
      create!(family: family, user: user, category: category, kind: :opening_balance,
              amount: amount.to_d, currency: currency, effective_on: effective_on, note: note)
    end

    # A rule-triggered credit (fixed/percent/round-up on a matching
    # transaction) -- kept distinct from opening_balance so a targeted future
    # undo (e.g. "reverse only what this rule ever contributed") can find its
    # own rows without touching genuine one-time backfills. Household chain
    # only (user: nil): a Rule has no per-user concept, matching how a
    # funding_category-linked Goal already only ever reads the household
    # chain (see Goal#current_funding_budget_category).
    def record_rule_contribution!(category:, amount:, family:, currency:, effective_on: Date.current)
      create!(family: family, user: nil, category: category, kind: :rule_contribution,
              amount: amount.to_d, currency: currency, effective_on: effective_on)
    end

    # Moves `amount` of ACCUMULATED RESERVE from one envelope to another --
    # the reserve equivalent of BudgetCategory.move_allocation!, which only
    # ever touches the current month's budgeted_spending plan.
    #
    # rolled_over_amount/adjustments_balance are calculator-derived, never
    # directly user-settable, so this can't mutate a column the way
    # move_allocation! does -- it writes a paired debit+credit instead and
    # leaves the caller to run Budget::RolloverCalculator#recompute! after
    # this commits. Same reasoning as move_allocation!: the calculator takes
    # its own advisory lock, and taking it inside this transaction would
    # invert the lock order every other caller uses and deadlock two
    # concurrent reallocations.
    def reallocate!(from_category:, to_category:, amount:, family:, user: nil, note: nil)
      amount = amount.to_d
      validate_reallocation!(from_category: from_category, to_category: to_category, amount: amount, family: family, user: user)

      group_id = SecureRandom.uuid
      currency = current_currency_for(to_category, family: family, user: user)
      effective_on = Date.current

      transaction do
        # Lock both categories' current budget_category rows (if any), by
        # ascending category id, so two concurrent reallocations touching
        # either side serialize here instead of racing past a stale read.
        BudgetCategory.where(category_id: [ from_category.id, to_category.id ].sort).lock.to_a

        available = available_reserve_for(from_category, family: family, user: user)
        raise InvalidReallocation.new(:insufficient_reserve) if amount > available

        debit = create!(family: family, user: user, category: from_category, kind: :reallocation,
                         amount: -amount, currency: currency, effective_on: effective_on, group_id: group_id, note: note)
        credit = create!(family: family, user: user, category: to_category, kind: :reallocation,
                          amount: amount, currency: currency, effective_on: effective_on, group_id: group_id, note: note)

        [ debit, credit ]
      end
    end

    private
      def validate_reallocation!(from_category:, to_category:, amount:, family:, user:)
        raise InvalidReallocation.new(:non_positive_amount) unless amount.positive?
        raise InvalidReallocation.new(:uncategorized) if [ from_category, to_category ].any? { |c| c.nil? || !c.persisted? }
        raise InvalidReallocation.new(:same_category) if from_category.id == to_category.id
        raise InvalidReallocation.new(:different_families) unless from_category.family_id == family.id && to_category.family_id == family.id
        raise InvalidReallocation.new(:parent_child) if direct_lineage?(from_category, to_category)

        from_currency = current_currency_for(from_category, family: family, user: user)
        to_currency = current_currency_for(to_category, family: family, user: user)
        raise InvalidReallocation.new(:different_currencies) if from_currency && to_currency && from_currency != to_currency
      end

      def direct_lineage?(a, b)
        a.id == b.parent_id || b.id == a.parent_id
      end

      # The most recently initialized budget_category row for this category,
      # in this family/user scope -- the same "most recent initialized"
      # lookup Budget#most_recent_initialized_budget uses, just keyed by
      # category instead of by budget.
      def current_budget_category_for(category, family:, user:)
        BudgetCategory.joins(:budget)
                       .where(category_id: category.id, budgets: { family_id: family.id, user_id: user&.id })
                       .where.not(budgets: { budgeted_spending: nil })
                       .order("budgets.start_date DESC")
                       .first
      end

      # The reserve a category can currently send away: its adjustments_balance
      # as of the most recent initialized period, or 0 if the category has
      # never been budgeted.
      def available_reserve_for(category, family:, user:)
        current_budget_category_for(category, family: family, user: user)&.adjustments_balance || 0
      end

      def current_currency_for(category, family:, user:)
        current_budget_category_for(category, family: family, user: user)&.currency || family.primary_currency_code
      end
  end

  private
    def category_belongs_to_family
      errors.add(:category, :invalid) if category && family && category.family_id != family.id
    end
end
