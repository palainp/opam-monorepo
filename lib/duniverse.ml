open Import

type unresolved = Git.Ref.t
type resolved = Git.Ref.resolved

module Repo = struct
  module Url = struct
    type 'ref t = Git of { repo : string; ref : 'ref } | Other of string

    let equal equal_ref t t' =
      match (t, t') with
      | Git { repo; ref }, Git { repo = repo'; ref = ref' } ->
          String.equal repo repo' && equal_ref ref ref'
      | Other s, Other s' -> String.equal s s'
      | _ -> false

    let compare compare_ref t t' =
      match (t, t') with
      | Git _, Other _ -> Base.Ordering.to_int Base.Ordering.Less
      | Other _, Git _ -> Base.Ordering.to_int Base.Ordering.Greater
      | Git { repo; ref }, Git { repo = repo'; ref = ref' } -> (
          let c1 = String.compare repo repo' in
          match Base.Ordering.of_int c1 with
          | Base.Ordering.Less | Greater -> c1
          | Equal -> compare_ref ref ref')
      | Other s, Other s' -> String.compare s s'

    let pp pp_ref fmt t =
      let open Pp_combinators.Ocaml in
      match t with
      | Git { repo; ref } ->
          Format.fprintf fmt
            "@[<hov 2>Git@ @[<hov 2>{ repo = %a;@ ref = %a }@]@]" string repo
            pp_ref ref
      | Other s -> Format.fprintf fmt "@[<hov 2>Other@ %a@]" string s

    let opam_url_from_string s =
      OpamUrl.parse ~from_file:true ~handle_suffix:false s

    let to_string : resolved t -> string = function
      | Other s -> s
      | Git { repo; ref = { Git.Ref.commit; _ } } ->
          Printf.sprintf "%s#%s" repo commit

    let to_opam_url t = opam_url_from_string (to_string t)

    let from_opam_url opam_url =
      match Opam.Url.from_opam opam_url with
      | Opam.Url.Other s -> Ok (Other s)
      | Opam.Url.Git { repo; ref = Some commit } ->
          Ok (Git { repo; ref = { Git.Ref.t = commit; commit } })
      | _ -> Error (`Msg "Git URL must be resolved to a commit hash")
  end

  module Package = struct
    module Dev_repo = struct
      type t = string

      let equal a b =
        let a = a |> Uri.of_string |> Uri_utils.Normalized.of_uri in
        let b = b |> Uri.of_string |> Uri_utils.Normalized.of_uri in
        Uri_utils.Normalized.equal a b
    end

    type t = {
      opam : OpamPackage.t;
      dev_repo : Dev_repo.t;
      url : unresolved Url.t;
      hashes : OpamHash.t list;
      dune_packages : string list;
    }

    let equal t t' =
      OpamPackage.equal t.opam t'.opam
      && Dev_repo.equal t.dev_repo t'.dev_repo
      && Url.equal Git.Ref.equal t.url t'.url

    let pp fmt { opam; dev_repo; url; hashes; dune_packages } =
      let open Pp_combinators.Ocaml in
      Format.fprintf fmt
        "@[<hov 2>{ opam = %a;@ dev_repo = %a;@ url = %a;@ hashes = %a;@ \
         dune_packages = %a }@]"
        Opam.Pp.raw_package opam string dev_repo (Url.pp Git.Ref.pp) url
        (list Opam.Pp.hash) hashes (list string) dune_packages

    let from_package_summary ~get_default_branch ps =
      let open Opam.Package_summary in
      let open Result.O in
      let url ourl =
        match (ourl : Opam.Url.t) with
        | Other s -> Ok (Url.Other s)
        | Git { repo; ref = Some ref } -> Ok (Url.Git { repo; ref })
        | Git { repo; ref = None } ->
            let* ref = get_default_branch repo in
            Ok (Url.Git { repo; ref })
      in
      match is_safe_package ps with
      | true -> Ok None
      | false -> (
          match ps with
          | {
           url_src = Some url_src;
           package;
           dev_repo = Some dev_repo;
           hashes;
           dune_packages;
           _;
          } ->
              let* url = url url_src in
              Ok (Some { opam = package; dev_repo; url; hashes; dune_packages })
          | { dev_repo = None; package; _ } ->
              Logs.warn (fun l ->
                  l
                    "Package %a has no dev-repo specified, but it needs a \
                     dev-repo to be successfully included in the duniverse."
                    Opam.Pp.package package);
              Ok None
          | _ -> Ok None)
  end

  type 'ref t = {
    dir : string;
    url : 'ref Url.t;
    hashes : OpamHash.t list;
    provided_packages : OpamPackage.t list;
    dune_packages : string list;
  }

  let log_url_selection ~dev_repo ~packages ~highest_version_package =
    let pp_url : unresolved Url.t Fmt.t =
     fun ppf -> function
      | Git { repo; ref } -> Fmt.pf ppf "%s#%s" repo ref
      | Other s -> Fmt.string ppf s
    in
    let pp_package ppf { Package.opam = { name; version }; url; _ } =
      Fmt.pf ppf "%a.%a: %a" Opam.Pp.package_name name Opam.Pp.version version
        pp_url url
    in
    let sep = Fmt.any "\n" in
    Logs.warn (fun l ->
        l
          "The following packages come from the same repository %s but are \
           associated with different URLs:\n\
           %a\n\
           The url for the highest versioned package was selected: %a"
          (Dev_repo.to_string dev_repo)
          (Fmt.list ~sep pp_package) packages pp_package highest_version_package)

  module Unresolved_url_map = Map.Make (struct
    type t = unresolved Url.t

    let compare = Url.compare Git.Ref.compare
  end)

  let dir_name_from_dev_repo dev_repo =
    Dev_repo.repo_name dev_repo
    |> Base.Result.map ~f:(function "dune" -> "dune_" | name -> name)

  let dir_name_from_package package =
    let name = OpamPackage.name package in
    let version = OpamPackage.version package in
    Fmt.str "%a.%a" Opam.Pp.package_name name Opam.Pp.version version

  let from_packages_by_dev_repo ~dev_repo (packages : Package.t list) =
    let open Result.O in
    let provided_packages = List.map packages ~f:(fun p -> p.Package.opam) in
    let dune_packages =
      List.map packages ~f:(fun p -> p.Package.dune_packages) |> List.concat
    in
    let* dir = dir_name_from_dev_repo dev_repo in
    let urls =
      let add acc p =
        Unresolved_url_map.set acc p.Package.url p.Package.hashes
      in
      List.fold_left packages ~init:Unresolved_url_map.empty ~f:add
      |> Unresolved_url_map.bindings
    in
    match urls with
    | [ (url, hashes) ] ->
        Ok { dir; url; hashes; provided_packages; dune_packages }
    | _ ->
        (* If packages from the same repo were resolved to different URLs, we need to pick
           a single one. Here we decided to go with the one associated with the package
           that has the higher version. We need a better long term solution as this won't
           play nicely with pins for instance.
           The best solution here would be to use source trimming, so we can pull each individual
           package to its own directory and strip out all the unrelated source code but we would
           need dune to provide that feature. *)
        let* highest_version_package =
          Base.List.max_elt packages ~compare:(fun p p' ->
              OpamPackage.Version.compare p.Package.opam.version p'.opam.version)
          |> Base.Result.of_option
               ~error:(Rresult.R.msg "No packages to compare, internal failure")
        in
        log_url_selection ~dev_repo ~packages ~highest_version_package;
        let url = highest_version_package.url in
        let hashes = highest_version_package.hashes in
        Ok { dir; url; hashes; provided_packages; dune_packages }

  let from_packages (packages : Package.t list) =
    let repos =
      List.map packages
        ~f:(fun Package.{ url; hashes; opam; dune_packages; dev_repo = _ } ->
          let provided_packages = [ opam ] in
          let dir = dir_name_from_package opam in
          { dir; url; hashes; provided_packages; dune_packages })
    in
    Ok repos

  let equal equal_ref t t' =
    let { dir; url; hashes; provided_packages; dune_packages } = t in
    let {
      dir = dir';
      url = url';
      hashes = hashes';
      provided_packages = provided_packages';
      dune_packages = dune_packages';
    } =
      t'
    in
    String.equal dir dir'
    && Url.equal equal_ref url url'
    && Base.List.equal Opam.Hash.equal hashes hashes'
    && Base.List.equal OpamPackage.equal provided_packages provided_packages'
    && Base.List.equal String.equal dune_packages dune_packages'

  let pp pp_ref fmt { dir; url; hashes; provided_packages; dune_packages } =
    let open Pp_combinators.Ocaml in
    Format.fprintf fmt
      "@[<hov 2>{ dir = %a;@ url = %a;@ hashes = %a;@ provided_packages = %a;@ \
       dune_packages = %a }@]"
      string dir (Url.pp pp_ref) url (list Opam.Pp.hash) hashes
      (list Opam.Pp.raw_package) provided_packages (list string) dune_packages

  let resolve ~resolve_ref ({ url; _ } as t) =
    let open Result.O in
    match (url : unresolved Url.t) with
    | Git { repo; ref } ->
        let* resolved_ref = resolve_ref ~repo ~ref in
        let resolved_url = Url.Git { repo; ref = resolved_ref } in
        Ok { t with url = resolved_url }
    | Other s -> Ok { t with url = Other s }
end

type t = resolved Repo.t list

let equal t t' = Base.List.equal (Repo.equal Git.Ref.equal_resolved) t t'

let pp fmt t =
  let open Pp_combinators.Ocaml in
  (list (Repo.pp Git.Ref.pp_resolved)) fmt t

let dev_repo_map_from_packages packages =
  List.fold_left packages ~init:Dev_repo.Map.empty ~f:(fun acc pkg ->
      let key = Dev_repo.from_string pkg.Repo.Package.dev_repo in
      Dev_repo.Map.update acc key ~f:(function
        | Some pkgs -> Some (pkg :: pkgs)
        | None -> Some [ pkg ]))

let from_dependency_entries ~deduplicate_packages ~get_default_branch
    dependencies =
  let open Result.O in
  let summaries =
    List.filter_map
      ~f:(fun Opam.Dependency_entry.{ package_summary; vendored } ->
        match vendored with true -> Some package_summary | false -> None)
      dependencies
  in
  let results =
    List.map
      ~f:(Repo.Package.from_package_summary ~get_default_branch)
      summaries
  in
  let* pkg_opts = Base.Result.all results in
  let pkgs = Base.List.filter_opt pkg_opts in
  match deduplicate_packages with
  | true ->
      let dev_repo_map = dev_repo_map_from_packages pkgs in
      Dev_repo.Map.fold dev_repo_map ~init:[]
        ~f:(fun ~key:dev_repo ~data:pkgs acc ->
          Repo.from_packages_by_dev_repo ~dev_repo pkgs :: acc)
      |> Base.Result.all
  | false -> Repo.from_packages pkgs

let resolve ~resolve_ref t =
  Parallel.map ~f:(Repo.resolve ~resolve_ref) t |> Base.Result.all
