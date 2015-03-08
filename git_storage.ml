(* Copyright (C) 2015, Thomas Leonard.
 * See the README file for details. *)

open Lwt

module Make (I : Irmin.BASIC with type key = string list and type value = string) = struct
  module V = Irmin.View(I)

  type repo = {
    config: Irmin.config;
    task_maker: string -> Irmin.task;
  }

  type commit = {
    c_repo : repo;
    c_store : string -> I.t;
  }

  module Staging = struct
    type t = {
      commit : commit option;
      view : V.t;
    }

    let empty () = V.empty () >|= fun view -> {commit = None; view}
    let list t = V.list t.view
    let read_exn t = V.read_exn t.view
    let update t = V.update t.view
    let remove t = V.remove t.view
  end

  module Commit = struct
    type t = commit

    type id = Irmin.Hash.SHA1.t

    module History = I.History

    let id t =
      match I.branch (t.c_store "get commit ID") with
      | `Tag _ -> assert false
      | `Head id -> id

    let equal a b =
      id a = id b

    let of_id repo id =
      I.of_head repo.config repo.task_maker id >|= fun c_store ->
      {c_repo = repo; c_store}

    let checkout t =
      V.of_path (t.c_store "Make view") I.Key.empty >|= fun view ->
      {Staging.commit = Some t; view}

    let commit staging ~msg =
      match staging.Staging.commit with
      | None -> assert false
      | Some t ->
      I.of_head t.c_repo.config t.c_repo.task_maker (id t) >>= fun tmp_branch ->
      V.update_path (tmp_branch msg) I.Key.empty staging.Staging.view >|= fun () ->
      {t with c_store = tmp_branch}

    let history ?depth t =
      I.history ?depth (t.c_store "Read history")

    let merge a b =
      I.of_head a.c_repo.config a.c_repo.task_maker (id a) >>= fun tmp ->
      I.merge_head (tmp "Merge") (id b) >|= function
      | `Ok () -> `Ok {a with c_store = tmp}
      | `Conflict _ as c -> c
  end

  module Branch = struct
    type t = {
      repo : repo;
      store : string -> I.t;
      mutex : Lwt_mutex.t;
      head_id : Commit.id option ref;
      head : Commit.t option React.S.t;
    }

    let opt_commit_equal a b =
      match a, b with
      | Some a, Some b -> Commit.equal a b
      | None, None -> true
      | _ -> false

    let initialise store fn =
      Staging.empty () >>= fun staging ->
      fn staging >>= fun () ->
      V.update_path (store "Initialise repository") I.Key.empty staging.Staging.view >>= fun () ->
      I.head_exn (store "Get initial commit")

    let of_store repo store ~if_new =
      match I.branch (store "Get branch name") with
      | `Head _ -> failwith "Not a tag!"
      | `Tag branch_name ->
      let commit_of_id = function
        | None -> return None
        | Some id -> Commit.of_id repo id >|= fun commit -> Some commit in
      (* Start watching for updates (must do this BEFORE getting the initial commit) *)
      let mutex = Lwt_mutex.create () in
      let watch_tags = I.watch_tags (store "Watch branch") in
      I.head (store "Get latest commit") >>= fun initial_head_id ->
      let initial_head_id =
        match initial_head_id with
        | None -> initialise store if_new
        | Some id -> return id in
      initial_head_id >>= fun initial_head_id ->
      let head_id = ref (Some initial_head_id) in
      Commit.of_id repo initial_head_id >>= fun initial_head ->
      let head, set_head = React.S.create ~eq:opt_commit_equal (Some initial_head) in
      async (fun () ->
        watch_tags |> Lwt_stream.iter_s (function
          | (n, Some _id) when n = branch_name ->
              (* (ignore the commit ID in the update message; we want the latest) *)
              I.head (store "Get latest commit") >>= fun new_head_id ->
              if new_head_id <> !head_id then (
                head_id := new_head_id;
                commit_of_id new_head_id >|= set_head
              ) else return ()
          | _ -> return ()
        )
      );
      return {
        repo;
        store;
        head_id;
        head;
        mutex;
      }

    let head t = t.head

    let fast_forward_to t commit =
      let commit_id = Commit.id commit in
      I.lcas_head (t.store "Check fast-forward") commit_id >>= function
      | `Max_depth_reached -> failwith "Max_depth_reached"    (* XXX: this actually happens *)
      | `Too_many_lcas -> failwith "Too_many_lcas"
      | `Ok lcas ->
          let expected = !(t.head_id) in
          if List.exists (fun common -> Some common = expected) lcas then (
            (* XXX: race *)
            I.update_head (t.store "Fast-forward") commit_id >>= fun () ->
            return `Ok
          ) else (
            return `Not_fast_forward
          )
  end

  module Repository = struct
    type t = repo

    let branch t ~if_new name =
      I.of_tag t.config t.task_maker name >>= Branch.of_store t ~if_new
  end

  let make config task_maker = {config; task_maker}
end
