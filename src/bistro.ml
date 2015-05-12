open Core.Std

module Utils = struct
  let load_value fn =
    In_channel.with_file fn ~f:(Marshal.from_channel)

  let save_value fn v =
    Out_channel.with_file fn ~f:(fun oc -> Marshal.to_channel oc v [])

  let with_temp_file ~in_dir ~f =
    let fn = Filename.temp_file ~in_dir "bistro" "" in
    protect ~f:(fun () -> f fn) ~finally:(fun () -> Sys.remove fn)

  type 'a logger = ('a,unit,string,unit) format4 -> 'a

  let null_logger fmt =
    Printf.ksprintf ignore fmt

  let printer oc fmt =
    let open Unix in
    let open Printf in
    ksprintf ident fmt

  let logger (type s) oc label fmt : s logger =
    let open Unix in
    let open Printf in
    let f msg =
      let t = localtime (time ()) in
      fprintf
        oc "[%s][%04d-%02d-%02d %02d:%02d] %s\n%!"
        label (1900 + t.tm_year) (t.tm_mon + 1)t.tm_mday t.tm_hour t.tm_min msg
    in
    ksprintf f fmt

  let sh ?(stdout = stdout) ?(stderr = stderr) cmd =
    try
      Shell.call
        ~stdout:(Shell.to_fd (Unix.descr_of_out_channel stdout))
        ~stderr:(Shell.to_fd (Unix.descr_of_out_channel stderr))
        [ Shell.cmd "sh" [ "-c" ; cmd ] ]
    with Shell.Subprocess_error _ -> (
        Core.Std.failwithf "shell call failed:\n%s\n" cmd ()
      )

  let shf ?(stdout = stdout) ?(stderr = stderr) fmt =
    Printf.ksprintf (sh ~stdout ~stderr) fmt
end

module Pool : sig
  type t

  val create : np:int -> mem:int -> t
  val use : t -> np:int -> mem:int -> f:(np:int -> mem:int -> 'a Lwt.t) -> 'a Lwt.t
end =
struct
  let ( >>= ) = Lwt.( >>= )

  type t = {
    np : int ;
    mem : int ;
    mutable current_np : int ;
    mutable current_mem : int ;
    mutable waiters : ((int * int) * unit Lwt.u) list ;
  }

  let create ~np ~mem = {
    np ; mem ;
    current_np = np ;
    current_mem = mem ;
    waiters = [] ;
  }

  let decr p ~np ~mem =
    p.current_np <- p.current_np - np ;
    p.current_mem <- p.current_mem - mem

  let incr p ~np ~mem =
    p.current_np <- p.current_np + np ;
    p.current_mem <- p.current_mem + mem

  let acquire p ~np ~mem =
    if np <= p.current_np && mem <= p.current_mem then (
      decr p ~np ~mem ;
      Lwt.return ()
    )
    else (
      let t, u = Lwt.wait () in
      p.waiters <- ((np,mem), u) :: p.waiters ;
      t
    )

  let release p ~np ~mem =
    let rec wake_guys_up p = function
      | [] -> []
      | (((np, mem), u) as h) :: t ->
        if np <= p.current_np && mem <= p.current_mem then (
          decr p ~np ~mem ;
          Lwt.wakeup u () ;
          t
        )
        else h :: (wake_guys_up p t)
    in
    incr p ~np ~mem ;
    p.waiters <- wake_guys_up p (List.sort (fun (x, _) (y,_) -> compare y x) p.waiters)

  let use p ~np ~mem ~f =
    if np > p.np then Lwt.fail (Invalid_argument "Bistro.Pool: asked more processors than there are in the pool")
    else if mem > p.mem then Lwt.fail (Invalid_argument "Bistro.Pool: asked more memory than there is in the pool")
    else (
      acquire p ~np ~mem >>= fun () ->
      Lwt.catch
        (fun () ->
           f ~np ~mem >>= fun r -> Lwt.return (`result r))
        (fun exn -> Lwt.return (`error exn))
      >>= fun r ->
      release p ~np ~mem ;
      match r with
      | `result r -> Lwt.return r
      | `error exn -> Lwt.fail exn
    )
end


type 'a path = Path of string

type env = {
  sh : string -> unit ; (** Execute a shell command (with {v /bin/sh v}) *)
  shf : 'a. ('a,unit,string,unit) format4 -> 'a ;
  stdout : out_channel ;
  stderr : out_channel ;
  out : 'a. ('a,out_channel,unit) format -> 'a ;
  err : 'a. ('a,out_channel,unit) format -> 'a ;
  with_temp_file : 'a. (string -> 'a) -> 'a ;
}


type primitive_info = {
  id : string ;
  version : int option ;
} with sexp

type _ workflow =
  | Input : string * string -> 'a path workflow
  | Value_workflow : string * (env -> 'a) term -> 'a workflow
  | Path_workflow : string * (string -> env -> unit) term -> 'a path workflow
  | Extract : string * [`directory of 'a] path workflow * string list -> 'b path workflow

and _ term =
  | Prim : primitive_info * 'a -> 'a term
  | App : ('a -> 'b) term * 'a term * string option -> 'b term
  | String : string -> string term
  | Int : int -> int term
  | Bool : bool -> bool term
  | Workflow : 'a workflow -> 'a term
  | Option : 'a term option -> 'a option term
  | List : 'a term list -> 'a list term

let primitive_info id ?version () = {
  id ; version ;
}

module Term = struct
  type 'a t = 'a term

  let prim id ?version x =
    Prim (primitive_info id ?version (), x)

  let app ?n f x = App (f, x, n)

  let ( $ ) f x = app f x

  let string s = String s
  let int i = Int i
  let bool b = Bool b
  let option f x = Option (Option.map x ~f)
  let list f xs = List (List.map xs ~f)
  let workflow w = Workflow w
end


let digest x =
  Digest.to_hex (Digest.string (Marshal.to_string x []))

module Description = struct
  type workflow =
    | Input of string
    | Value_workflow of term
    | Path_workflow of term
    | Extract of workflow * string list
  and term =
    | Prim of primitive_info
    | App of term * term * string option
    | String of string
    | Int of int
    | Bool of bool
    | Workflow of workflow
    | Option of term option
    | List of term list
  with sexp
end


let rec term_description : type s. s term -> Description.term = function
  | Prim (info, _) -> Description.Prim info

  | App (f, x, lab) ->
    Description.App (term_description f,
                     term_description x,
                     lab)

  | String s -> Description.String s
  | Int i -> Description.Int i
  | Bool b -> Description.Bool b
  | Workflow w -> Description.Workflow (workflow_description w)
  | Option o -> Description.Option (Option.map o ~f:term_description)
  | List l -> Description.List (List.map l ~f:term_description)

and workflow_description : type s. s workflow -> Description.workflow = function
  | Input (_, fn) -> Description.Input fn
  | Value_workflow (_, t) -> Description.Value_workflow (term_description t)
  | Path_workflow (_, t) -> Description.Path_workflow (term_description t)
  | Extract (_, dir, path) -> Description.Extract (workflow_description dir, path)

let sexp_of_workflow w =
  Description.sexp_of_workflow (workflow_description w)

let workflow t = Value_workflow (digest (`workflow (term_description t)), t)
let path_workflow t = Path_workflow (digest (`path_workflow (term_description t)), t)

let rec extract : type s. [`directory of s] path workflow -> string list -> 'a workflow = fun dir path ->
  match dir with
  | Extract (_, dir', path') -> extract dir' (path' @ path)
  | Path_workflow _ -> extract_aux dir path
  | Input (_, fn) -> extract_aux dir path
  | Value_workflow _ -> assert false (* unreachable case, due to typing constraints *)
and extract_aux : type s. [`directory of s] path workflow -> string list -> 'a workflow = fun dir path ->
  let id = digest (`extract (workflow_description dir, path)) in
  Extract (id, dir , path)

let input fn = Input (digest (`input fn), fn)

let id : type s. s workflow -> string = function
  | Input (id, fn) -> id
  | Value_workflow (id, _) -> id
  | Path_workflow (id, _) -> id
  | Extract (id, _, _) -> id






module Db = struct

  type t = string

  let cache_dir base = Filename.concat base "cache"
  let build_dir base = Filename.concat base "build"
  let tmp_dir base = Filename.concat base "tmp"
  let stderr_dir base = Filename.concat base "stderr"
  let stdout_dir base = Filename.concat base "stdout"
  let log_dir base = Filename.concat base "logs"
  let history_dir base = Filename.concat base "history"
  let description_dir base = Filename.concat base "description"

  let well_formed_db path =
    if Sys.file_exists_exn path then (
      Sys.file_exists_exn (cache_dir path)
      && Sys.file_exists_exn (build_dir path)
      && Sys.file_exists_exn (tmp_dir path)
      && Sys.file_exists_exn (stderr_dir path)
      && Sys.file_exists_exn (stdout_dir path)
      && Sys.file_exists_exn (log_dir path)
      && Sys.file_exists_exn (history_dir path)
      && Sys.file_exists_exn (description_dir path)
    )
    else false

  let init base =
    if Sys.file_exists_exn base
    then (
      if not (well_formed_db base)
      then invalid_argf "Bistro_db.init: the path %s is not available for a bistro database" base ()
    )
    else (
      Unix.mkdir_p (tmp_dir base) ;
      Unix.mkdir_p (build_dir base) ;
      Unix.mkdir_p (cache_dir base) ;
      Unix.mkdir_p (stderr_dir base) ;
      Unix.mkdir_p (stdout_dir base) ;
      Unix.mkdir_p (log_dir base) ;
      Unix.mkdir_p (history_dir base) ;
      Unix.mkdir_p (description_dir base)
    ) ;
    base

  let aux_path f db w =
    Filename.concat (f db) (id w)

  let log_path db w = aux_path log_dir db w
  let build_path db w = aux_path build_dir db w
  let tmp_path db w = aux_path tmp_dir db w
  let stdout_path db w = aux_path stdout_dir db w
  let stderr_path db w = aux_path stderr_dir db w
  let history_path db w = aux_path history_dir db w
  let description_path db w = aux_path description_dir db w

  let rec cache_path : type s. t -> s workflow -> string = fun db -> function
    | Extract (_, dir, p) ->
      List.fold (cache_path db dir :: p) ~init:"" ~f:Filename.concat
    | _ as w -> aux_path cache_dir db w


  let used_tag = "U"
  let created_tag = "C"

  let history_tag_of_string x =
    if x = used_tag then `used
    else if x = created_tag then `created
    else invalid_argf "Bistro.Db.history_tag_of_string: %s" x ()

  let append_history ~db ~msg u =
    Out_channel.with_file ~append:true (history_path db u) ~f:(fun oc ->
        let time_stamp = Time.to_string_fix_proto `Local (Time.now ()) in
        fprintf oc "%s: %s\n" time_stamp msg
      )

  let rec used : type s. t -> s workflow -> unit = fun db -> function
      | Extract (_, u, _) -> used db u
      | _ as w -> append_history ~db ~msg:used_tag w

  let created : type s. t -> s workflow -> unit = fun db -> function
      | Extract _ -> assert false
      | _ as u -> append_history ~db ~msg:created_tag u

  let parse_history_line l =
    let stamp, tag = String.lsplit2_exn l ~on:':' in
    Time.of_string_fix_proto `Local stamp,
    history_tag_of_string (String.lstrip tag)

  let rec history : type s. t -> s workflow -> (Core.Time.t * [`created | `used]) list = fun db -> function
      | Extract (_, dir, _) -> history db dir
      | _ as u ->
        let p_u = history_path db u in
        if Sys.file_exists_exn p_u then
          List.map (In_channel.read_lines p_u) ~f:parse_history_line
        else
          []

  let echo ~path msg =
    Out_channel.with_file ~append:true path ~f:(fun oc ->
        output_string oc msg ;
        output_string oc "\n"
      )

  let log db fmt =
    let f msg =
      let path =
        Filename.concat
          (log_dir db)
          (Time.format (Time.now ()) "%Y-%m-%d.log")
      in
      echo ~path msg
    in
    Printf.ksprintf f fmt
end

(* type 'a iterator = { f : 'b. 'a -> 'b workflow -> 'a } *)

(* let rec fold_deps_in_term : type s. s term -> init:'a -> it:'a iterator -> 'a = fun t ~init ~it -> *)
(*   match t with *)
(*   | String _ -> init *)
(*   | Int _ -> init *)
(*   | Bool _ -> init *)
(*   | Option None -> init *)
(*   | Prim _ -> init *)
(*   | App (f, x, _) -> *)
(*     let init = fold_deps_in_term f ~init ~it in *)
(*     fold_deps_in_term x ~init ~it *)
(*   | Value_workflow w -> it.f init w *)
(*   | Option (Some t) -> *)
(*     fold_deps_in_term t ~init ~it *)
(*   | List ts -> *)
(*     List.fold ts ~init ~f:(fun accu t -> fold_deps_in_term t ~init:accu ~it) *)

(* let rec fold_deps : type s. s workflow -> init:'a -> it:'a iterator -> 'a = fun w ~init ~it -> *)
(*   match w with *)
(*   | Value_workflow t -> fold_deps_in_term t ~init ~it *)
(*   | File t -> fold_deps_in_term t ~init ~it *)
(*   | Directory t -> fold_deps_in_term t ~init ~it *)
(*   | Extract (dir, path) -> fold_deps dir ~init ~it *)

let remove_if_exists fn =
  if Sys.file_exists_exn fn
  then Sys.command (sprintf "rm -r %s" fn) |> ignore

module type Configuration = sig
  val db_path : string
  val np : int
  val mem : int
end

module Engine(Conf : Configuration) = struct
  open Lwt

  let db = Db.init Conf.db_path

  let worker_pool =
    if !Sys.interactive then None
    else Some (fst (Nproc.create Conf.np))

  let submit f =
    match worker_pool with
    | None ->
      Lwt_preemptive.detach f () >|= fun x -> Some x
    | Some pool ->
      Nproc.submit pool ~f ()

  let np = match worker_pool with
    | None -> 1
    | Some _ -> Conf.np

  let mem = Conf.mem

  let resource_pool = Pool.create ~np ~mem

  let with_env ~np ~mem x ~f =
    let stderr = open_out (sprintf "%s/%s" (Db.stderr_dir Conf.db_path) (id x)) in
    let stdout = open_out (sprintf "%s/%s" (Db.stdout_dir Conf.db_path) (id x)) in
    let env = {
      stderr ; stdout ;
      out = (fun fmt -> fprintf stdout fmt) ;
      err = (fun fmt -> fprintf stderr fmt) ;
      shf = (fun fmt -> Utils.shf ~stdout ~stderr fmt) ;
      sh = Utils.sh ~stdout ~stderr ;
      with_temp_file = fun f -> Utils.with_temp_file ~in_dir:(Db.tmp_dir Conf.db_path) ~f
    }
    in
    protect ~f:(fun () -> f env) ~finally:(fun () ->
        List.iter ~f:Out_channel.close [ stderr ; stdout ]
      )

  let send_task w deps (t : env -> [`Ok | `Error of string]) =
    deps >>= fun () ->
    Pool.use resource_pool ~np:1 ~mem:100 ~f:(fun ~np ~mem ->
        let f () = with_env ~np ~mem w ~f:t in
        submit f >>= function
        | Some `Ok -> Lwt.return ()
        | Some (`Error msg) -> Lwt.fail (Failure msg)
        | None -> Lwt.fail (Failure "A primitive raised an unknown exception")
      )

  (* Wrapping around a task, implementing:
     - removing previous stdout stderr tmp
     - moving from build to cache and clearing tmp
       if the task succeeded
  *)
  let create_task x (f : env -> unit) =
    let stdout_path = Db.stdout_path db x in
    let stderr_path = Db.stderr_path db x in
    let tmp_path    = Db.tmp_path    db x in
    let build_path  = Db.build_path  db x in
    let cache_path  = Db.cache_path  db x in
    fun env ->
      remove_if_exists stdout_path ;
      remove_if_exists stderr_path ;
      remove_if_exists build_path  ;
      remove_if_exists tmp_path    ;
      Out_channel.with_file (Db.description_path db x) ~f:(fun oc ->
          Sexplib.Sexp.output_hum_indent 2 oc (sexp_of_workflow x)
        ) ;
      Unix.mkdir tmp_path ;
      let outcome = try f env ; `Ok with exn -> `Error exn in
      match outcome, Sys.file_exists_exn build_path with
      | `Ok, true ->
        remove_if_exists tmp_path ;
        Unix.rename build_path cache_path ;
        `Ok
      | `Ok, false ->
        let msg = sprintf "Workflow %s failed to produce its target at the prescribed location" (id x) in
        `Error msg
      | `Error (Failure msg), _ ->
        let msg = sprintf "Workflow %s failed saying: %s" (id x) msg in
        `Error msg
      | `Error exn, _ -> raise exn

  (* Currently Building Workflows

     If two threads try to concurrently eval a workflow, we don't want
     the build procedure to be executed twice. So when the first
     thread tries to eval the workflow, we store the build thread in a
     hash table. When the second thread tries to eval, we give the
     build thread in the hash table, which prevents the workflow from
     being built twice concurrently.

  *)
  module CBW = struct
    module W = struct
      type t = W : _ workflow -> t
      let equal (W x) (W y) = id x = id y
      let hash (W x) = String.hash (id x)
    end

    module T = Caml.Hashtbl.Make(W)

    type contents =
      | Thread of unit Lwt.t

    let table : contents T.t = T.create 253


    let find_or_add x f =
      match T.find table (W.W x) with
      | Thread t -> t
      | exception Not_found ->
        let waiter, u = Lwt.wait () in
        T.add table (W.W x) (Thread waiter) ;
        f () >>= fun () ->
        T.remove table (W.W x) ;
        Lwt.wakeup u () ;
        Lwt.return ()
  end



  let rec build : type s. s workflow -> unit Lwt.t = fun w ->
    CBW.find_or_add w (fun () ->
        match w with
        | Input (_, fn) -> build_input fn

        | Extract (_, dir, path_in_dir) ->
          build_extract (Db.cache_path db w) dir path_in_dir

        | Path_workflow (_, term_w) ->
          build_path_workflow w term_w

        | Value_workflow (_, term_w) ->
          build_workflow w term_w
      )

  and build_input fn =
    let f () =
      if not (Sys.file_exists_exn fn)
      then failwithf "File %s is declared as an input of a workflow but does not exist." fn ()
    in
    Lwt.wrap f

  and build_extract : type s. string -> s workflow -> string list -> unit Lwt.t =
    fun output dir path_in_dir ->
      let dir_path = Db.cache_path db dir in
      (* Checks the file to extract of the directory is there *)
      let check_in_dir () =
        if not (Sys.file_exists_exn output)
        then (
          let msg = sprintf "No file or directory named %s in directory workflow." (String.concat ~sep:"/" path_in_dir) in
          Lwt.fail (Failure msg)
        )
        else Lwt.return ()
      in
      if Sys.file_exists_exn dir_path then (
        Db.used db dir ;
        check_in_dir ()
      )
      else build dir >>= check_in_dir

  and build_path_workflow : type s. s workflow -> (string -> env -> unit) Term.t -> unit Lwt.t =
    fun w term_w ->
      let cache_path = Db.cache_path db w in
      if Sys.file_exists_exn cache_path then (
        Db.used db w ;
        Lwt.return ()
      )
      else
        let thunk, deps = compile_term term_w in
        let build_path = Db.build_path db w in
        let f env = (thunk ()) build_path env in
        send_task w deps (create_task w f)

  and build_workflow : type s. s workflow -> (env -> s) Term.t -> unit Lwt.t =
    fun w term_w ->
      let cache_path = Db.cache_path db w in
      if Sys.file_exists_exn cache_path then (
        Db.used db w ;
        Lwt.return ()
      )
      else
        let thunk, deps = compile_term term_w in
        let build_path = Db.build_path db w in
        let f env =
          let y = (thunk ()) env in
          Utils.save_value build_path y
        in
        send_task w deps (create_task w f)

  and compile_term : type s. s term -> (unit -> s) * unit Lwt.t = function
    | Prim (_, v) -> const v, Lwt.return ()
    | App (f, x, _) ->
      let ff, f_deps = compile_term f in
      let xx, x_deps = compile_term x in
      (fun () -> (ff ()) (xx ())),
      Lwt.join [ f_deps ; x_deps ]
    | Int i -> const i, Lwt.return ()
    | String s -> const s, Lwt.return ()
    | Bool b -> const b, Lwt.return ()
    | Option None -> const None, Lwt.return ()
    | Option (Some t) ->
      let tt,t_deps = compile_term t in
      (fun () -> Some (tt ())), t_deps
    | List ts ->
      let tts, deps = List.map ts ~f:compile_term |> List.unzip in
      (fun () -> List.map tts ~f:(fun ff -> ff ())),
      Lwt.join deps

    | Workflow (Value_workflow _ as w) ->
      (fun () -> Utils.load_value (Db.cache_path db w)),
      build w

    | Workflow (Path_workflow _ as w) ->
      (fun () -> Path (Db.cache_path db w)),
      build w

    | Workflow (Input (_, fn)) ->
      (fun () -> Path fn),
      Lwt.return ()

    | Workflow (Extract _ as w) ->
      (fun () -> Path (Db.cache_path db w)),
      Lwt.return ()

  and primitive_info_of_term : type s. s term -> primitive_info option = function
    | Prim (pi, _) -> Some pi
    | App (f, _, _) -> primitive_info_of_term f
    | _ -> None

  let eval : type s. s workflow -> s Lwt.t = fun w ->
    let path = Db.cache_path db w in
    let return_value : type s. s workflow -> s Lwt.t = function
      | Input (_, fn) -> Lwt.return (Path fn)
      | Extract _ -> Lwt.return (Path path)
      | Path_workflow (_, t) -> Lwt.return (Path path)
      | Value_workflow (_, t) ->
        Lwt_io.(with_file ~mode:Input path read_value)
    in
    build w >>= fun () -> return_value w

end
