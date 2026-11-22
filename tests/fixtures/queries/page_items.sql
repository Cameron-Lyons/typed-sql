SELECT id, title, note, enabled FROM integration_items
WHERE (id BETWEEN :lo AND :hi AND title LIKE :pattern ESCAPE '~')
   OR (NOT (id IN (:excluded)) AND title = 'untitled')
ORDER BY id LIMIT :count OFFSET :skip;
