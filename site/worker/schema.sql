-- Counters per day. dim is what is counted (views, uniques, country, lang, os, device, ref, page,
-- dl, dl_lang, dls), key is its value.
CREATE TABLE IF NOT EXISTS counts (
  day TEXT NOT NULL,
  dim TEXT NOT NULL,
  key TEXT NOT NULL,
  n   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, dim, key)
) WITHOUT ROWID;

-- Today's visitor hashes and the salt they were made with; both are deleted the next night.
CREATE TABLE IF NOT EXISTS seen (
  day TEXT NOT NULL,
  h   TEXT NOT NULL,
  PRIMARY KEY (day, h)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS salts (
  day TEXT PRIMARY KEY,
  v   TEXT NOT NULL
);
