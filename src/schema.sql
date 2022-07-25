PRAGMA foreign_keys=ON;

CREATE TABLE folder (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL
) STRICT;

CREATE TABLE note (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text TEXT NOT NULL,
    folder_id INTEGER DEFAULT NULL,
    FOREIGN KEY (folder_id) REFERENCES folder(id)
) STRICT;
