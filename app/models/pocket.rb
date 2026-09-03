class Pocket < ApplicationRecord
  include Monetizable

  belongs_to :account
  belongs_to :tag, optional: true
  has_one :goal, dependent: :nullify
  # Ordered explicitly: the primary key is a UUID, so insertion order isn't
  # recoverable from it the way it would be from a serial id — an unordered
  # .last here is a coin flip, not "the most recent movement".
  has_many :movements, -> { order(:created_at) }, class_name: "PocketMovement", dependent: :destroy

  class MovementRefused < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("pocket movement refused: #{reason}")
    end
  end

  enum :fill_direction, { inflows: "inflows", outflows: "outflows", both: "both" }, default: :inflows

  validates :name, :currency, presence: true
  validate :account_must_be_depository
  validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :total_pockets_within_account_balance
  validate :tag_belongs_to_same_family

  # Composition sketch (PR #2892 discussion): same reasoning as Goal's own
  # tracking tag — a free choice among the family's existing tags risks
  # landing on one already used for something else, silently backdating
  # every past transaction under it into this pocket's total. `link_new_tag`
  # is a form flag ("auto-fill from a tag"), never a tag picker: when set,
  # the pocket generates and owns a dedicated tag instead of being handed one.
  attr_accessor :link_new_tag
  after_create :ensure_tracking_tag, if: :link_new_tag

  # recompute! treats the sum of movements as the whole non-tag story, so a
  # starting balance that never became a movement would vanish the moment
  # anything (a tag event, an add/withdraw) asked for a recompute. These two
  # keep that sum honest: one seeds the amount a manual pocket is born with,
  # the other logs a direct edit to allocated_amount as the delta it is —
  # neither fires for a tag-linked pocket, whose amount recompute! (via
  # sync_from_tag/the tag total) owns outright.
  after_create :seed_initial_movement, if: -> { allocated_amount.to_d.positive? && !link_new_tag }
  after_update :seed_movement_for_direct_edit, if: -> { saved_change_to_allocated_amount? && !tag_id.present? }

  before_save :sync_tracking_tag_name, if: :will_save_change_to_name?

  after_save :sync_from_tag, if: -> { saved_change_to_tag_id? || saved_change_to_fill_direction? }

  PALETTE = %w[#875BF7 #6471EB #4DA568 #E99537 #DB5A54 #DF4E92 #61C9EA #805DEE].freeze
  COLORS = Category::COLORS
  ICONS = Category.icon_codes

  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_blank: true
  validates :icon, inclusion: { in: -> { Category.icon_codes }, allow_nil: true }

  monetize :allocated_amount

  def display_color
    color.presence || tag&.color.presence || PALETTE[id.bytes.sum % PALETTE.size]
  end

  def display_icon
    icon.presence || "wallet"
  end

  def allocation_percent(balance)
    return 0 if balance.nil? || balance <= 0

    [ (allocated_amount / balance.to_f * 100).round, 100 ].min
  end

  # The pocket's true balance, always fully derived rather than incrementally
  # tracked: the sum of every explicit add/withdraw gesture, plus whatever
  # the auto-fill tag currently totals (0 if there is none). Two independent
  # sources, recomputed together on every call — same reasoning tag-fill
  # already used update_column and a full re-sum for: incrementally applying
  # deltas from two different mechanisms is exactly where the two can drift
  # apart from each other.
  def recompute!
    total = manual_movement_total
    total += tagged_transaction_total(tag_id) if tag_id.present?
    update_column(:allocated_amount, total)
  end

  def manual_movement_total
    movements.sum(:amount)
  end

  # Full recompute (via recompute!) rather than an incremental adjust_by:
  # incrementally adding/subtracting per-tagging deltas can diverge from the aggregate
  # for fill_direction "both" (each step clamps at 0, whereas the aggregate only floors
  # the net total at 0 — order of tagging/untagging can then produce different results).
  # recompute! uses update_column, same as increment!/decrement! did, so it
  # still skips AR callbacks/validations and avoids re-triggering the Tagging callbacks
  # that called these methods.
  def apply_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    recompute!
  end

  # Must run after the Tagging row is actually deleted (see Tagging#unfill_linked_pocket,
  # registered as after_destroy) so the aggregate query in recompute! excludes it.
  def reverse_tagging(tagging)
    delta = tagging_transaction_delta(tagging)
    return unless delta

    recompute!
  end

  # The explicit-transfer counterpart to tag-fill: a deliberate "move this
  # much in" gesture, not tied to any transaction. Capped at what the
  # account actually has free across every pocket, same ceiling
  # total_pockets_within_account_balance already enforces on a direct edit —
  # recompute! writes via update_column and skips that validation, so it is
  # checked explicitly here instead.
  def add_money!(amount, note: nil)
    amount = amount.to_d
    raise MovementRefused.new(:non_positive) unless amount.positive?

    with_lock do
      others_total = account.pockets.where.not(id: id).sum(:allocated_amount)
      room = account.balance.to_d - others_total
      raise MovementRefused.new(:exceeds_account_balance) if allocated_amount.to_d + amount > room

      movements.create!(amount: amount, note: note)
      recompute!
    end

    reload
    self
  end

  # The withdraw side of add_money!. Refused past what the pocket actually
  # holds — same "refuse rather than clamp" reasoning Goal's consume! uses:
  # clamping would silently disagree with what the movement history says
  # happened.
  def withdraw_money!(amount, note: nil)
    amount = amount.to_d
    raise MovementRefused.new(:non_positive) unless amount.positive?

    with_lock do
      raise MovementRefused.new(:exceeds_balance) if amount > allocated_amount.to_d

      movements.create!(amount: -amount, note: note)
      recompute!
    end

    reload
    self
  end

  private

    def ensure_tracking_tag
      generated = account.family.tags.find_or_create_by!(name: "pockets:#{name}") do |t|
        t.color = Tag::COLORS.sample
      end
      update_column(:tag_id, generated.id)
    end

    def seed_initial_movement
      movements.create!(amount: allocated_amount)
    end

    def seed_movement_for_direct_edit
      old_amount, new_amount = saved_change_to_allocated_amount
      delta = new_amount.to_d - old_amount.to_d
      return if delta.zero?

      movements.create!(amount: delta)
    end

    def sync_tracking_tag_name
      return unless tag_id.present?
      return if account.family.tags.where.not(id: tag_id).exists?(name: "pockets:#{name}")

      tag.update_column(:name, "pockets:#{name}")
    end

    def sync_from_tag
      _, new_tag_id = saved_change_to_tag_id || [ nil, tag_id ]

      # Full recompute: replace current amount with the fresh sum from DB
      new_amount = new_tag_id.present? ? tagged_transaction_total(new_tag_id) : 0
      update_column(:allocated_amount, new_amount)
    end

    def direction_condition
      case fill_direction
      when "inflows"  then "entries.amount < 0"
      when "outflows" then "entries.amount > 0"
      else nil
      end
    end

    def tagged_transaction_total(tag_id)
      # Runs its own independent aggregate query, so it must not inherit an
      # ambient current_scope (e.g. Entry.bulk_update! invoked via a
      # `family.entries` has_many :through relation leaves an accounts JOIN
      # in scope). Entry.from(subq, ...) replaces the FROM clause, so any
      # inherited JOIN referencing "entries" would break the query.
      Entry.unscoped do
        subq = Entry.joins(
          "INNER JOIN transactions ON transactions.id = entries.entryable_id
             AND entries.entryable_type = 'Transaction'"
        ).joins(
          "INNER JOIN taggings ON taggings.taggable_id = transactions.id
             AND taggings.taggable_type = 'Transaction'"
        ).where(entries: { account_id: account_id, currency: currency })
         .where(taggings: { tag_id: tag_id })
         .select("DISTINCT entries.id, entries.amount")

        if fill_direction == "both"
          # Net = incomes - expenses, floored at 0.
          # DB convention: income = negative amount, expense = positive → SUM(-amount) gives net.
          Entry.from(subq, :deduplicated_entries)
               .pick(Arel.sql("GREATEST(0, COALESCE(SUM(-amount), 0))"))
               .to_d
        else
          subq = subq.where(direction_condition)
          Entry.from(subq, :deduplicated_entries)
               .pick(Arel.sql("COALESCE(SUM(ABS(amount)), 0)"))
               .to_d
        end
      end
    end

    # Returns a signed delta: positive = add to pocket, negative = subtract from pocket.
    def tagging_transaction_delta(tagging)
      return nil unless tagging.taggable_type == "Transaction"

      entry = tagging.taggable.entry
      return nil unless entry
      return nil unless entry.currency == currency

      amount = entry.amount
      return nil unless amount

      case fill_direction
      when "inflows"  then amount < 0 ? amount.abs : nil  # income only, always positive
      when "outflows" then amount > 0 ? amount : nil      # expense only, always positive
      else -amount  # income (neg in DB) → positive delta; expense (pos in DB) → negative delta
      end
    end

    def total_pockets_within_account_balance
      return unless account && allocated_amount

      sibling_total = account.pockets.where.not(id: id).sum(:allocated_amount)
      if sibling_total + allocated_amount > account.balance
        errors.add(:allocated_amount, :exceeds_account_balance,
          available: account.balance - sibling_total,
          currency: account.currency)
      end
    end

    def account_must_be_depository
      return unless account

      errors.add(:account, :not_depository) unless account.depository?
    end

    def tag_belongs_to_same_family
      return unless tag && account

      unless tag.family_id == account.family_id
        errors.add(:tag, :wrong_family)
      end
    end
end
