(* PG'OCaml is a set of OCaml bindings for the PostgreSQL database.
 * $Id: pGOCaml.ml,v 1.23 2007-05-26 13:54:33 rich Exp $
 *)

open Printf
open ExtString

open PGOCaml
open Lwt

type 'a t = {
  fd : Lwt_unix.file_descr;
  ichan : Lwt_chan.in_channel;		(* In_channel wrapping socket. *)
  chan : Lwt_chan.out_channel;		(* Out_channel wrapping socket. *)
  mutable private_data : 'a option;
  uuid : string;			(* UUID for this connection. *)
	mutex : Lwt_mutex.t; (* mutex for this connection *)
}

let uuid_of_conn conn =
	conn.uuid;;

let lock_connection conn =
	eprintf "[PGOCaml] [%s] locking\n%!" conn.uuid;
	Lwt_mutex.lock conn.mutex;;

let unlock_connection conn =
	eprintf "[PGOCaml] [%s] unlocking\n%!" conn.uuid;
	Lwt_mutex.unlock conn.mutex;;

let debug_protocol = false

(*----- Code to generate messages for the back-end. -----*)

let new_message typ =
  let buf = Buffer.create 128 in
  buf, Some typ

(* StartUpMessage and SSLRequest are special messages which don't
 * have a type byte field.
 *)
let new_start_message () =
  let buf = Buffer.create 128 in
  buf, None

let add_byte (buf, _) i =
  (* Deliberately throw an exception if i isn't [0..255]. *)
  Buffer.add_char buf (Char.chr i)

let add_char (buf, _) c =
  Buffer.add_char buf c

let add_int16 (buf, _) i =
  if i < 0 || i > 65_535 then
    raise (Error "PGOCaml: int16 is outside range [0..65535].");
  Buffer.add_char buf (Char.unsafe_chr ((i lsr 8) land 0xff));
  Buffer.add_char buf (Char.unsafe_chr (i land 0xff))

let add_int32 (buf, _) i =
  let base = Int32.to_int i in
  let big = Int32.to_int (Int32.shift_right_logical i 24) in
  Buffer.add_char buf (Char.unsafe_chr (big land 0xff));
  Buffer.add_char buf (Char.unsafe_chr ((base lsr 16) land 0xff));
  Buffer.add_char buf (Char.unsafe_chr ((base lsr 8) land 0xff));
  Buffer.add_char buf (Char.unsafe_chr (base land 0xff))

let add_string_no_trailing_nil (buf, _) str =
  (* Check the string doesn't contain '\0' characters. *)
  if String.contains str '\000' then
    raise (Error (sprintf "PGOCaml: string contains ASCII NIL character: %S" str));
  if String.length str > 0x3fff_ffff then
    raise (Error "PGOCaml: string is too long.");
  Buffer.add_string buf str

let add_string msg str =
  add_string_no_trailing_nil msg str;
  add_byte msg 0

let send_message { chan = chan } (buf, typ) =
  (* Get the length in bytes. *)
  let len = 4 + Buffer.length buf in

  (* If the length is longer than a 31 bit integer, then the message is
   * too long to send.  This limits messages to 1 GB, which should be
   * enough for anyone :-)
   *)
  if Int64.of_int len >= 0x4000_0000L then
    raise (Error "PGOCaml: message is larger than 1 GB");

  if debug_protocol then
    eprintf "> %s%d %S\n%!"
      (match typ with
       | None -> ""
       | Some c -> sprintf "%c " c)
      len (Buffer.contents buf);

  (* Write the type byte? *)
  (match typ with
   | None -> return ()
   | Some c -> Lwt_chan.output_string chan (String.make 1 c)
  ) >>=

  (* Write the length field. *)
  fun () -> Lwt_extutil.output_binary_int chan len >>=

  (* Write the buffer. *)
  fun () -> Lwt_chan.output_string chan (Buffer.contents buf)

(* generic code removed *)

(* Receive a single result message.  Parse out the message type,
 * message length, and binary message content.
 *)
let receive_message { ichan = ichan; chan = chan } =
  (* Flush output buffer. *)
  Lwt_chan.flush chan >>=
  fun () -> Lwt_chan.input_char ichan >>=
  fun typ -> Lwt_extutil.input_binary_int ichan >>=
  fun len ->

  (* Discount the length word itself. *)
  let len = len - 4 in
  begin

  (* If the message is too long, give up now. *)
    if len > !max_message_length then
    begin 
      (* Skip the message so we stay in synch with the stream. *)
      let bufsize = 65_536 in
      let buf = String.create bufsize in
      Lwt_extutil.lwt_while len
        (fun n -> n > 0)
        (fun n -> let m = min n bufsize in
          Lwt_chan.really_input ichan buf 0 m >>=
          fun () -> return (n - m)) >>=
      fun () -> fail
        (Error "PGOCaml: back-end message is longer than max_message_length")
    end
    else
      return ()
  end >>=
	
  fun () ->
  (* Read the binary message content. *)
  let msg = String.create len in
    Lwt_chan.really_input ichan msg 0 len >>=
    fun () -> return (typ, msg)

(* Send a message and expect a single result. *)
let send_recv conn msg =
  send_message conn msg >>=
  fun () -> receive_message conn

(* generic code removed *)

(* Parse a back-end message. *)
type msg_t =
  | AuthenticationOk
  | AuthenticationKerberosV5
  | AuthenticationCleartextPassword
  | AuthenticationCryptPassword of string
  | AuthenticationMD5Password of string
  | AuthenticationSCMCredential
  | BackendKeyData of int32 * int32
  | BindComplete
  | CloseComplete
  | CommandComplete of string
  | DataRow of (int * string) list
  | EmptyQueryResponse
  | ErrorResponse of (char * string) list
  | NoData
  | NoticeResponse of (char * string) list
  | ParameterDescription of int32 list
  | ParameterStatus of string * string
  | ParseComplete
  | ReadyForQuery of char
  | RowDescription of (string * int32 * int * int32 * int * int32 * int) list
  | UnknownMessage of char * string

let string_of_msg_t = function
  | AuthenticationOk -> "AuthenticationOk"
  | AuthenticationKerberosV5 -> "AuthenticationKerberosV5"
  | AuthenticationCleartextPassword -> "AuthenticationCleartextPassword"
  | AuthenticationCryptPassword str ->
      sprintf "AuthenticationCleartextPassword %S" str
  | AuthenticationMD5Password str ->
      sprintf "AuthenticationMD5Password %S" str
  | AuthenticationSCMCredential -> "AuthenticationMD5Password"
  | BackendKeyData (i1, i2) ->
      sprintf "BackendKeyData %ld, %ld" i1 i2
  | BindComplete -> "BindComplete"
  | CloseComplete -> "CloseComplete"
  | CommandComplete str ->
      sprintf "CommandComplete %S" str
  | DataRow fields ->
      sprintf "DataRow [%s]"
	(String.concat "; "
	   (List.map (fun (len, bytes) -> sprintf "%d, %S" len bytes) fields))
  | EmptyQueryResponse -> "EmptyQueryResponse"
  | ErrorResponse strs ->
      sprintf "ErrorResponse [%s]"
	(String.concat "; "
	   (List.map (fun (k, v) -> sprintf "%c, %S" k v) strs))
  | NoData -> "NoData"
  | NoticeResponse strs ->
      sprintf "NoticeResponse [%s]"
	(String.concat "; "
	   (List.map (fun (k, v) -> sprintf "%c, %S" k v) strs))
  | ParameterDescription fields ->
      sprintf "ParameterDescription [%s]"
	(String.concat "; "
	   (List.map (fun oid -> sprintf "%ld" oid) fields))
  | ParameterStatus (s1, s2) ->
      sprintf "ParameterStatus %S, %S" s1 s2
  | ParseComplete -> "ParseComplete"
  | ReadyForQuery c ->
      sprintf "ReadyForQuery %s"
	(match c with
	 | 'I' -> "Idle"
	 | 'T' -> "inTransaction"
	 | 'E' -> "Error"
	 | c -> sprintf "unknown(%c)" c)
  | RowDescription fields ->
      sprintf "RowDescription [%s]"
	(String.concat "; "
	   (List.map (fun (name, table, col, oid, len, modifier, format) ->
			sprintf "%s %ld %d %ld %d %ld %d"
			  name table col oid len modifier format) fields))
  | UnknownMessage (typ, msg) ->
      sprintf "UnknownMessage %c, %S" typ msg

let parse_backend_message (typ, msg) =
  let pos = ref 0 in
  let len = String.length msg in

  (* Functions to grab the next object from the string 'msg'. *)
  let get_char where =
    if !pos < len then (
      let r = msg.[!pos] in
      incr pos;
      r
    ) else
      raise (Error ("PGOCaml: parse_backend_message: " ^ where ^
		    ": short message"))
  in
  let get_byte where = Char.code (get_char where) in
  let get_int16 () =
    let r0 = get_byte "get_int16" in
    let r1 = get_byte "get_int16" in
    (r0 lsr 8) + r1
  in
  let get_int32 () =
    let r0 = get_byte "get_int32" in
    let r1 = get_byte "get_int32" in
    let r2 = get_byte "get_int32" in
    let r3 = get_byte "get_int32" in
    let r = Int32.of_int r0 in
    let r = Int32.shift_left r 8 in
    let r = Int32.logor r (Int32.of_int r1) in
    let r = Int32.shift_left r 8 in
    let r = Int32.logor r (Int32.of_int r2) in
    let r = Int32.shift_left r 8 in
    let r = Int32.logor r (Int32.of_int r3) in
    r
  in
  (*let get_int64 () =
    let r0 = get_byte "get_int64" in
    let r1 = get_byte "get_int64" in
    let r2 = get_byte "get_int64" in
    let r3 = get_byte "get_int64" in
    let r4 = get_byte "get_int64" in
    let r5 = get_byte "get_int64" in
    let r6 = get_byte "get_int64" in
    let r7 = get_byte "get_int64" in
    let r = Int64.of_int r0 in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r1) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r2) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r3) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r4) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r5) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r6) in
    let r = Int64.shift_left r 8 in
    let r = Int64.logor r (Int64.of_int r7) in
    r
  in*)
  let get_string () =
    let buf = Buffer.create 16 in
    let rec loop () =
      let c = get_char "get_string" in
      if c <> '\000' then (
	Buffer.add_char buf c;
	loop ()
      ) else
	Buffer.contents buf
    in
    loop ()
  in
  let get_n_bytes n =
    let str = String.create n in
    for i = 0 to n-1 do
      str.[i] <- get_char "get_n_bytes"
    done;
    str
  in
  let get_char () = get_char "get_char" in
  (*let get_byte () = get_byte "get_byte" in*)

  let msg =
    match typ with
    | 'R' ->
	let t = get_int32 () in
	(match t with
	 | 0l -> AuthenticationOk
	 | 2l -> AuthenticationKerberosV5
	 | 3l -> AuthenticationCleartextPassword
	 | 4l ->
	     let salt = String.create 2 in
	     for i = 0 to 2 do
	       salt.[i] <- get_char ()
	     done;
	     AuthenticationCryptPassword salt
	 | 5l ->
	     let salt = String.create 4 in
	     for i = 0 to 3 do
	       salt.[i] <- get_char ()
	     done;
	     AuthenticationMD5Password salt
	 | 6l -> AuthenticationSCMCredential
	 | _ -> UnknownMessage (typ, msg)
	);

    | 'E' ->
	let strs = ref [] in
	let rec loop () =
	  let field_type = get_char () in
	  if field_type = '\000' then List.rev !strs (* end of list *)
	  else (
	    strs := (field_type, get_string ()) :: !strs;
	    loop ()
	  )
	in
	ErrorResponse (loop ())

    | 'N' ->
	let strs = ref [] in
	let rec loop () =
	  let field_type = get_char () in
	  if field_type = '\000' then List.rev !strs (* end of list *)
	  else (
	    strs := (field_type, get_string ()) :: !strs;
	    loop ()
	  )
	in
	NoticeResponse (loop ())

    | 'Z' ->
	let c = get_char () in
	ReadyForQuery c

    | 'K' ->
	let pid = get_int32 () in
	let key = get_int32 () in
	BackendKeyData (pid, key)

    | 'S' ->
	let param = get_string () in
	let value = get_string () in
	ParameterStatus (param, value)

    | '1' -> ParseComplete

    | '2' -> BindComplete

    | '3' -> CloseComplete

    | 'C' ->
	let str = get_string () in
	CommandComplete str

    | 'D' ->
	let nr_fields = get_int16 () in
	let fields = ref [] in
	for i = 0 to nr_fields-1 do
	  let len = get_int32 () in
	  let field =
	    if len < 0l then (-1, "")
	    else (
	      if len >= 0x4000_0000l then
		raise (Error "PGOCaml: result field is too long");
	      let len = Int32.to_int len in
	      if len > Sys.max_string_length then
		raise (Error "PGOCaml: result field is too wide for string");
	      let bytes = get_n_bytes len in
	      len, bytes
	    ) in
	  fields := field :: !fields
	done;
	DataRow (List.rev !fields)

    | 'I' -> EmptyQueryResponse

    | 'n' -> NoData

    | 'T' ->
	let nr_fields = get_int16 () in
	let fields = ref [] in
	for i = 0 to nr_fields-1 do
	  let name = get_string () in
	  let table = get_int32 () in
	  let column = get_int16 () in
	  let oid = get_int32 () in
	  let length = get_int16 () in
	  let modifier = get_int32 () in
	  let format = get_int16 () in
	  fields := (name, table, column, oid, length, modifier, format)
	    :: !fields
	done;
	RowDescription (List.rev !fields)

    | 't' ->
	let nr_fields = get_int16 () in
	let fields = ref [] in
	for i = 0 to nr_fields - 1 do
	  let oid = get_int32 () in
	  fields := oid :: !fields
	done;
	ParameterDescription (List.rev !fields)

    | _ -> UnknownMessage (typ, msg) in

  if debug_protocol then eprintf "< %s\n%!" (string_of_msg_t msg);

  msg
(* Print an ErrorResponse on stderr. *)
let print_ErrorResponse fields =
  if !verbose >= 1 then (
    try
      let severity = List.assoc 'S' fields in
      let code = List.assoc 'C' fields in
      let message = List.assoc 'M' fields in
      if !verbose = 1 then
	match severity with
	| "ERROR" | "FATAL" | "PANIC" ->
	    eprintf "%s: %s: %s\n%!" severity code message
	| _ -> ()
      else
	eprintf "%s: %s: %s\n%!" severity code message
    with
      Not_found ->
	eprintf
	  "WARNING: 'Always present' field is missing in error message\n%!"
  );
  if !verbose >= 2 then (
    List.iter (
      fun (field_type, field) ->
	if field_type <> 'S' && field_type <> 'C' && field_type <> 'M' then
	  eprintf "%c: %s\n%!" field_type field
    ) fields
  )

(* Handle an ErrorResponse anywhere, by printing and raising an exception. *)
let pg_error ?conn fields =
  print_ErrorResponse fields;
  let str =
    try
      let severity = List.assoc 'S' fields in
      let code = List.assoc 'C' fields in
      let message = List.assoc 'M' fields in
      sprintf "%s: %s: %s" severity code message
    with
      Not_found ->
	"WARNING: 'Always present' field is missing in error message" in

  (* If conn parameter was given, then resynch - read messages until we
   * see ReadyForQuery.
   *)
  (match conn with
   | None -> return ()
   | Some conn ->
       let rec loop () =
	 receive_message conn >>=
	 fun x -> return (parse_backend_message x) >>=
	 fun msg -> match msg with
                    | ReadyForQuery _ -> return ()
                    | _ -> loop ()
       in
       loop ()
  ) >>=

  fun () -> fail (PostgreSQL_Error (str, fields))

(*----- Profiling. -----*)

type 'a retexn = Ret of 'a | Exn of exn

(* profile_op : string -> string -> string list -> (unit -> 'a) -> 'a *)
let profile_op uuid op detail f =
  let chan =
    try
      let filename = Sys.getenv "PGPROFILING" in
      let flags = [ Open_wronly; Open_append; Open_creat ] in
      let chan = open_out_gen flags 0o644 filename in
      Some chan
    with
    | Not_found
    | Sys_error _ -> None in
  match chan with
  | None -> f ()			(* No profiling - just run it. *)
  | Some chan ->			(* Profiling. *)
      let start_time = Unix.gettimeofday () in
      let ret = try Ret (f ()) with exn -> Exn exn in
      let end_time = Unix.gettimeofday () in

      let elapsed_time_ms = int_of_float (1000. *. (end_time -. start_time)) in
      let row = [
	"1";				(* Version number. *)
	uuid;
	op;
	string_of_int elapsed_time_ms;
	match ret with
	| Ret _ -> "ok"
	| Exn exn -> Printexc.to_string exn
      ] @ detail in

      (* Lock the output channel while we write the row, to prevent
       * corruption from multiple writers.
       *)
      let fd = Unix.descr_of_out_channel chan in
      Unix.lockf fd Unix.F_LOCK 0;
      Csv.save_out chan [row];
      close_out chan;

      (* Return result or re-raise the exception. *)
      match ret with
      | Ret r -> r
      | Exn exn -> raise exn


(*----- Connection. -----*)

let connect ?host ?port ?user ?(password = "") ?database
    ?(unix_domain_socket_dir = PGOCaml_config.default_unix_domain_socket_dir)
    () =
  (* Get the username. *)
  let user =
    match user with
    | Some user -> user
    | None ->
	try Sys.getenv "PGUSER"
	with Not_found ->
	  try
	    let pw = Unix.getpwuid (Unix.geteuid ()) in
	    pw.Unix.pw_name
	  with
	    Not_found -> "postgres" in

  (* Get the database name. *)
  let database =
    match database with
    | Some database -> database
    | None ->
	try Sys.getenv "PGDATABASE"
	with Not_found -> user in

  (* Hostname and port number. *)
  let host =
    match host with
    | Some _ -> host
    | None ->
	try Some (Sys.getenv "PGHOST")
	with Not_found -> None in (* use Unix domain socket. *)

  let port =
    match port with
    | Some port -> port
    | None ->
	try int_of_string (Sys.getenv "PGPORT")
	with Not_found | Failure "int_of_string" -> 5432 in

  (* Make the socket address. *)
  let sockaddr =
    match host with
    | Some hostname ->
	(try
	   let hostent = Unix.gethostbyname hostname in
	   let domain = hostent.Unix.h_addrtype in
	   match domain with
	   | Unix.PF_INET | Unix.PF_INET6 ->
	       (* Choose a random address from the list. *)
	       let addrs = hostent.Unix.h_addr_list in
	       let len = Array.length addrs in
	       if len <= 0 then
		 raise (Error ("PGOCaml: unknown host: " ^ hostname));
	       let i = Random.int len in
	       let addr = addrs.(i) in
	       Unix.ADDR_INET (addr, port)
	   | Unix.PF_UNIX ->
	       (* Would we trust a pathname returned through DNS? *)
	       raise (Error "PGOCaml: DNS returned PF_UNIX record")
	 with
	   Not_found ->
	     raise (Error ("PGOCaml: unknown host: " ^ hostname))
	);
    | None -> (* Unix domain socket. *)
	let sockaddr = sprintf "%s/.s.PGSQL.%d" unix_domain_socket_dir port in
	Unix.ADDR_UNIX sockaddr in

  (* Create a universally unique identifier for this connection.  This
   * is mainly for debugging and profiling.
   *)
  let uuid =
    sprintf "%s %d %d %g %s %g"
      (Unix.gethostname ())
      (Unix.getpid ())
      (Unix.getppid ())
      (Unix.gettimeofday ())
      Sys.executable_name
      ((Unix.times ()).Unix.tms_utime) in
  let uuid = Digest.to_hex (Digest.string uuid) in

  let do_connect () =
    return (Lwt_unix.socket
      (Unix.domain_of_sockaddr sockaddr)
      (Unix.SOCK_STREAM) 0) >>=
    fun fd -> Lwt_unix.connect fd sockaddr >>=
    fun () -> return (Lwt_unix.in_channel_of_descr fd) >>=
    fun ichan -> return (Lwt_unix.out_channel_of_descr fd) >>=
    fun chan ->

    (* Create the connection structure. *)
    let conn = { fd = fd;
		 ichan = ichan;
		 chan = chan;
		 private_data = None;
		 uuid = uuid;
		 mutex = Lwt_mutex.create () } in

    (* Send the StartUpMessage.  NB. At present we do not support SSL. *)
    let msg = new_start_message () in
    add_int32 msg 196608l;
    add_string msg "user"; add_string msg user;
    add_string msg "database"; add_string msg database;
    add_byte msg 0;

    (* Loop around here until the database gives a ReadyForQuery message. *)
    let rec loop msg =
    (match msg with
     | Some msg -> send_recv conn msg
     | None -> receive_message conn) >>=
    fun x -> let msg = parse_backend_message x in

      match msg with
      | ReadyForQuery _ -> return () (* Finished connecting! *)
      | BackendKeyData _ ->
         (* XXX We should save this key. *)
         loop None
      | ParameterStatus _ ->
         (* Should we do something with this? *)
	 loop None
      | AuthenticationOk -> loop None
      | AuthenticationKerberosV5 ->
	  raise (Error "PGOCaml: Kerberos authentication not supported")
      | AuthenticationCleartextPassword ->
	  let msg = new_message 'p' in (* PasswordMessage *)
	  add_string msg password;
	  loop (Some msg)
      | AuthenticationCryptPassword salt ->
	  (* Crypt password not supported because there is no crypt(3) function
	   * in OCaml.
	   *)
	  raise (Error "PGOCaml: crypt password authentication not supported")
      | AuthenticationMD5Password salt ->
	  (*	(* This is a guess at how the salt is used ... *)
		let password = salt ^ password in
		let password = Digest.string password in*)
	  let password = "md5" ^ Digest.to_hex (Digest.string (Digest.to_hex (Digest.string (password ^ user)) ^ salt)) in
	  let msg = new_message 'p' in (* PasswordMessage *)
	  add_string msg password;
	  loop (Some msg)
      | AuthenticationSCMCredential ->
	  fail (Error "PGOCaml: SCM Credential authentication not supported")
      | ErrorResponse err ->
	  pg_error ~conn err
      | NoticeResponse err ->
	  (* XXX Do or print something here? *)
	  loop None
      | _ ->
	  (* Silently ignore unknown or unexpected message types. *)
	  loop None
    in
    loop (Some msg) >>=

    fun () -> return conn
  in
  let detail = [
    "user"; user;
    "database"; database;
    "host"; Option.default "unix" host;
    "port"; string_of_int port;
    "prog"; Sys.executable_name
  ] in
  profile_op uuid "connect" detail do_connect

let close conn =
  let do_close () =
    (* Be nice and send the terminate message. *)
    let msg = new_message 'X' in
    send_message conn msg >>=
    fun () -> Lwt_chan.flush conn.chan >>=
    (* Closes the underlying socket too. *)
    fun () -> return (Lwt_unix.close conn.fd)
  in
  profile_op conn.uuid "close" [] do_close

let set_private_data conn data =
  conn.private_data <- Some data

let private_data { private_data = private_data } =
  match private_data with
  | None -> raise Not_found
  | Some private_data -> private_data

(* generic code removed *)
let ping conn =
  let msg = new_message 'S' in
  send_message conn msg >>=
  fun () ->

  (* Wait for ReadyForQuery. *)
  let rec loop () =
    receive_message conn >>=
    fun x -> let msg = parse_backend_message x in
    match msg with
    | ReadyForQuery _ -> return () (* Finished! *)
    | ErrorResponse err -> pg_error ~conn err (* Error *)
    | _ -> loop ()
  in
  profile_op conn.uuid "ping" [] loop

(* generic code removed *)

let flush_msg conn =
  let msg = new_message 'H' in
  send_message conn msg >>=
  (* Might as well actually flush the channel too, otherwise what is the
   * point of executing this command?
   *)
  fun () -> Lwt_chan.flush conn.chan

let prepare conn ~query ?(name = "") ?(types = []) () =
  let do_prepare () =
		eprintf "[PGOCaml] [%s] do_prepare\n%!" conn.uuid;
    let msg = new_message 'P' in
    add_string msg name;
    add_string msg query;
    add_int16 msg (List.length types);
    List.iter (add_int32 msg) types;
    send_message conn msg >>=
    fun () -> flush_msg conn >>=
    fun () -> let rec loop () =
      receive_message conn >>=
      fun x -> return (parse_backend_message x) >>=
      fun msg ->
      match msg with
      | ErrorResponse err -> pg_error err
      | ParseComplete -> return () (* Finished! *)
      | NoticeResponse _ ->
	  (* XXX Do or print something here? *)
	  loop ()
      | _ ->
	  fail (Error ("PGOCaml: unknown response from parse: " ^
			  string_of_msg_t msg))
    in
    loop ()
  in
  let details = [ "query"; query; "name"; name ] in
  profile_op conn.uuid "prepare" details do_prepare

let execute conn ?(name = "") ?(portal = "") ~params () =
  let do_execute () =
    eprintf "[PGOCaml] [%s] do_execute\n%!" conn.uuid;
		(* Bind *)
    let msg = new_message 'B' in
    add_string msg portal;
    add_string msg name;
    add_int16 msg 0; (* Send all parameters as text. *)
    add_int16 msg (List.length params);
    List.iter (
      fun param ->
	match param with
	| None -> add_int32 msg 0xffff_ffffl (* NULL *)
	| Some str ->
	    add_int32 msg (Int32.of_int (String.length str));
	    add_string_no_trailing_nil msg str
    ) params;
    add_int16 msg 0; (* Send back all results as text. *)
    send_message conn msg >>=
    fun () ->

    (* Execute *)
    let msg = new_message 'E' in
    add_string msg portal;
    add_int32 msg 0l; (* no limit on rows *)
    send_message conn msg >>=
    fun () ->

    (* Sync *)
    let msg = new_message 'S' in
    send_message conn msg >>=
    fun () ->

    (* Process the message(s) received from the database until we read
     * ReadyForQuery.  In the process we may get some rows back from
     * the database, no data, or an error.
     *)
    let rows = ref [] in
    let rec loop () =
      (* NB: receive_message flushes the output connection. *)
      receive_message conn >>=
      fun x -> return (parse_backend_message x) >>=
      fun msg -> match msg with
      | ReadyForQuery _ -> return () (* Finished! *)
      | ErrorResponse err -> pg_error ~conn err (* Error *)
      | NoticeResponse err ->
	  (* XXX Do or print something here? *)
	  loop ()
      | BindComplete -> loop ()
      | CommandComplete _ -> loop ()
      | EmptyQueryResponse -> loop ()
      | DataRow fields ->
	  let fields = List.map (
	    function
	    | (i, _) when i < 0 -> None (* NULL *)
	    | (0, _) -> Some ""
	    | (i, bytes) -> Some bytes
	  ) fields in
	  rows := fields :: !rows;
	  loop ()
      | NoData -> loop ()
      | ParameterStatus _ ->
	  (* 43.2.6: ParameterStatus messages will be generated whenever
	   * the active value changes for any of the parameters the backend
	   * believes the frontend should know about. Most commonly this
	   * occurs in response to a SET SQL command executed by the
	   * frontend, and this case is effectively synchronous -- but it
	   * is also possible for parameter status changes to occur because
	   * the administrator changed a configuration file and then sent
	   * the SIGHUP signal to the postmaster.
	   *)
	  loop ()
      | _ ->
	  fail
	    (Error ("PGOCaml: unknown response message: " ^
		      string_of_msg_t msg))
    in
    loop () >>=

    (* Return the result rows. *)
			fun () -> return (List.rev !rows)
  in
  (* We used to append the parameters here, but that leads to
   * problems with parsing, and may leak sensitive data.  In any
   * case the profiling program doesn't care about the actual
   * parameters.
   *)
  let details = [ "name"; name; "portal"; portal ] in
  profile_op conn.uuid "execute" details do_execute

let begin_work conn =
  let query = "begin work" in
	lock_connection conn;
  prepare conn ~query () >>=
  fun () -> execute conn ~params:[] () >>=
  fun _ -> unlock_connection conn; return ()

let commit conn =
  let query = "commit" in
	lock_connection conn;
  prepare conn ~query () >>=
  fun () -> execute conn ~params:[] () >>=
  fun _ -> unlock_connection conn; return ()

let rollback conn =
  let query = "rollback" in
	lock_connection conn;
  prepare conn ~query () >>=
  fun () -> execute conn ~params:[] () >>=
  fun _ -> unlock_connection conn; return ()

let serial conn name =
  let query = "select currval ($1)" in
	lock_connection conn;
  prepare conn ~query () >>=
  fun () -> execute conn ~params:[Some name] () >>=
  fun rows -> 
  let row = List.hd rows in
  let result = List.hd row in
  (* NB. According to the manual, the return type of currval is
   * always a bigint, whether or not the column is serial or bigserial.
   *)
	 unlock_connection conn;
  return (Int64.of_string (Option.get result))

let serial4 conn name =
  serial conn name >>=
  fun x -> return (Int64.to_int32 x)

let serial8 = serial

let close_statement conn ?(name = "") () =
  let msg = new_message 'C' in
  add_char msg 'S';
  add_string msg name;
  send_message conn msg >>=
  fun () -> flush_msg conn >>=
  fun () -> 
  let rec loop () =
    receive_message conn >>=
    fun x -> return (parse_backend_message x) >>=
    fun msg ->
    match msg with
    | ErrorResponse err -> pg_error err
    | CloseComplete -> return () (* Finished! *)
    | NoticeResponse _ ->
	(* XXX Do or print something here? *)
	loop ()
    | _ ->
	fail (Error ("PGOCaml: unknown response from close: " ^
			string_of_msg_t msg))
  in
  loop ()

let close_portal conn ?(portal = "") () =
  let msg = new_message 'C' in
  add_char msg 'P';
  add_string msg portal;
  send_message conn msg >>=
  fun () -> flush_msg conn >>=
  fun () -> let rec loop () =
  receive_message conn >>=
  fun x -> return (parse_backend_message x) >>=
  fun msg ->
    match msg with
    | ErrorResponse err -> pg_error err
    | CloseComplete -> return ()
    | NoticeResponse _ ->
	(* XXX Do or print something here? *)
	loop ()
    | _ ->
	fail (Error ("PGOCaml: unknown response from close: " ^
			string_of_msg_t msg))
  in
  loop ()

(* generic code removed *)
let describe_statement conn ?(name = "") () =
  let msg = new_message 'D' in
  add_char msg 'S';
  add_string msg name;
  send_message conn msg >>=
  fun () -> flush_msg conn >>=
  fun () -> receive_message conn >>=
  fun x -> return (parse_backend_message x) >>=
  fun msg ->
    (match msg with
    | ErrorResponse err -> pg_error err
    | ParameterDescription params ->
	let params = List.map (
	  fun oid ->
	    { param_type = oid }
	) params in
	return params
    | _ ->
	fail (Error ("PGOCaml: unknown response from describe: " ^
			string_of_msg_t msg))) >>=
	fun params -> receive_message conn >>=
  fun x -> return (parse_backend_message x) >>=
  fun msg ->
  match msg with
  | ErrorResponse err -> pg_error err
  | NoData -> return (params, None)
  | RowDescription fields ->
      let fields = List.map (
	fun (name, table, column, oid, length, modifier, _) ->
	  {
	    name = name;
	    table = if table = 0l then None else Some table;
	    column = if column = 0 then None else Some column;
	    field_type = oid;
	    length = length;
	    modifier = modifier;
	  }
      ) fields in
      return (params, Some fields)
  | _ ->
      raise (Error ("PGOCaml: unknown response from describe: " ^
		      string_of_msg_t msg))

let describe_portal conn ?(portal = "") () =
  let msg = new_message 'D' in
  add_char msg 'P';
  add_string msg portal;
  send_message conn msg >>=
  fun () -> flush_msg conn >>= 
  fun () -> receive_message conn >>=
  fun x -> return (parse_backend_message x) >>=
  fun msg ->
  match msg with
  | ErrorResponse err -> pg_error err
  | NoData -> return None
  | RowDescription fields ->
      let fields = List.map (
	fun (name, table, column, oid, length, modifier, _) ->
	  {
	    name = name;
	    table = if table = 0l then None else Some table;
	    column = if column = 0 then None else Some column;
	    field_type = oid;
	    length = length;
	    modifier = modifier;
	  }
      ) fields in
      return (Some fields)
  | _ ->
      raise (Error ("PGOCaml: unknown response from describe: " ^
		      string_of_msg_t msg))

(* generic code removed *)
