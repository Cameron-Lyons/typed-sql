SELECT id, small_id FROM integration_items
WHERE small_id = :shared OR id = :shared ORDER BY id;
