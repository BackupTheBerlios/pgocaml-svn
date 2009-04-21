let create_table dbh =
      PGSQL(dbh) "execute" "create temporary table users
      (
      id          serial not null primary key,
      name        text not null,
      age         int
      )"

let insert_user dbh name age =
      PGSQL(dbh) "INSERT INTO users (name, age)
                  VALUES ($name, $?age)"

let get_users dbh =
      PGSQL(dbh) "SELECT id, name, age FROM users"

let print_user (id, name, age) =
      let age_str = match age with
            | Some number     -> Int32.to_string number
            | None            -> "(no age)"
      in
      Printf.printf "Id: %ld  Name: %s  Age: %s \n" id name age_str

let _ =
      let dbh = PGOCaml.connect () in

      let () = create_table dbh in

      let () =
            insert_user dbh "John" (Some 30_l);
            insert_user dbh "Mary" (Some 40_l);
            insert_user dbh "Mark" None in

      List.iter print_user (get_users dbh)
