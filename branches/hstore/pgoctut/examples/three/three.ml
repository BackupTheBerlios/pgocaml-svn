let create_table dbh =
      PGSQL(dbh) "execute" "create temporary table users
      (
      id          serial not null primary key,
      name        text not null,
      age         int,
      votes       int[]
      )"

let insert_user dbh name age votes =
      PGSQL(dbh) "INSERT INTO users (name, age, votes)
                  VALUES ($name, $?age, $votes)"

let get_users dbh =
      PGSQL(dbh) "SELECT id, name, age FROM users"

let get_2_users dbh =
      PGSQL(dbh) "SELECT id, name, age FROM users WHERE id IN (1, 2)"

let get_n_users dbh user_ids =
      PGSQL(dbh) "SELECT id, name, age FROM users WHERE id IN $@user_ids"

let print_user (id, name, age) =
      let age_str = match age with
            | Some number     -> Int32.to_string number
            | None            -> "(no age)"
      in
      Printf.printf "Id: %ld  Name: %s  Age: %s \n"
            id name age_str

let _ =
      let dbh = PGOCaml.connect () in

      let () = create_table dbh in

      let () =
            insert_user dbh "John" (Some 30_l) [| 10_l; 15_l |];
            insert_user dbh "Mary" (Some 40_l) [| 16_l |];
            insert_user dbh "Mark" None [| |] in

      List.iter print_user (get_users dbh);
      List.iter print_user (get_2_users dbh);
      List.iter print_user (get_n_users dbh [2_l; 3_l])
