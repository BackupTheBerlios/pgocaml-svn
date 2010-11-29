open ExtString

let string_of_hstore hstore =
	let string_of_quoted str = "\"" ^ str ^ "\"" in
	let string_of_mapping (key, value) =
		let key_str = string_of_quoted key
		and value_str = match value with
			| Some v -> string_of_quoted v
			| None -> "NULL"
		in key_str ^ "=>" ^ value_str
	in String.join ", " (List.map string_of_mapping hstore)


let print_row (foo1, foo2, foo3, foo4) =
	Printf.printf "(%ld, %Ld, %s, {%s})\n" foo1 foo2 foo3 (string_of_hstore foo4)


let print_all rows =
	List.iter print_row rows


let conn =
	PGOCaml.connect ()

let s0 =
	Printf.eprintf "#s0\n%!";
	PGSQL(conn) "execute" "drop table if exists gluglu";
	PGSQL(conn) "execute" "drop domain if exists bar";
	PGSQL(conn) "execute" "create domain bar as int8";
	PGSQL(conn) "execute" "create table gluglu (foo1 int4 not null, foo2 bar not null, foo3 text not null, foo4 hstore not null)"


let s1 =
	Printf.eprintf "#s1\n%!";
	let foo1 = 1_l
	and foo2 = 1_L
	and foo3 = "hello"
	and foo4 = [("x", Some "1"); ("y", None); ("", Some "2"); ("z", Some "NULL")] in
	PGSQL(conn) "insert into gluglu (foo1, foo2, foo3, foo4) values ($foo1, $foo2, $foo3, $foo4)"


let s2 =
	Printf.eprintf "#s2\n%!";
	let foo1 = 2_l
	and foo2 = 2_L
	and foo3 = "byebye"
	and foo4 = [("a", None); ("a", Some "2"); ("NULL", None); ("NOTNULL", Some "NULL")] in
	PGSQL(conn) "insert into gluglu (foo1, foo2, foo3, foo4) values ($foo1, $foo2, $foo3, $foo4)"


let s3 =
	Printf.eprintf "#s3\n%!";
	let rows = PGSQL(conn) "SELECT * FROM gluglu" in
	print_all rows

