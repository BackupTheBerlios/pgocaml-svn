let sprint_a = string_of_bool
let sprint_b = Int32.to_string
let sprint_c = Int64.to_string
let sprint_d x = x
let sprint_e = string_of_float
let sprint_f = string_of_float

let sprint_array f a = String.concat "; " (Array.to_list (Array.map f a))

let print (a, b, c, d, e, f) =
	Printf.printf "A: %s\n" (sprint_array sprint_a a);
	Printf.printf "B: %s\n" (sprint_array sprint_b b);
	Printf.printf "C: %s\n" (sprint_array sprint_c c);
	Printf.printf "D: %s\n" (sprint_array sprint_d d);
	Printf.printf "E: %s\n" (sprint_array sprint_e e);
	Printf.printf "F: %s\n" (sprint_array sprint_f f)

let () =
	let conn = PGOCaml.connect () in
	let () = PGSQL(conn) "execute" "CREATE TEMPORARY TABLE test (a boolean[] not null, b int4[] not null, c int8[] not null, d text[] not null, e float4[] not null, f float8[] not null)" in
	let a = [|true; false; true|] in
	let b = [|1_l; 2_l; 3_l|] in
	let c = [|1_L; 2_L; 3_L|] in
	let d = [|"one"; "two"; "three"|] in
	let e = [|1.0; 2.0; 3.0|] in
	let f = [|1.0; 2.0; 3.0|] in
	let () = PGSQL(conn) "INSERT INTO test (a, b, c, d, e, f) VALUES ($a, $b, $c, $d, $e, $f)" in
	let res = PGSQL(conn) "SELECT * FROM test" in
	let () = PGOCaml.close conn in
	List.iter print res

