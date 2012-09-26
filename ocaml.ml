open Types

type t =
	| Block of t list
	| Line of string

let rec lines_of_t t =
	let indent = String.make 4 ' ' in
	match t with
		| Line x -> [ x ]
		| Block xs ->
	let all = List.concat (List.map lines_of_t xs) in
	List.map (fun x -> indent ^ x) all

let string_of_ts ts = String.concat "\n" (List.concat (List.map lines_of_t ts))

open Printf

let rec typeof ?(expand_aliases=false) env =
	let typeof env = typeof ~expand_aliases env in
	let open Type in function
		| Basic Int64 -> "int64"
		| Basic String -> "string"
		| Basic Double -> "float"
		| Basic Boolean -> "bool"
		| Struct (fst, rest) ->
			let member (name, ty, descr) = sprintf "%s: %s; (** %s *)" name (typeof env ty) descr in
			"{ " ^ (member fst) ^ (String.concat " " (List.map member rest)) ^ " }"
		| Variant (fst, rest) ->
			let member (name, ty, descr) = sprintf "| %s of %s (** %s *)" name (typeof env ty) descr in
			member fst ^ (String.concat " " (List.map member rest))
		| Array t -> typeof env t ^ " list"
		| Dict (basic, t) -> sprintf "(%s * %s) list" (typeof env (Basic basic)) (typeof env t)
		| Name x ->
			let ident =
				if not(List.mem_assoc x env)
				then failwith (Printf.sprintf "Unable to find ident: %s" x)
				else List.assoc x env in
			if expand_aliases
			then typeof env ident.Ident.ty
			else List.hd ident.Ident.name (* we assume names are all in scope *)
		| Unit -> "()"
		| Option t -> sprintf "%s option" (typeof env t)
		| Pair (a, b) -> sprintf "(%s * %s)" (typeof env a) (typeof env b)

let type_decl env t =
	[
		Line (sprintf "type %s = %s with rpc" t.TyDecl.name (typeof ~expand_aliases:true env t.TyDecl.ty));
		Line (sprintf "(** %s *)" t.TyDecl.description);
	]

let rec example_value_of env =
	let open Type in function
		| Basic Int64 -> "0L"
		| Basic String -> "\"string\""
		| Basic Double -> "1.1"
		| Basic Boolean -> "true"
		| Struct (hd, tl) ->
			let member (name, ty, descr) =
				sprintf "%s = %s" name (example_value_of env ty) in
			sprintf "{ %s }" (String.concat "; " (List.map member (hd :: tl)))
		| Variant ((first_name, first_t, _), tl) ->
			first_name ^ " " ^ (example_value_of env first_t)
		| Array t ->
			sprintf "[ %s; %s ]" (example_value_of env t) (example_value_of env t)
		| Dict (key, va) ->
			sprintf "(%s, %s)" (example_value_of env (Basic key)) (example_value_of env va)
		| Name x ->
			let ident =
				if not(List.mem_assoc x env)
				then failwith (Printf.sprintf "Unable to find ident: %s" x)
				else List.assoc x env in
			example_value_of env ident.Ident.ty
		| Unit ->
			"()"
		| Option t ->
			"Some " ^ (example_value_of env t)
		| Pair (a, b) ->
			Printf.sprintf "(%s, %s)" (example_value_of env a) (example_value_of env b)

let exn_decl env e =
	let open Printf in
	let rec unpair = function
		| Type.Pair(a, b) -> unpair a @ (unpair b)
		| Type.Name x -> unpair((List.assoc x env).Ident.ty)
		| t -> [ t ] in
	let args = unpair e.TyDecl.ty in
	[
		Line (sprintf "exception %s of %s" e.TyDecl.name (String.concat " * " (List.map Type.ocaml_of_t args)));
		Line (sprintf "(** %s *)" e.TyDecl.description);
	]

let rpc_of_interfaces env is =
	let field_of_arg a = Line (sprintf "%s: %s;" a.Arg.name (typeof env a.Arg.ty)) in
	let of_method i m =
		[
			Line (sprintf "module %s = struct" (String.capitalize m.Method.name));
			Block ([
				Line "module In = struct";
				Block [
					Line "type t = {";
					Block (List.map field_of_arg m.Method.inputs);
					Line "} with rpc";
				];
				Line "end";
			]);
			Block [
				Line "module Out = struct";
				Block [
					match m.Method.outputs with
						| [ x ] ->
							Line (sprintf "type t = %s with rpc" (typeof env x.Arg.ty))
						| [] ->
							Line "type t = unit with rpc"
						| _ -> failwith (Printf.sprintf "%s.%s has output arity <> 0, 1: rpc-light can't cope" i.Interface.name m.Method.name)
				];
				Line "end";
			];
			Line "end";
		] in
	let rpc_of_interface env i =
		[
			Line (sprintf "module %s = struct" i.Interface.name);
			Block ([
			] @ (List.concat (List.map (type_decl env) i.Interface.type_decls)
			) @ (List.concat (List.map (of_method i) i.Interface.methods))
			);
			Line "end"
		] in
	[
		Line "module Types = struct";
		Block ([
		] @ (List.concat (List.map (type_decl env) is.Interfaces.type_decls)
		) @ (List.concat (List.map (rpc_of_interface env) is.Interfaces.interfaces)
		));
		Line "end";
	]

let skeleton_method unimplemented env i m =
	let example_outputs =
		if m.Method.outputs = []
		then "()"
		else sprintf "Types.%s.%s.Out.({ %s })" i.Interface.name (String.capitalize m.Method.name)
		(String.concat "; " (List.map (fun a -> sprintf "%s = %s" a.Arg.name (example_value_of env a.Arg.ty)) m.Method.outputs)) in
	[
		Line (sprintf "let %s x = %s" m.Method.name
			(if unimplemented
			then (sprintf "raise (Unimplemented \"%s.%s\")" i.Interface.name m.Method.name)
			else example_outputs)
		)
	]

let example_skeleton_user env i m =
    let open Printf in
    [
		Line "";
		Line (sprintf "module %s_myimplementation = struct" i.Interface.name);
		Block [
			Line (sprintf "include %s_skeleton" i.Interface.name);
			Line "...";
			Block (skeleton_method false env i m);
			Line "...";
		];
		Line "end"
    ]

let skeleton_of_interface unimplemented suffix env i =
	[
		Line (sprintf "module %s_%s = struct" i.Interface.name suffix);
		Block (List.concat (List.map (skeleton_method unimplemented env i) i.Interface.methods));
		Line "end";
	]

let signature_of_interface env i =
	let signature_of_method m =
		Line (sprintf "val %s: Types.%s.%s.In.t -> (Types.%s.%s.Out.t, exn) Xcp.result Xcp.M.t"
			m.Method.name
			i.Interface.name (String.capitalize m.Method.name)
			i.Interface.name (String.capitalize m.Method.name)
		) in
	[
		Line (sprintf "module type %s = sig" i.Interface.name);
		Block (List.map signature_of_method i.Interface.methods);
		Line "end";
	]

let test_impl_of_interface = skeleton_of_interface false "test"
let skeleton_of_interface = skeleton_of_interface true "skeleton"

let server_of_interface env i =
	let dispatch_method m =
		[
			Line (sprintf "| \"%s.%s\", [ args ] ->" i.Interface.name m.Method.name);
			Block [
				Line (sprintf "let request = %s.%s.In.t_of_rpc args in" i.Interface.name (String.capitalize m.Method.name));
				Line (sprintf "%s request" m.Method.name);
				Line ">>= function";
				Line " | Ok response ->";
				Block [
					Line (sprintf "let response = %s.%s.Out.to_rpc response" i.Interface.name (String.capitalize m.Method.name));
					Line "return response";
				];
				Line " | Error exn ->";
				Block [
					Line "Rpc.failure (Printf.sprintf \"Internal_error: %s\" (Printexc.to_string exn))";
				]
			];
			Line (sprintf "| \"%s.%s\", args -> failwith \"wrong number of arguments\""
				i.Interface.name m.Method.name
			);
		] in
	[
		Line (sprintf "module %s_server_dispatcher = functor(Impl: %s) -> struct" i.Interface.name i.Interface.name);
		Block [
			Line "let open Impl in";
			Line "let dispatch (call: Rpc.call) : Rpc.response Impl.t =";
			Block [
				Line "match call.Rpc.name, call.Rpc.params with";
				Block (List.concat (List.map dispatch_method i.Interface.methods));
			]
		];
		Line "end"
	]

let of_interfaces env i =
	let open Printf in
	[
		Line "(* Automatically generated code - DO NOT MODIFY *)";
		Line "";
		Line "open Xcp";
		Line "";
	] @ (
		List.concat (List.map (exn_decl env) i.Interfaces.exn_decls)
	) @ (
		rpc_of_interfaces env i
	) @ (
		List.concat (List.map (signature_of_interface env) i.Interfaces.interfaces)
	) @ (
		List.fold_left (fun acc i -> acc @
			(server_of_interface env i) @ (skeleton_of_interface env i) @ (test_impl_of_interface env i)
		) [] i.Interfaces.interfaces
	)