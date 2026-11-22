INSERT INTO integration_items(id, small_id, title, note)
VALUES (:first_id, :small, :first_title, :note),
       (:second_id, :small, :second_title, :note),
       (:third_id, :small, :third_title, :note)
RETURNING *;
