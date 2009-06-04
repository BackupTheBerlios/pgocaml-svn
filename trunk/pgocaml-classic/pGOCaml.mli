(* PG'OCaml is a set of OCaml bindings for the PostgreSQL database.
 *
 * PG'OCaml - type safe interface to PostgreSQL.
 * Copyright (C) 2005-2008 Richard Jones and other authors.
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

open CalendarLib

type 'a t				(** Database handle. *)

exception Error of string
(** For library errors. *)

exception PostgreSQL_Error of string * (char * string) list
(** For errors generated by the PostgreSQL database back-end.  The
  * first argument is a printable error message.  The second argument
  * is the complete set of error fields returned from the back-end.
  * See [http://www.postgresql.org/docs/8.1/static/protocol-error-fields.html]
  *)

(** {6 Connection management} *)

val connect : ?host:string -> ?port:int -> ?user:string -> ?password:string -> ?database:string -> ?unix_domain_socket_dir:string -> unit -> 'a t
(** Connect to the database.  The normal [$PGDATABASE], etc. environment
  * variables are available.
  *)

val close : 'a t -> unit
(** Close the database handle.  You must call this after you have
  * finished with the handle, or else you will get leaked file
  * descriptors.
  *)

val ping : 'a t -> unit
(** Ping the database.  If the database is not available, some sort of
  * exception will be thrown.
  *)

(** {6 Transactions} *)

val begin_work : 'a t -> unit
(** Start a transaction. *)

val commit : 'a t -> unit
(** Perform a COMMIT operation on the database. *)

val rollback : 'a t -> unit
(** Perform a ROLLBACK operation on the database. *)

(** {6 Serial column} *)

val serial : 'a t -> string -> int64
(** This is a shorthand for [SELECT CURRVAL(serial)].  For a table
  * called [table] with serial column [id] you would typically
  * call this as [serial dbh "table_id_seq"] after the previous INSERT
  * operation to get the serial number of the inserted row.
  *)

val serial4 : 'a t -> string -> int32
(** As {!PGOCaml.serial} but assumes that the column is a SERIAL or
  * SERIAL4 type.
  *)

val serial8 : 'a t -> string -> int64
(** Same as {!PGOCaml.serial}.
  *)

(** {6 Miscellaneous} *)

val max_message_length : int ref
(** Maximum message length accepted from the back-end.  The default
  * is [Sys.max_string_length], which means that we will try to read as
  * much data from the back-end as we can, and this may cause us to
  * run out of memory (particularly on 64 bit machines), causing a
  * possible denial of service.  You may want to set this to a smaller
  * size to avoid this happening.
  *)

val verbose : int ref
(** Verbosity.  0 means don't print anything.  1 means print short
  * error messages as returned from the back-end.  2 means print all
  * messages as returned from the back-end.  Messages are printed on [stderr].
  * Default verbosity level is 1.
  *)

val set_private_data : 'a t -> 'a -> unit
(** Attach some private data to the database handle.
  *
  * NB. The pa_pgsql camlp4 extension uses this for its own purposes, which
  * means that in most programs you will not be able to attach private data
  * to the database handle.
  *)

val private_data : 'a t -> 'a
(** Retrieve some private data previously attached to the database handle.
  * If no data has been attached, raises [Not_found].
  *
  * NB. The pa_pgsql camlp4 extension uses this for its own purposes, which
  * means that in most programs you will not be able to attach private data
  * to the database handle.
  *)

type pa_pg_data = (string, bool) Hashtbl.t
(** When using pa_pgsql, database handles have type
  * [PGOCaml.pa_pg_data PGOCaml.t]
  *)

(** {6 Low level query interface - DO NOT USE DIRECTLY} *)

type oid = int32

type param = string option (** None is NULL. *)
type result = string option (** None is NULL. *)
type row = result list (** One row is a list of fields. *)

val prepare : 'a t -> query:string -> ?name:string -> ?types:oid list -> unit -> unit
(** [prepare conn ~query ?name ?types ()] prepares the statement [query]
  * and optionally names it [name] and sets the parameter types to [types].
  * If no name is given, then the "unnamed" statement is overwritten.  If
  * no types are given, then the PostgreSQL engine infers types.
  * Synchronously checks for errors.
  *)

val execute_rev : 'a t -> ?name:string -> ?portal:string -> params:param list -> unit -> row list
val execute : 'a t -> ?name:string -> ?portal:string -> params:param list -> unit -> row list
(** [execute conn ?name ~params ()] executes the named or unnamed
  * statement [name], with the given parameters [params],
  * returning the result rows (if any).
  *
  * There are several steps involved at the protocol layer:
  * (1) a "portal" is created from the statement, binding the
  * parameters in the statement (Bind).
  * (2) the portal is executed (Execute).
  * (3) we synchronise the connection (Sync).
  *
  * The optional [?portal] parameter may be used to name the portal
  * created in step (1) above (otherwise the unnamed portal is used).
  * This is only important if you want to call {!PGOCaml.describe_portal}
  * to find out the result types.
  *)

val close_statement : 'a t -> ?name:string -> unit -> unit
(** [close_statement conn ?name ()] closes a prepared statement and frees
  * up any resources.
  *)

val close_portal : 'a t -> ?portal:string -> unit -> unit
(** [close_portal conn ?portal ()] closes a portal and frees up any resources.
  *)

type row_description = result_description list
and result_description = {
  name : string;			(** Field name. *)
  table : oid option;			(** OID of table. *)
  column : int option;			(** Column number of field in table. *)
  field_type : oid;			(** The type of the field. *)
  length : int;				(** Length of the field. *)
  modifier : int32;			(** Type modifier. *)
}

type params_description = param_description list
and param_description = {
  param_type : oid;			(** The type of the parameter. *)
}

val describe_statement : 'a t -> ?name:string -> unit -> params_description * row_description option
(** [describe_statement conn ?name ()] describes the named or unnamed
  * statement's parameter types and result types.
  *)

val describe_portal : 'a t -> ?portal:string -> unit -> row_description option
(** [describe_portal conn ?portal ()] describes the named or unnamed
  * portal's result types.
  *)

(** {6 Low level type conversion functions - DO NOT USE DIRECTLY} *)

val name_of_type : ?modifier:int32 -> oid -> string
(** Returns the OCaml equivalent type name to the PostgreSQL type [oid].
  * For instance, [name_of_type (Int32.of_int 23)] returns ["int32"] because
  * the OID for PostgreSQL's internal [int4] type is [23].  As another
  * example, [name_of_type (Int32.of_int 25)] returns ["string"].
  *)

type timestamptz = Calendar.t * Time_Zone.t
type int16 = int
type bytea = string (* XXX *)
type point = float * float
type int32_array = int32 array

val string_of_oid : oid -> string
val string_of_bool : bool -> string
val string_of_int : int -> string
val string_of_int16 : int16 -> string
val string_of_int32 : int32 -> string
val string_of_int64 : int64 -> string
val string_of_float : float -> string
val string_of_point : point -> string
val string_of_timestamp : Calendar.t -> string
val string_of_timestamptz : timestamptz -> string
val string_of_date : Date.t -> string
val string_of_time : Time.t -> string
val string_of_interval : Calendar.Period.t -> string
val string_of_int32_array : int32_array -> string
val string_of_bytea : bytea -> string
val string_of_string : string -> string
val string_of_unit : unit -> string

val bool_of_string : string -> bool
val int_of_string : string -> int
val int16_of_string : string -> int16
val int32_of_string : string -> int32
val int64_of_string : string -> int64
val float_of_string : string -> float
val point_of_string : string -> point
val timestamp_of_string : string -> Calendar.t
val timestamptz_of_string : string -> timestamptz
val date_of_string : string -> Date.t
val time_of_string : string -> Time.t
val interval_of_string : string -> Calendar.Period.t
val int32_array_of_string : string -> int32_array
val bytea_of_string : string -> bytea
val unit_of_string : string -> unit
(** These conversion functions are used by pa_pgsql to convert
  * values in and out of the database.
  *)
