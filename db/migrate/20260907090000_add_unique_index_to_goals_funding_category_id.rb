class AddUniqueIndexToGoalsFundingCategoryId < ActiveRecord::Migration[8.1]
  def change
    # Étape 5: `validates :funding_category_id, uniqueness: true` only
    # catches this at the Rails layer -- two concurrent requests can both
    # read "no active goal on this category yet" and both create one. A
    # plain (non-unique) index has existed here since the column was added;
    # this is the constraint Postgres actually enforces. Nulls stay
    # unconstrained by Postgres's own single-column unique-index semantics
    # (NULL is never equal to NULL), matching allow_nil: true exactly --
    # no partial WHERE clause needed.
    remove_index :goals, :funding_category_id, name: "index_goals_on_funding_category_id"
    add_index :goals, :funding_category_id, unique: true, name: "index_goals_on_funding_category_id"
  end
end
