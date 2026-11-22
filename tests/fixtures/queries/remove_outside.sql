DELETE FROM integration_items WHERE id NOT BETWEEN :lo AND :hi RETURNING id;
