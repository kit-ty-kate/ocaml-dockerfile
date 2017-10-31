(* generate ocaml docker containers *)
module L = Dockerfile_linux
module D = Dockerfile_distro
module C = Dockerfile_cmd
module G = Dockerfile_gen

let arch_to_docker = function
 | `X86_64 -> "amd64"
 | `Aarch64 -> "arm64"

module Log_gen = struct

  let phases = [ "phase1-arm64"; "phase1-amd64"; "phase2" ]
  
  let render_joblog f =
    let open C.Parallel.Joblog in
    v f |>
    List.map (fun j ->
    let result =
      if j.exit_code = 0 then "ok" else "fail"
    in
    Fmt.strf "
      <div class=\"joblog\">
        <div class=\"joblog_result\">%s</div>
        <div class=\"joblog_arg\">%s %s</div>
        <div class=\"joblog_runtime\">(%.02fs)</div>
      </div>
    " result j.command j.arg j.run_time
    )
end

module Gen = struct
  open Dockerfile
  open Dockerfile_opam
  (* Apk based Dockerfile *)
  let apk_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "apk")::labels) @@
    L.Apk.install "build-base bzip2 git tar curl ca-certificates" @@
    install_opam_from_source ~install_wrappers:true ~branch:"master" () @@
    run "strip /usr/local/bin/opam*" @@
    from ~tag distro @@
    copy ~from:"0" ~src:["/usr/local/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/local/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.Apk.install "build-base tar ca-certificates git rsync curl sudo bash" @@ 
    L.Apk.add_user ~uid:1000 ~sudo:true "opam" @@
    L.Git.init () @@
    run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository"

  (* Debian based Dockerfile *)
  let apt_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "apt")::labels) @@
    L.Apt.install "build-essential curl git" @@
    install_opam_from_source ~install_wrappers:true ~branch:"master" () @@
    from ~tag distro @@
    copy ~from:"0" ~src:["/usr/local/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/local/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.Apt.install "build-essential curl git rsync sudo unzip" @@
    L.Apt.add_user ~uid:1000 ~sudo:true "opam" @@
    L.Git.init () @@
    run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository"

  (* RPM based Dockerfile *)
  let yum_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "apt")::labels) @@
    L.RPM.update @@
    L.RPM.dev_packages ~extra:"which tar curl xz" () @@
    install_opam_from_source ~prefix:"/usr" ~install_wrappers:true ~branch:"master" () @@
    from ~tag distro @@
    L.RPM.update @@
    L.RPM.dev_packages ~extra:"which tar curl xz" () @@
    copy ~from:"0" ~src:["/usr/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.RPM.add_user ~uid:1000 ~sudo:true "opam" @@ (** TODO pin uid at 1000 *)
    L.Git.init () @@
    run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository"

  (* Zypper based Dockerfile *)
  let zypper_opam2 ?(labels=[]) ~distro ~tag () =
    header distro tag @@
    label (("distro_style", "zypper")::labels) @@
    L.Zypper.dev_packages () @@
    install_opam_from_source ~prefix:"/usr" ~install_wrappers:true ~branch:"master" () @@
    from ~tag distro @@
    L.Zypper.dev_packages () @@
    copy ~from:"0" ~src:["/usr/bin/opam"] ~dst:"/usr/bin/opam" () @@
    copy ~from:"0" ~src:["/usr/bin/opam-installer"] ~dst:"/usr/bin/opam-installer" () @@
    L.Zypper.add_user ~uid:1000 ~sudo:true "opam" @@
    L.Git.init () @@
    run "git clone git://github.com/ocaml/opam-repository /home/opam/opam-repository"

  (* Generate archive mirror *)
  let opam2_mirror (hub_id:string) =
    header hub_id "alpine-3.6-opam" @@
    run "sudo apk add --update bash m4" @@
    workdir "/home/opam/opam-repository" @@
    run "git pull origin master" @@
    run "opam admin upgrade" @@
    run "opam init -a /home/opam/opam-repository" @@
    run "opam install -yj4 cohttp-lwt-unix" @@
    run "opam admin cache"

  let all_ocaml_compilers hub_id arch distro =
    let distro = D.tag_of_distro distro in
    let compilers =
      D.stable_ocaml_versions |>
      List.filter (D.ocaml_supported_on arch) |>
      List.map D.ocaml_version_to_opam_switch |>
      List.map (run "opam switch create %s") |> (@@@) empty in
    let d = 
      header hub_id (Fmt.strf "%s-opam" distro) @@
      run "cd /home/opam/opam-repository && git pull origin master" @@
      run "opam init -a /home/opam/opam-repository" @@
      compilers @@
      run "opam switch default" in
    (Fmt.strf "%s-ocaml" distro), d

  let separate_ocaml_compilers hub_id arch distro =
    let distro = D.tag_of_distro distro in
    D.stable_ocaml_versions |>
    List.filter (D.ocaml_supported_on arch) |>
    List.map (fun ov ->
      let default_switch = D.ocaml_version_to_opam_switch ov in
      let variants = List.map (run "opam switch create %s+%s" default_switch) Ocaml_version.(of_string ov |> Has.variants) |> (@@@) empty in
      let d = 
        header hub_id (Fmt.strf "%s-opam" distro) @@
        run "cd /home/opam/opam-repository && git pull origin master" @@
        run "opam init -a /home/opam/opam-repository -c %s" default_switch @@
        variants @@
        run "opam switch %s" default_switch
      in
      (Fmt.strf "%s-ocaml-%s" distro (D.tag_of_ocaml_version ov)), d
    )

  let bulk_build distro arch prod_hub_id distro ocaml_version variant opam_repo_tag =
    header prod_hub_id (Fmt.strf "%s-ocaml-%s" (D.tag_of_distro distro) ocaml_version) @@
    (* TODO do opam_repo_tag once we have a v2 opam-repo branch so we can pull *)
    (match variant with Some v -> run "opam switch %s+%s" ocaml_version v| None -> empty) @@
    env ["OPAMYES","1"; "OPAMVERBOSE","1"; "OPAMJOBS","2"] @@
    run "opam pin add depext https://github.com/AltGr/opam-depext.git#opam-2-beta4" @@
    run "opam depext -uiy jbuilder ocamlfind"  |> fun dfile ->
    ["base", dfile]

  let gen_opam_for_distro ?labels d =
    let fn =
     match D.resolve_alias d with
     | `Alpine v ->
      let tag = match v with
        | `V3_3 -> "3.3" | `V3_4 -> "3.4"
        | `V3_5 -> "3.5" | `V3_6 -> "3.6"
        | `Latest -> assert false in
      apk_opam2 ?labels ~distro:"alpine" ~tag ()
     | `Debian v ->
      let tag = match v with
        | `V7 -> "7"
        | `V8 -> "8"
        | `V9 -> "9"
        | `Testing -> "testing"
        | `Unstable -> "unstable"
        | `Stable -> assert false in
      apt_opam2 ?labels ~distro:"debian" ~tag ()
    | `Ubuntu v ->
      let tag = match v with
        | `V12_04 -> "precise"
        | `V14_04 -> "trusty"
        | `V16_04 -> "xenial"
        | `V16_10 -> "yakkety"
        | `V17_04 -> "zesty"
        | `V17_10 -> "artful"
        | _ -> assert false in
      apt_opam2 ?labels ~distro:"ubuntu" ~tag ()
   | `CentOS v ->
      let tag = match v with
        | `V6 -> "6"
        | `V7 -> "7"
        | _ -> assert false in
      yum_opam2 ?labels ~distro:"centos" ~tag ()
   | `Fedora v ->
      let tag = match v with
        | `V21 -> "21" | `V22 -> "22" | `V23 -> "23" | `V24 -> "24"
        | `V25 -> "25" | `V26 -> "26"
        | _ -> assert false in
      yum_opam2 ?labels ~distro:"fedora" ~tag ()
   | `OracleLinux v ->
      let tag = match v with
        | `V7 -> "7" 
        | _ -> assert false in
      yum_opam2 ?labels ~distro:"oraclelinux" ~tag ()
   | `OpenSUSE v ->
      let tag = match v with
        | `V42_1 -> "42.1"  | `V42_2 -> "42.2" | `V42_3 -> "42.3"
        | _ -> assert false in
      zypper_opam2 ?labels ~distro:"opensuse" ~tag ()
   in (D.tag_of_distro d), fn

   let multiarch_manifest ~target ~platforms =
     let ms =
       List.map (fun (image, arch) ->
         Fmt.strf "  -\n    image: %s\n    platform:\n      architecture: %s\n      os: linux" image arch
       ) platforms |> String.concat "\n" in
     Fmt.strf "image: %s\nmanifests:\n%s" target ms
end

type copts = {
  staging_hub_id: string;
  prod_hub_id: string;
  push: bool;
  cache: bool;
  build: bool;
  arch: [`X86_64 | `Aarch64];
  build_dir: Fpath.t;
  logs_dir: Fpath.t;
}

let copts staging_hub_id prod_hub_id push cache build arch build_dir logs_dir =
  { staging_hub_id; prod_hub_id; push; cache; build; arch; build_dir; logs_dir }

module Phases = struct

  open Rresult
  open R.Infix

  let if_opt opt fn = if opt then fn () else Ok ()

  let setup_log_dirs ~prefix build_dir logs_dir fn =
    Fpath.(build_dir / prefix) |> fun build_dir ->
    Fpath.(logs_dir / prefix) |> fun logs_dir ->
    Bos.OS.Dir.create ~path:true build_dir >>= fun _ ->
    Bos.OS.Dir.create ~path:true logs_dir >>= fun _ ->
    let md = C.Mdlog.init ~logs_dir ~prefix ~descr:prefix in (* TODO descr *)
    fn build_dir md >>= fun () ->
    C.Mdlog.output md

  (* Generate base opam binaries for all distros *)
  let phase1 {cache;push;build;arch;staging_hub_id;build_dir;logs_dir} () =
    let arch_s = arch_to_docker arch in
    let prefix = Fmt.strf "phase1-%s" arch_s in
    setup_log_dirs ~prefix build_dir logs_dir @@ fun build_dir md ->
    let tag = Fmt.strf "%s:{}-opam-linux-%s" staging_hub_id arch_s in
    List.filter (D.distro_supported_on arch) D.active_distros |>
    List.map Gen.gen_opam_for_distro |> fun ds ->
    G.generate_dockerfiles ~crunch:true build_dir ds >>= fun () ->
    if_opt build @@ fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let cmd = C.Docker.build_cmd ~cache ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst ds in
    C.Mdlog.run_parallel ~retries:1 md "01-build" cmd args >>= fun jobs ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.push_cmd tag in
    C.Mdlog.run_parallel ~retries:1 md "02-push" cmd args

  (* Push multiarch images to the Hub for base opam binaries *)
  let phase2 {prod_hub_id;staging_hub_id;push;build_dir;logs_dir} () =
    setup_log_dirs ~prefix:"phase2" build_dir logs_dir @@ fun build_dir md ->
    let yaml_file tag = Fpath.(build_dir / (tag ^ ".yml")) in
    let yamls =
      List.map (fun distro ->
        let tag = D.tag_of_distro distro in
        let target = Fmt.strf "%s:%s-opam" prod_hub_id tag in
        let platforms =
          D.distro_arches distro |>
          List.map (fun arch ->
            let arch = arch_to_docker arch in
            let image = Fmt.strf "%s:%s-opam-linux-%s" staging_hub_id tag arch in
            image, arch) in
        Gen.multiarch_manifest ~target ~platforms |> fun m ->
        tag, m
      ) D.active_distros in
    C.iter (fun (t,m) -> Bos.OS.File.write (yaml_file t) m) yamls >>= fun () ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.manifest_push_file (yaml_file "{}") in
    let args = List.map (fun (t,_) -> t) yamls in
    C.Mdlog.run_parallel ~retries:1 md "01-manifest" cmd args

  (* Generate an opam archive suitable for pointing local builds at *)
  let phase3_archive {cache;push;build;staging_hub_id;prod_hub_id;build_dir;logs_dir} () =
    setup_log_dirs ~prefix:"phase3-archive" build_dir logs_dir @@ fun build_dir md ->
    G.generate_dockerfile ~crunch:true build_dir (Gen.opam2_mirror prod_hub_id) >>= fun () ->
    if_opt build @@ fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile") in
    let cmd = C.Docker.build_cmd ~cache ~dockerfile ~tag:"{}" (Fpath.v ".") in
    let args = [Fmt.strf "%s:%s" staging_hub_id "opam2-archive"] in
    C.Mdlog.run_parallel ~retries:1 md "01-build" cmd args >>= fun () ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.push_cmd "{}" in
    C.Mdlog.run_parallel ~retries:1 md "02-push" cmd args

  let phase3_ocaml {cache;push;build;arch;staging_hub_id;prod_hub_id;build_dir;logs_dir} () =
    let arch_s = arch_to_docker arch in
    let prefix = Fmt.strf "phase3-ocaml-%s" arch_s in
    setup_log_dirs ~prefix build_dir logs_dir @@ fun build_dir md ->
    let all_compilers =
      List.filter (D.distro_supported_on arch) D.active_distros |>
      List.map (Gen.all_ocaml_compilers prod_hub_id arch) in
    let each_compiler =
      List.filter (D.distro_supported_on arch) D.active_distros |>
      List.map (Gen.separate_ocaml_compilers prod_hub_id arch) |>
      List.flatten in
    let dfiles = all_compilers @ each_compiler in
    G.generate_dockerfiles ~crunch:true build_dir dfiles >>= fun () ->
    if_opt build @@ fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let tag = Fmt.strf "%s:{}-linux-%s" staging_hub_id arch_s in
    let cmd = C.Docker.build_cmd ~cache ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst dfiles in
    C.Mdlog.run_parallel ~delay:5.0 ~retries:1 md "01-build" cmd args >>= fun () ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.push_cmd tag in
    C.Mdlog.run_parallel ~retries:1 md "02-push" cmd args

  (* Push multiarch images to the Hub for ocaml binaries *)
  let phase4 {staging_hub_id;prod_hub_id;push;build_dir;logs_dir} () =
    setup_log_dirs ~prefix:"phase4" build_dir logs_dir @@ fun build_dir md ->
    let yaml_file tag = Fpath.(build_dir / (tag ^ ".yml")) in
    let yamls =
      List.map (fun distro ->
        let tag = D.tag_of_distro distro in
        let mega_ocaml =
          let target = Fmt.strf "%s:%s-ocaml" prod_hub_id tag in
          let platforms =
            D.distro_arches distro |>
            List.map (fun arch ->
              let arch = arch_to_docker arch in
              let image = Fmt.strf "%s:%s-ocaml-linux-%s" staging_hub_id tag arch in
              image, arch) in
          let tag = Fmt.strf "%s-ocaml" tag in
          Gen.multiarch_manifest ~target ~platforms |> fun m ->
          tag, m in
        let each_ocaml = List.map (fun ov ->
          let target = Fmt.strf "%s:%s-ocaml-%s" prod_hub_id tag ov in
          let platforms =
            D.distro_arches distro |>
            List.filter (fun a -> Ocaml_version.(Has.arch a (of_string ov))) |>
            List.map (fun arch ->
              let arch = arch_to_docker arch in
              let image = Fmt.strf "%s:%s-ocaml-%s-linux-%s" staging_hub_id tag ov arch in
              image, arch) in
          let tag = Fmt.strf "%s-ocaml-%s" tag ov in
          Gen.multiarch_manifest ~target ~platforms |> fun m ->
          tag,m 
        ) D.stable_ocaml_versions in
        mega_ocaml :: each_ocaml
      ) D.active_distros |> List.flatten in
    C.iter (fun (t,m) -> Bos.OS.File.write (yaml_file t) m) yamls >>= fun () ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.manifest_push_file (yaml_file "{}") in
    let args = List.map (fun (t,_) -> t) yamls in
    C.Mdlog.run_parallel ~delay:1.0 ~retries:1 md "01-manifest" cmd args

  (* Setup a bulk build image *)
  let phase5 {arch;cache;staging_hub_id;prod_hub_id;build;push;build_dir;logs_dir} () =
    let arch_s = arch_to_docker arch in 
    let distro = `Alpine `V3_6 in (* TODO turn into cmdline switches *)
    let ov = "4.05.0" in
    let opam_repo_tag = "master" in
    let tag_frag = Fmt.strf "%s-%s-%s-%s" (D.tag_of_distro distro) ov opam_repo_tag arch_s in
    let prefix = Fmt.strf "phase5-%s" tag_frag in
    setup_log_dirs ~prefix build_dir logs_dir @@ fun build_dir md ->
    let dfiles = Gen.bulk_build distro arch prod_hub_id distro ov None opam_repo_tag in
    G.generate_dockerfiles ~crunch:true build_dir dfiles >>= fun () ->
    if_opt build @@ fun () ->
    let dockerfile = Fpath.(build_dir / "Dockerfile.{}") in
    let tag = Fmt.strf "%s:base-linux-%s" staging_hub_id tag_frag in
    let cmd = C.Docker.build_cmd ~cache ~dockerfile ~tag (Fpath.v ".") in
    let args = List.map fst dfiles in
    C.Mdlog.run_parallel ~retries:1 md "01-build" cmd args >>= fun () ->
    let opam_cmd = Bos.Cmd.of_list ["opam";"list";"--installable";"-s"] in 
    let pkgs_list = Fpath.(build_dir / "pkgs.txt") in
    Bos.OS.Cmd.(run_out (C.Docker.run_cmd tag opam_cmd) |> to_file pkgs_list) >>= fun () ->
    if_opt push @@ fun () ->
    let cmd = C.Docker.push_cmd "{}" in
    C.Mdlog.run_parallel ~retries:1 md "02-push" cmd [tag]

  let phase5_setup {staging_hub_id} () =
    let open Bos in 
    let cmd = Cmd.(v "docker" % "volume" % "rm" % "-f" % "opam2-archive") in
    OS.Cmd.(run cmd) >>= fun () ->
    (* TODO docker pull archive *)
    let cmd = Cmd.(v "docker" % "run" % "--rm" % "--name=create-opam2-archive" % "--mount" %
      "source=opam2-archive,destination=/home/opam/opam-repository/cache" %
      Fmt.strf "%s:opam2-archive" staging_hub_id % "true") in
    OS.Cmd.(run cmd)
  
  let phase5_build {arch;cache;staging_hub_id;prod_hub_id;build;build_dir;logs_dir} pkg () =
    let arch_s = arch_to_docker arch in 
    let distro = `Alpine `V3_6 in (* TODO turn into cmdline switches *)
    let ov = "4.05.0" in
    let opam_repo_tag = "master" in
    let tag_frag = Fmt.strf "%s-%s-%s-%s" (D.tag_of_distro distro) ov opam_repo_tag arch_s in
    let prefix = Fmt.strf "phase5-%s" tag_frag in
    let open Bos in 
    setup_log_dirs ~prefix build_dir logs_dir @@ fun build_dir md ->
    let img = Fmt.strf "%s:base-linux-%s" staging_hub_id tag_frag in
    Cmd.(v "docker" % "run" % "--rm" % "-v" % "opam2-archive:/home/opam/.opam/download-cache" % img % "opam" % "depext" % "-i" % pkg) |>
    C.Mdlog.run_cmd md pkg

  let phase5_cluster {arch;build_dir;logs_dir} hosts () =
    let arch_s = arch_to_docker arch in 
    let distro = `Alpine `V3_6 in (* TODO turn into cmdline switches *)
    let ov = "4.05.0" in
    let opam_repo_tag = "master" in
    let tag_frag = Fmt.strf "%s-%s-%s-%s" (D.tag_of_distro distro) ov opam_repo_tag arch_s in
    let prefix = Fmt.strf "phase5-%s" tag_frag in
    let open Bos in 
    setup_log_dirs ~prefix build_dir logs_dir @@ fun build_dir md ->
    let hosts_l = String.concat "," (List.map (fun s -> "30/"^s) hosts) in
    Bos.OS.File.read_lines Fpath.(logs_dir / "pkgs.txt") >>= fun pkgs ->
    C.iter (fun host ->
      Cmd.(v "parallel" % "--no-notice" % "-S" % hosts_l % "--nonall" % "./ocaml-docker" % "phase5-setup" % "-vvv") |> OS.Cmd.run >>=	fun () ->
      Cmd.(v "parallel" % "--no-notice" % "-S" % hosts_l % "echo" % "./ocaml-docker" % "phase5-build" % "{}" % "-vvv" % ":::" %% of_list pkgs) |> OS.Cmd.run
    ) hosts >>= fun () ->
    Ok ()
end

open Cmdliner
let setup_logs = C.setup_logs ()

let fpath =
  Arg.conv ~docv:"PATH" (Fpath.of_string,Fpath.pp)

let copts_t =
  let docs = Manpage.s_common_options in
  let staging_hub_id =
    let doc = "Docker Hub user/repo to push to for staging builds" in
    Arg.(value & opt string "ocaml/opam2-staging" & info ["staging-hub-id"] ~docv:"STAGING_HUB_ID" ~doc ~docs) in
  let prod_hub_id =
    let doc = "Docker Hub user/repo to push to for production multiarch builds" in
    Arg.(value & opt string "ocaml/opam2" & info ["prod-hub-id"] ~docv:"PROD_HUB_ID" ~doc ~docs) in
  let push =
    let doc = "Push result of builds to Docker Hub" in
    Arg.(value & opt bool true & info ["push"] ~docv:"PUSH" ~doc ~docs) in
  let cache =
    let doc = "Use Docker caching (normally only activate for development use)" in
    Arg.(value & opt bool false & info ["cache"] ~docv:"CACHE" ~doc ~docs) in
  let build =
    let doc = "Build the results (normally only disable for development use)" in
    Arg.(value & opt bool true & info ["build"] ~docv:"BUILD" ~doc ~docs) in
  let arch =
    let doc = "CPU architecture to perform build on" in
    let term = Arg.enum ["x86_64",`X86_64; "aarch64",`Aarch64] in
    Arg.(value & opt term `X86_64 & info ["arch"] ~docv:"ARCH" ~doc ~docs) in
  let build_dir = 
    let doc = "Directory in which to store build artefacts" in
    Arg.(value & opt fpath (Fpath.v "_obj") & info ["b";"build-dir"] ~docv:"BUILD_DIR" ~doc ~docs) in
  let logs_dir =
    let doc = "Directory in which to store logs" in
    Arg.(value & opt fpath (Fpath.v "_logs") & info ["l";"logs-dir"] ~docv:"LOG_DIR" ~doc ~docs) in
  Term.(const copts $ staging_hub_id $ prod_hub_id $ push $ cache $ build $ arch $ build_dir $ logs_dir)

let phase1_cmd =
  let doc = "generate, build and push base opam container images" in
  let exits = Term.default_exits in
  let man = [
    `S Manpage.s_description;
    `P "Generate and build base $(b,opam) container images." ]
  in
  Term.(term_result (const Phases.phase1 $ copts_t $ setup_logs)),
  Term.info "phase1" ~doc ~sdocs:Manpage.s_common_options ~exits ~man

let phase2_cmd =
  let doc = "combine opam container images into multiarch versions" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase2 $ copts_t $ setup_logs)),
  Term.info "phase2" ~doc ~exits

let phase3_archive_cmd =
  let doc = "generate a distribution archive mirror" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase3_archive $ copts_t $ setup_logs)),
  Term.info "phase3-cache" ~doc ~exits

let phase3_ocaml_cmd =
  let doc = "generate a matrix of ocaml compilers" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase3_ocaml $ copts_t $ setup_logs)),
  Term.info "phase3-ocaml" ~doc ~exits

let phase4_cmd =
  let doc = "combine ocaml container images into multiarch versions" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase4 $ copts_t $ setup_logs)),
  Term.info "phase4" ~doc ~exits

let phase5_cmd =
  let doc = "create a bulk build base image and generate a package list for it" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase5 $ copts_t $ setup_logs)),
  Term.info "phase5" ~doc ~exits

let ssh_hosts =
  let doc = "cluster hosts to ssh to" in
  Arg.(value & opt (list string) [] & info ["hosts"] ~docv:"PUSH" ~doc)

let phase5_setup =
  let doc = "setup cluster hosts for a bulk build" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase5_setup $ copts_t $ setup_logs)),
  Term.info "phase5-setup" ~doc ~exits

let phase5_build =
  let doc = "build one package in a bulk build" in
  let exits = Term.default_exits in
  let pkg =
    let doc = "Package to build" in
    Arg.(required & pos ~rev:true 0 (some string) None & info [] ~docv:"PACKAGE" ~doc) in
  Term.(term_result (const Phases.phase5_build $ copts_t $ pkg $ setup_logs)),
  Term.info "phase5-build" ~doc ~exits

let phase5_cluster =
  let doc = "run cluster build" in
  let exits = Term.default_exits in
  Term.(term_result (const Phases.phase5_cluster $ copts_t $ ssh_hosts $ setup_logs)),
  Term.info "phase5-cluster" ~doc ~exits

let default_cmd =
  let doc = "build and push opam and OCaml multiarch container images" in
  let sdocs = Manpage.s_common_options in
  Term.(ret (const (fun _ -> `Help (`Pager, None)) $ pure ())),
  Term.info "obi-docker" ~version:"v1.0.0" ~doc ~sdocs

let cmds = [phase1_cmd; phase2_cmd; phase3_archive_cmd; phase3_ocaml_cmd; phase4_cmd; phase5_cmd; phase5_build; phase5_setup; phase5_cluster]
let () = Term.(exit @@ eval_choice default_cmd cmds)

