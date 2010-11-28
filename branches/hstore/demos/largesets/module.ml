(********************************************************************************)
(* Demo for PGOCaml with Lwt.							*)
(********************************************************************************)

open Lwt
open XHTML.M

module PGOCaml = PGOCaml_generic.Make (struct include Lwt include Lwt_chan end)


(********************************************************************************)
(* Coucou service.								*)
(********************************************************************************)

let pool = Lwt_pool.create 2 PGOCaml.connect

let count = ref 0

let coucou_handler sp () () =
	let id = !count in
	let () = incr count in
	let log msg =
		let now = Unix.gettimeofday () in
		Ocsigen_messages.warning (Printf.sprintf "Thread %d %s fetch at %f" id msg now) in
	let get_data dbh =
		log "starting";
		PGSQL (dbh) "SELECT name, age FROM people" >>= fun people ->
		log "finished";
		Lwt.return people in
	let format_person (name, age) =
		p [pcdata name; pcdata (Int32.to_string age)] in
	Lwt_pool.use pool get_data >>= fun people ->
	Lwt.return
		(html
		(head (title (pcdata "Coucou")) [])
		(body (List.rev_map format_person people)))

let coucou_service =
	Eliom_predefmod.Xhtml.register_new_service
		~path: [""]
		~get_params: Eliom_parameters.unit
		coucou_handler

