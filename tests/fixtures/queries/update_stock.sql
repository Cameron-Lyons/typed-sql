UPDATE integration_items SET stock = :stock WHERE id = :id RETURNING stock;
