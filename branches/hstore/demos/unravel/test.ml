let add_user dbh =
	let id = 3l
	and name = "mark"
	and age = 40l in
	PGSQL(dbh) "INSERT INTO people (id, name, age) VALUES ($id, $name, $age)"


let get_users dbh =
	PGSQL(dbh) "SELECT id, name, age FROM people"

let print_user (id, name, age) =
	Printf.printf "Id: %ld  Name: %s  Age: %ld \n" id name age

let () =
	let dbh = PGOCaml.connect ()
	in List.iter print_user (get_users dbh)

