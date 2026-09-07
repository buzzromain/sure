class Tag < ApplicationRecord
  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a]

  UNCATEGORIZED_COLOR = "#737373"

  # Tag name key for i18n
  UNTAGGED_NAME_KEY = "models.tag.untagged"

  # Stable, non-localized filter value for the synthetic "Untagged" option.
  # Using an opaque sentinel (rather than the translated display name) means a real
  # tag can never collide with it, regardless of name or locale.
  UNTAGGED_FILTER_VALUE = "__untagged__"

  belongs_to :family
  has_many :taggings, dependent: :destroy
  has_many :transactions, through: :taggings, source: :taggable, source_type: "Transaction"
  has_many :import_mappings, as: :mappable, dependent: :destroy, class_name: "Import::Mapping"
  # No `dependent:` here on purpose -- see release_linked_pockets below. A
  # bulk `dependent: :nullify` would skip Pocket's own after_save
  # (sync_from_tag), leaving allocated_amount stuck at its last tag-filled
  # total instead of recomputed to 0.
  has_many :pockets

  validates :name, presence: true, uniqueness: { scope: :family }
  validates :name, exclusion: { in: [ UNTAGGED_FILTER_VALUE ] }
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }, allow_nil: true

  scope :alphabetically, -> { order(:name, :id) }

  class << self
    def untagged
      new(name: I18n.t(UNTAGGED_NAME_KEY), color: UNCATEGORIZED_COLOR)
    end

    # Helper to get the localized name for "Untagged"
    def untagged_name
      I18n.t(UNTAGGED_NAME_KEY)
    end
  end

  # The value the transactions-filter checkbox submits for this tag: the
  # persisted name for a real tag, or the stable sentinel for the synthetic
  # "Untagged" pseudo-tag returned by .untagged.
  def filter_value
    persisted? ? name : UNTAGGED_FILTER_VALUE
  end

  # pockets.tag_id has no ON DELETE clause (NO ACTION), so destroying a tag
  # a Pocket auto-fills from would otherwise raise ActiveRecord::InvalidForeignKey.
  # Releasing through Pocket#update! rather than a bulk nullify so its own
  # sync_from_tag callback recomputes allocated_amount to 0 -- the same
  # outcome a user gets from clearing the tag on the pocket's own edit form.
  before_destroy :release_linked_pockets

  def replace_and_destroy!(replacement)
    transaction do
      raise ActiveRecord::RecordInvalid, "Replacement tag cannot be the same as the tag being destroyed" if replacement == self

      if replacement
        taggings.update_all tag_id: replacement.id
      end

      destroy!
    end
  end

  private
    def release_linked_pockets
      pockets.find_each { |pocket| pocket.update!(tag_id: nil) }
    end
end
