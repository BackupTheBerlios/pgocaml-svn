(* PG'OCaml - type safe interface to PostgreSQL.
 * Copyright (C) 2005-2009 Richard Jones and other authors.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this library; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 *)

open Camlp4.PreCast

open Printf
open ExtString
open ExtList

exception Bad_funret of string
exception Bad_table_comment of string

let nullable_name = "nullable"
let unravel_name = "unravel"
let column_comment_name = "column_comment"
let table_comment_name = "table_comment"
let proc_comment_name = "proc_comment"
let type_name = "type"
let class_name = "class"
let funret_name = "funret"

(* We need a database connection while compiling.  If people use the
 * override flags like "database=foo", then we may connect to several
 * databases at once.  Keep track of that here.  Note that in the normal
 * case we have just one database handle, opened to the default
 * database (as controlled by environment variables such as $PGHOST,
 * $PGDATABASE, etc.)
 *)
type key = {
  (* None in any of these fields means use the default. *)
  host : string option;
  port : int option;
  user : string option;
  password : string option;
  database : string option;
  unix_domain_socket_dir : string option;
}

let connections : (key, unit PGOCaml.t) Hashtbl.t = Hashtbl.create 13

let get_connection key =
  try
    Hashtbl.find connections key
  with
    Not_found ->
      (* Create a new connection. *)
      let host = key.host in
      let port = key.port in
      let user = key.user in
      let password = key.password in
      let database = key.database in
      let unix_domain_socket_dir = key.unix_domain_socket_dir in
      let dbh =
	PGOCaml.connect
	  ?host ?port ?user ?password ?database
	  ?unix_domain_socket_dir () in

      (* Prepare the nullable test - see result conversions below. *)
      let nullable_query = "select attnotnull from pg_attribute where attrelid = $1 and attnum = $2" in
      PGOCaml.prepare dbh ~query:nullable_query ~name:nullable_name ();

      (* Prepare the unravel test. *)
      let unravel_query = "select typtype, typbasetype from pg_type where oid = $1" in
      PGOCaml.prepare dbh ~query:unravel_query ~name:unravel_name ();

      (* Prepare the query returning the comment associated with a given table and column. *)
      let column_comment_query = "select col_description (attrelid, attnum) from pg_attribute where attrelid=$1 and attnum=$2" in
      PGOCaml.prepare dbh ~query:column_comment_query ~name:column_comment_name ();

      (* Prepare the query returning the comment associated with a given OID. *)
      let table_comment_query = "select obj_description ($1, $2)" in
      PGOCaml.prepare dbh ~query:table_comment_query ~name:table_comment_name ();

      (* Prepare the query returning the comment associated with a given function name. *)
      let proc_comment_query = "select obj_description (oid, 'pg_proc') from pg_proc where proname=$1" in
      PGOCaml.prepare dbh ~query:proc_comment_query ~name:proc_comment_name ();

      (* Prepare the query returning the pg_type.OID associated with a type name. *)
      let type_query = "select oid from pg_type where typname=$1" in
      PGOCaml.prepare dbh ~query:type_query ~name:type_name ();

      (* Prepare the query returning the pg_class.OID associated with the pg_type.OID. *)
      let class_query = "select typrelid from pg_type where oid=$1" in
      PGOCaml.prepare dbh ~query:class_query ~name:class_name ();

      (* Prepare the query returning the pg_type.OID associated with a function's return type. *)
      let funret_query = "select prorettype from pg_proc where proname = $1" in
      PGOCaml.prepare dbh ~query:funret_query ~name:funret_name ();

      Hashtbl.add connections key dbh;
      dbh

(*
*)
let debug_table = function
	| `pg_class t -> "pg_class.oid=" ^ t
	| `pg_type t -> "pg_type.oid=" ^ t

(* By using CREATE DOMAIN, the user may define types which are essentially aliases
   for existing types.  If the original type is not recognised by PG'OCaml, this
   functions recurses through the pg_type table to see if it happens to be an alias
   for a type which we do know how to handle.
*)
let unravel_type dbh orig_type =
  (*Printf.eprintf "unravel_type %ld\n" orig_type;*)
  let rec unravel_type_aux ft =
    try
      PGOCaml.name_of_type ft
    with PGOCaml.Error msg as exc ->
      let params = [ Some (PGOCaml.string_of_oid ft) ] in
      let rows = PGOCaml.execute dbh ~name:unravel_name ~params () in
      match rows with
	| [ [ Some typtype ; Some typbasetype ] ] when typtype = "d" ->
	  unravel_type_aux (PGOCaml.oid_of_string typbasetype)
	| _ ->
	  raise exc
  in unravel_type_aux orig_type

(* Checks attnotnull in the system table pg_attribute to determine whether the
   the given column is nullable.  Note that this only works for real tables.
*)
let get_attnotnull dbh class_oid column =
  (*Printf.eprintf "get_attnotnull %s %s\n" class_oid column;*)
  let params = [ Some class_oid; Some column ] in
  let rows = PGOCaml.execute dbh ~name:nullable_name ~params () in
  let not_nullable = match rows with
    | [ [ Some b ] ] -> PGOCaml.bool_of_string b
    | _ -> false
  in not not_nullable

(* Returns the pg_class.oid associated with a given pg_type.oid.
*)
let get_class_oid dbh type_oid =
  (*Printf.eprintf "get_class_oid %s\n" type_oid;*)
  let params = [ Some type_oid ] in
  let rows = PGOCaml.execute dbh ~name:class_name ~params () in
  match rows with
    | [ [ Some class_oid ] ] -> class_oid
    | _ -> failwith ("Cannot get pg_class.oid associated with pg_type.oid=" ^ type_oid)

(* Checks whether a 'pgoc_null' comment exists for the given column.
   If so, we can directly set the column's nullability accordingly.
*)
let rec get_column_comment =
  let rex = Pcre.regexp "\\bpgoc_null=(?<value>[t|f])" in
  fun dbh table_oid column ->
    Printf.eprintf "get_column_comment %s %s\n" (debug_table table_oid) column;
    let class_oid = match table_oid with
      | `pg_class t -> t
      | `pg_type t  -> get_class_oid dbh t in
    let params = [ Some class_oid; Some column ] in
    let rows = PGOCaml.execute dbh ~name:column_comment_name ~params () in
    match rows with
      | [ [ Some comment ] ] ->
	let substr = Pcre.exec ~rex comment in
	let value = Pcre.get_named_substring rex "value" substr in
	(match value with
	  | "f" -> false
	  | _   -> true)  (* Whether explicitly "t" or otherwise, assume nullable. *)
      | _ ->
	get_table_comment dbh table_oid column

(* Checks whether a 'pgoc_link' comment exists for the given table.
   This comment tells us that nullability-wise, this table can be
   treated as if it were an instance of the table specified in the
   comment.
*)
and get_table_comment =
  let rex = Pcre.regexp "\\bpgoc_link=(?<value>\\w+)" in
  fun dbh table_oid column ->
    Printf.eprintf "get_table_comment %s %s\n" (debug_table table_oid) column;
    let obj_oid, class_oid, catalog = match table_oid with
      | `pg_class t -> t, t, "pg_class"
      | `pg_type t  -> t, (get_class_oid dbh t), "pg_type" in
    let params = [ Some obj_oid ; Some catalog ] in
    let rows = PGOCaml.execute dbh ~name:table_comment_name ~params () in
    match rows with
      | [ [ Some comment ] ] ->
	(try
	  let substr = Pcre.exec ~rex comment in
	  let value = Pcre.get_named_substring rex "value" substr in
	  get_type_oid dbh value column
	with _ ->
	  get_attnotnull dbh class_oid column)
      | _ ->
	get_attnotnull dbh class_oid column

(* Returns the pg_type.oid corresponding to a type's named.
*)
and get_type_oid dbh table column =
  (*Printf.eprintf "get_type_oid %s %s\n" table column;*)
  let params = [ Some table ] in
  let rows = PGOCaml.execute dbh ~name:type_name ~params () in
  match rows with
    | [ [ Some type_oid ] ] -> get_column_comment dbh (`pg_type type_oid) column
    | _ -> raise (Bad_table_comment table)

(* Checks whether there is a pgoc_null comment defined for the given function;
   if so, extract nullability from it; otherwise, check nullability via the
   pg_type.oid of the function's return type.
*)
let get_funret =
  let rex = Pcre.regexp "\\bpgoc_null=(?<value>[t|f])" in
  fun dbh funret column ->
    Printf.eprintf "get_funret %s %s\n" funret column;
    let params = [ Some funret ] in
    let rows = PGOCaml.execute dbh ~name:proc_comment_name ~params () in
    match rows with
      | [ [ Some comment ] ] ->
	let substr = Pcre.exec ~rex comment in
	let value = Pcre.get_named_substring rex "value" substr in
	(match value with
	  | "f" -> false
	  | _   -> true)  (* Whether explicitly "t" or otherwise, assume nullable. *)
      | _ ->
	let rows = PGOCaml.execute dbh ~name:funret_name ~params () in
	match rows with
	  | [ [ Some table ] ] -> get_column_comment dbh (`pg_type table) column
	  | _			 -> raise (Bad_funret funret)

(* Return the list of numbers a <= i < b.
*)
let rec range a b =
  if a < b then a :: range (a+1) b else [];;

let rex = Pcre.regexp "\\$(@?)(\\??)([_a-z][_a-zA-Z0-9']*)"

let pgsql_expand ?(flags = []) loc dbh query =
  (* Parse the flags. *)
  let f_execute = ref false in
  let f_nullable_results = ref false in
  let f_funret = ref None in
  let key = ref { host = None; port = None; user = None;
		  password = None; database = None;
		  unix_domain_socket_dir = None } in
  List.iter (
    function
    | "execute" -> f_execute := true
    | "nullable-results" -> f_nullable_results := true
    | str when String.starts_with str "fun=" ->
	f_funret := Some (String.sub str 4 (String.length str - 4))
    | str when String.starts_with str "host=" ->
	let host = String.sub str 5 (String.length str - 5) in
	key := { !key with host = Some host }
    | str when String.starts_with str "port=" ->
	let port = int_of_string (String.sub str 5 (String.length str - 5)) in
	key := { !key with port = Some port }
    | str when String.starts_with str "user=" ->
	let user = String.sub str 5 (String.length str - 5) in
	key := { !key with user = Some user }
    | str when String.starts_with str "password=" ->
	let password = String.sub str 9 (String.length str - 9) in
	key := { !key with password = Some password }
    | str when String.starts_with str "database=" ->
	let database = String.sub str 9 (String.length str - 9) in
	key := { !key with database = Some database }
    | str when String.starts_with str "unix_domain_socket_dir=" ->
	let socket = String.sub str 23 (String.length str - 23) in
	key := { !key with unix_domain_socket_dir = Some socket }
    | str ->
	Loc.raise loc (
	  Failure ("Unknown flag: " ^ str)
	)
  ) flags;
  let f_execute = !f_execute in
  let f_nullable_results = !f_nullable_results in
  let f_funret = !f_funret in
  let key = !key in

  (* Connect, if necessary, to the database. *)
  let my_dbh = get_connection key in

  (* Split the query into text and variable name parts using Pcre.full_split.
   * eg. "select id from employees where name = $name and salary > $salary"
   * would become a structure equivalent to:
   * ["select id from employees where name = "; "$name"; " and salary > ";
   * "$salary"].
   * Actually it's a wee bit more complicated than that ...
   *)
  let split = Pcre.full_split ~rex query in
  let split =
    let rec loop = function
      | [] -> []
      | Pcre.Text text :: rest -> `Text text :: loop rest
      | Pcre.Delim _ :: Pcre.Group (1, list) ::
	  Pcre.Group (2, option) :: Pcre.Group (3, varname) :: rest ->
	  let list = match list with
	    | "" -> false | "@" -> true | _ -> assert false in
	  let option = match option with
	    | "" -> false | "?" -> true | _ -> assert false in
	  `Var (varname, list, option) :: loop rest
      | _ ->
	  Loc.raise loc (
	    Failure "Pcre.full_split: unexpected value returned"
	  )
    in
    loop split in

  (* Go to the database, prepare this statement, and find out exactly
   * what the parameter types and return values are.  Exceptions can
   * be raised here if the statement is bad SQL.
   *)
  let (params, results), varmap =
    (* Rebuild the query with $n placeholders for each variable. *)
    let next = let i = ref 0 in fun () -> incr i; !i in
    let varmap = Hashtbl.create 7 in
    let query = String.concat "" (
      List.map (
	function
	| `Text text -> text
	| `Var (varname, false, option) ->
	    let i = next () in
	    Hashtbl.add varmap i (varname, false, option);
	    sprintf "$%d" i
	| `Var (varname, true, option) ->
	    let i = next () in
	    Hashtbl.add varmap i (varname, true, option);
	    sprintf "($%d)" i
      ) split
    ) in
    let varmap = Hashtbl.fold (
      fun i var vars -> (i, var) :: vars
    ) varmap [] in
    try
      PGOCaml.prepare my_dbh ~query ();
      PGOCaml.describe_statement my_dbh (), varmap
    with
      exn -> Loc.raise loc exn in

  (* If the PGSQL(dbh) "execute" flag was used, we will actually
   * execute the statement now.  Normally this would never be used, but
   * some statements need to be executed, particularly CREATE TEMPORARY
   * TABLE.
   *)
  if f_execute then ignore (PGOCaml.execute my_dbh ~params:[] ());

  (* Number of params should match length of map, otherwise something
   * has gone wrong in the substitution above.
   *)
  if List.length varmap <> List.length params then
    Loc.raise loc (
      Failure ("Mismatch in number of parameters found by database. " ^
	       "Most likely your statement contains bare $, $number, etc.")
    );

  (* Generate a function for converting the parameters.
   *
   * See also:
   * http://archives.postgresql.org/pgsql-interfaces/2006-01/msg00043.php
   *)
  let params =
    List.fold_right
      (fun (i, { PGOCaml.param_type = param_type }) tail ->
	 let varname, list, option = List.assoc i varmap in
	 let fn = "string_of_" ^ (unravel_type my_dbh param_type) in
	 let head =
	   match list, option with
	   | false, false ->
	     <:expr< [ Some (PGOCaml.$lid:fn$ $lid:varname$) ] >>
	   | false, true ->
	     <:expr< [ Option.map PGOCaml.$lid:fn$ $lid:varname$ ] >>
	   | true, false ->
	     <:expr< List.map (fun x -> Some (PGOCaml.$lid:fn$ x)) $lid:varname$ >>
	   | true, true ->
	     <:expr< List.map (fun x -> Option.map PGOCaml.$lid:fn$ x) $lid:varname$ >> in
	 <:expr< [ $head$ :: $tail$ ] >>
      )
      (List.combine (range 1 (1 + List.length varmap)) params)
      <:expr< [] >>
  in

  (* Substitute expression. *)
  let expr =
    let split = List.fold_right (
      fun s tail ->
	let head = match s with
	  | `Text text -> <:expr< `Text $str:text$ >>
	  | `Var (varname, list, option) ->
	      let list =
		if list then <:expr< True >> else <:expr< False >> in
	      let option =
		if option then <:expr< True >> else <:expr< False >> in
	      <:expr< `Var $str:varname$ $list$ $option$ >> in
	<:expr< [ $head$ :: $tail$ ] >>
    ) split <:expr< [] >> in
    <:expr<
      (* let original_query = $str:query$ in * original query string *)
      let dbh = $dbh$ in
      let params = $params$ in (* type: string option list list *)
      let split = $split$ in (* split up query *)

      (* Rebuild the query with appropriate placeholders.  A single list
       * param can expand into several placeholders.
       *)
      let i = ref 0 in (* Counts parameters. *)
      let j = ref 0 in (* Counts placeholders. *)
      let query = String.concat "" (
	List.map (
	  fun
	  [ `Text text -> text
	  | `Var varname False _ ->	(* non-list item *)
	      let () = incr i in	(* next parameter *)
	      let () = incr j in	(* next placeholder number *)
	      "$" ^ string_of_int j.contents
	  | `Var varname True _ -> (* list item *)
	      let param = List.nth params i.contents in
	      let () = incr i in	(* next parameter *)
	      "(" ^
		String.concat "," (
		  List.map (
		    fun _ ->
		      let () = incr j in (* next placeholder number *)
		      "$" ^ string_of_int j.contents
		  ) param
		) ^
		")"
	  ]
	) split) in

      (* Flatten the parameters to a simple list now. *)
      let params = List.flatten params in

      (* Get a unique name for this query using an MD5 digest. *)
      let name = "pa_pgsql." ^ Digest.to_hex (Digest.string query) in

      (* Get the hash table used to keep track of prepared statements. *)
      let hash =
	try PGOCaml.private_data dbh
	with
	  [ Not_found ->
	      let hash = Hashtbl.create 17 in
	      do {
		PGOCaml.set_private_data dbh hash;
		hash
	      } ] in
      (* Have we prepared this statement already?  If not, do so. *)
      let is_prepared = Hashtbl.mem hash name in
      PGOCaml.bind
        (if not is_prepared then
           PGOCaml.bind (PGOCaml.prepare dbh ~name ~query ()) (fun () ->
           do {
             Hashtbl.add hash name True;
             PGOCaml.return ()
           })
         else
           PGOCaml.return ()) (fun () ->
         (* Execute the statement, returning the rows. *)
      PGOCaml.execute_rev dbh ~name ~params ())
    >> in

  (* If we're expecting any result rows, then generate a function to
   * convert them.  Otherwise return unit.  Note that we can only
   * determine the nullability of results if they correspond to real
   * columns in a table, otherwise the type will always be 'type option'.
   *)
  match results with
  | Some results ->
      let list = List.fold_right
	(fun i tail ->
	   <:patt< [ $lid:"c"^string_of_int i$ :: $tail$ ] >>
	)
	(range 0 (List.length results))
	<:patt< [] >> in

      let conversions =
	List.mapi (
	  fun i result ->
	    Printf.eprintf "Determining column %d\n" i;
	    let field_type = result.PGOCaml.field_type in
	    let modifier = result.PGOCaml.modifier in
	    let fn =
	      PGOCaml.name_of_type ~modifier field_type in
	    let fn = fn ^ "_of_string" in
	    let nullable = f_nullable_results || match f_funret with
	      | Some f -> get_funret my_dbh f (string_of_int (i+1))
	      | None ->
		match (result.PGOCaml.table, result.PGOCaml.column) with
		  | Some table, Some column ->
		    get_column_comment my_dbh (`pg_class (PGOCaml.string_of_oid table)) (string_of_int column)
		  | _ ->
		    true in  (* Assume it could be nullable. *)
	    let col = <:expr< $lid:"c" ^ string_of_int i$ >> in
	    if nullable then
	      <:expr< Option.map PGOCaml.$lid:fn$ $col$ >>
	    else
	      <:expr< PGOCaml.$lid:fn$ (Option.get $col$) >>
	) results in

      let convert =
	(* Avoid generating a single-element tuple. *)
	match conversions with
	| [] -> <:expr< () >>
	| [a] -> <:expr< $a$ >>
	| conversion :: conversions ->
	    (*<:expr< ( $list:conversions$ ) >> in
	     * http://caml.inria.fr/pub/ml-archives/caml-list/2007/05/ab49714d974451f669cf46455627466d.en.html
	     *)
	    <:expr< ( $conversion$, $Ast.exCom_of_list conversions$ ) >> in

      <:expr<
	PGOCaml.bind $expr$ (fun rows ->
        PGOCaml.return
          (let original_query = $str:query$ in
           List.rev_map (
             fun row ->
               match row with
                 [ $list$ -> $convert$
                 | _ ->
                     (* This should never happen, even if the schema changes.
                      * Well, maybe if the user does 'SELECT *'.
                      *)
                     let msg = "pa_pgsql: internal error: " ^
                       "Incorrect number of columns returned from query: " ^
                       original_query ^
                       ".  Columns are: " ^
                       String.concat "; " (
                         List.map (
                           fun [ Some str -> Printf.sprintf "%S" str
                           | None -> "NULL" ]
                         ) row
                       ) in
                     raise (PGOCaml.Error msg) ]
           ) rows))
      >>

  | None ->
      <:expr<
	PGOCaml.bind $expr$ (fun rows -> PGOCaml.return ())
      >>

open Syntax

EXTEND Gram
  expr: LEVEL "top" [
    [ "PGSQL"; "("; dbh = expr; ")";
      extras = LIST1 [ x = STRING -> x ] ->
	let query, flags =
	  match List.rev extras with
	  | [] -> assert false
	  | query :: flags -> query, flags in
	pgsql_expand ~flags loc dbh (Camlp4.Struct.Token.Eval.string query)
    ]
  ];
END
