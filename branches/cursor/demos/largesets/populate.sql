create table people
	(
	id	serial not null primary key,
	name	text not null,
	age	int4 not null
	);

insert into people (name, age) select 'name' || CAST (x.x AS text), CAST (x.x AS int) FROM generate_series (1,500000) AS x;

