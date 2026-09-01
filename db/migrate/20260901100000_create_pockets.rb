class CreatePockets < ActiveRecord::Migration[8.1]
  def change
    create_table :pockets, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true
      t.references :tag, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :description
      t.decimal :allocated_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :fill_direction, null: false, default: "inflows"
      t.string :color
      t.string :icon

      t.timestamps
    end

    add_index :pockets, [ :account_id, :tag_id ], unique: true, where: "tag_id IS NOT NULL",
              name: "index_pockets_on_account_and_tag_unique"

    add_check_constraint :pockets, "allocated_amount >= 0", name: "chk_pockets_allocated_amount_non_negative"
    add_check_constraint :pockets, "btrim(name) <> ''", name: "chk_pockets_name_present"
    add_check_constraint :pockets, "btrim(currency) <> ''", name: "chk_pockets_currency_present"
    add_check_constraint :pockets, "fill_direction IN ('inflows', 'outflows', 'both')", name: "chk_pockets_fill_direction"
  end
end
