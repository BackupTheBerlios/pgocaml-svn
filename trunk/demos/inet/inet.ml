let () =
	let conn = PGOCaml.connect () in
	let () = PGSQL(conn) "execute" "CREATE TEMPORARY TABLE test (ip_address inet not null)" in
	let ip4_address = (Unix.inet_addr_loopback, 32) in
	let ip6_address = (Unix.inet6_addr_loopback, 128) in
	let () = PGSQL(conn) "INSERT INTO test (ip_address) VALUES ($ip4_address)" in
	let () = PGSQL(conn) "INSERT INTO test (ip_address) VALUES ($ip6_address)" in
	let addrs = PGSQL(conn) "SELECT * FROM test"
	in List.iter (fun (addr, mask) -> Printf.printf "%s/%d\n" (Unix.string_of_inet_addr addr) mask) addrs

