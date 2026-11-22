CREATE INDEX books_in_print ON books (in_print);
INSERT INTO books (id, title, author, in_print)
VALUES (1, 'Invisible Cities', 'Italo Calvino', TRUE);
