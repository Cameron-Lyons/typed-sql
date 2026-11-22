UPDATE integration_items SET note = :note
WHERE id = :id OR id = :id RETURNING id, note;
