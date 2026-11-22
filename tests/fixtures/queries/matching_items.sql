SELECT id, title FROM integration_items
WHERE NOT (id NOT IN (:first, :second, :first) OR title NOT LIKE :pattern)
ORDER BY id DESC;
