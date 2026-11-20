class CreateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs do |t|
      t.string :scenario_key, null: false
      t.json :world, null: false, default: {}
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :runs, :scenario_key
  end
end
