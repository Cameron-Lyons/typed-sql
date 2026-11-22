CREATE TABLE integration_categories (
  id INTEGER NOT NULL PRIMARY KEY DEFAULT 1,
  label TEXT NOT NULL UNIQUE DEFAULT 'general'
);

CREATE TABLE integration_items (
  id BIGINT NOT NULL,
  small_id INTEGER NOT NULL,
  category_id INTEGER NOT NULL DEFAULT 1 REFERENCES integration_categories(id),
  title TEXT NOT NULL DEFAULT 'untitled',
  note TEXT DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  stock INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT integration_items_pk PRIMARY KEY (id),
  UNIQUE (title, id)
);

CREATE INDEX integration_items_title ON integration_items(title, id DESC);
