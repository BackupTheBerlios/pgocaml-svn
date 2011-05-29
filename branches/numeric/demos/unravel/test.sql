CREATE DOMAIN age_t AS int4;

CREATE TABLE people
	(
	id	int4 UNIQUE NOT NULL,
	name	text NOT NULL,
	age	age_t NOT NULL,

	PRIMARY KEY (id)
	);

INSERT INTO people (id, name, age) VALUES (1, 'john', 20);
INSERT INTO people (id, name, age) VALUES (2, 'mary', 30);

