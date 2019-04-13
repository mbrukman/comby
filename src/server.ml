open Core
open Opium.Std

open Comby
open Language
open Matchers
open Rewriter

let (>>|) = Lwt.Infix.(>|=)

type match_request =
  { source : string
  ; match_template : string [@key "match"]
  ; rule : string option [@default None]
  ; language : string [@default "generic"]
  }
[@@deriving yojson]

type rewrite_request =
  { source : string
  ; match_template : string [@key "match"]
  ; rewrite_template : string [@key "rewrite"]
  ; rule : string option [@default None]
  ; language : string [@default "generic"]
  ; substitution_kind : string [@default "in_place"]
  }
[@@deriving yojson]

type json_match_result =
  { matches : Match.t list
  ; source : string
  }
[@@deriving yojson]

let matcher_of_file_extension =
  function
  | ".c" | ".h" | ".cc" | ".cpp" | ".hpp" -> (module Matchers.C : Matchers.Matcher)
  | ".py" -> (module Matchers.Python : Matchers.Matcher)
  | ".go" -> (module Matchers.Go : Matchers.Matcher)
  | ".sh" -> (module Matchers.Bash : Matchers.Matcher)
  | ".html" -> (module Matchers.Html : Matchers.Matcher)
  | _ -> (module Matchers.Generic : Matchers.Matcher)

let matcher_of_language =
  function
  | "c" | "c++" -> (module Matchers.C : Matchers.Matcher)
  | "pyhon" -> (module Matchers.Python : Matchers.Matcher)
  | "go" -> (module Matchers.Go : Matchers.Matcher)
  | "bash" -> (module Matchers.Bash : Matchers.Matcher)
  | "html" -> (module Matchers.Html : Matchers.Matcher)
  | _ -> (module Matchers.Generic : Matchers.Matcher)

let get_matches (module Matcher : Matchers.Matcher) source match_template =
  let configuration = Configuration.create ~match_kind:Fuzzy () in
  Matcher.all ~configuration ~template:match_template ~source

let matches_to_json source matches =
  Format.sprintf "%s"
    (Yojson.Safe.pretty_to_string (json_match_result_to_yojson { matches; source }))

let apply_rule matcher rule =
  List.filter ~f:(fun Match.{ environment; _ } ->
      Rule.(sat @@ apply rule ~matcher environment))

let perform_match request =
  App.string_of_body_exn request
  >>| Yojson.Safe.from_string
  >>| match_request_of_yojson
  >>| function
  | Ok { source; match_template; rule; language } ->
    let matcher = matcher_of_language language in
    let run ?rule () =
      get_matches matcher source match_template
      |> Option.value_map rule ~default:ident ~f:(apply_rule matcher)
      |> matches_to_json source
    in
    let code, result =
      match Option.map rule ~f:Rule.create with
      | None -> `Code 200, run ()
      | Some Ok rule -> `Code 200, run ~rule ()
      | Some Error error -> `Code 400, Error.to_string_hum error
    in
    respond ~code (`String result)
  | Error error ->
    respond ~code:(`Code 400) (`String error)

let rewrite_to_json result =
  Format.sprintf "%s"
    (Yojson.Safe.pretty_to_string (Rewrite.result_to_yojson result))

let perform_rewrite request =
  App.string_of_body_exn request
  >>| Yojson.Safe.from_string
  >>| rewrite_request_of_yojson
  >>| function
  | Ok { source; match_template; rewrite_template; rule; language; substitution_kind } ->
    let matcher = matcher_of_language language in
    let source_substitution =
      match substitution_kind with
      | "newline" -> None
      | "in_place" | _ -> Some source
    in
    let run ?rule () =
      get_matches matcher source match_template
      |> Option.value_map rule ~default:ident ~f:(apply_rule matcher)
      |> Rewrite.all ?source:source_substitution ~rewrite_template
      |> Option.value_map ~default:"" ~f:rewrite_to_json
    in
    let code, result =
      match Option.map rule ~f:Rule.create with
      | None -> `Code 200, run ()
      | Some Ok rule -> `Code 200, run ~rule ()
      | Some Error error -> `Code 400, Error.to_string_hum error
    in
    respond ~code (`String result)
  | Error error ->
    respond ~code:(`Code 400) (`String error)

let add_cors_headers (headers: Cohttp.Header.t): Cohttp.Header.t =
  Cohttp.Header.add_list headers [
    ("access-control-allow-origin", "*");
    ("access-control-allow-headers", "Accept, Content-Type");
    ("access-control-allow-methods", "GET, HEAD, POST, DELETE, OPTIONS, PUT, PATCH")
  ]

let allow_cors =
  let filter handler req =
    handler req
    >>| fun response ->
    response
    |> Response.headers
    |> add_cors_headers
    |> Field.fset Response.Fields.headers response
  in
  Rock.Middleware.create ~name:("allow cors") ~filter

let () =
    App.empty
    |> post "/match" perform_match
    |> post "/rewrite" perform_rewrite
    |> middleware allow_cors
    |> App.run_command