open Solver_Runner

let to_triple (a, (b, c)) = (a, b, c)

let ( $$ ) = Base.List.cartesian_product

let ( *$ ) a b = Base.List.cartesian_product [ a ] b

let ( *$- ) a b = List.map to_triple (a *$ b)

type model_experiment = {
  solver : solver;
  mutable experiment_count : int;
  mutable lengths : int list;
  mutable opted_lengths : int list;
}

type model_result = {
  model : model_experiment;
  deviation : float;
  length : float;
  opt_deviation : float;
  opt_length : float;
  deviation_standart_dev : float;
  opt_deviation_standart_dev : float;
  min_dev : float;
  max_dev : float;
  opt_min_dev : float;
  opt_max_dev : float;
}

let get_model_results (best_lengths : int list) model =
  let n = float model.experiment_count in
  let exp_count = List.length best_lengths in
  let mean_list list = List.fold_left ( +. ) 0. list /. n in
  let get_deviations lengths =
    try
      List.map2
        (fun len opt_len -> float (len - opt_len) /. float opt_len)
        lengths
        (if exp_count = model.experiment_count then best_lengths
        else List.tl best_lengths)
    with Invalid_argument e | Failure e ->
      raise
      @@ Invalid_argument
           (Printf.sprintf
              "error : %s, size of lenghts : %d, size of best_lengths : %d, \
               experiment count : %d"
              e (List.length lengths) exp_count model.experiment_count)
  in
  let deviations = get_deviations model.lengths in
  let opt_deviations = get_deviations model.opted_lengths in
  let deviation = mean_list deviations in
  let length = model.lengths |> List.map float |> mean_list in
  let opt_deviation = mean_list opt_deviations in
  let opt_length = model.opted_lengths |> List.map float |> mean_list in
  let dev_of_dev l =
    List.fold_left (fun acc dev -> acc +. ((deviation -. dev) ** 2.)) 0. l /. n
    |> sqrt
  in
  let deviation_standart_dev = dev_of_dev deviations in
  let opt_deviation_standart_dev = dev_of_dev opt_deviations in
  let min_dev = Base.List.min_elt deviations ~compare |> Option.get in
  let max_dev = Base.List.max_elt deviations ~compare |> Option.get in
  let opt_min_dev = Base.List.min_elt opt_deviations ~compare |> Option.get in
  let opt_max_dev = Base.List.max_elt opt_deviations ~compare |> Option.get in
  {
    model;
    deviation;
    length;
    opt_deviation;
    opt_length;
    deviation_standart_dev;
    opt_deviation_standart_dev;
    min_dev;
    max_dev;
    opt_max_dev;
    opt_min_dev;
  }

type named_opt = { opt : MCTS.optimization_mode; name : string }

let init_model solver =
  { solver; experiment_count = 0; lengths = []; opted_lengths = [] }

let string_of_ratio = function
  | 2 -> "Semi"
  | 4 -> "Quart"
  | n -> Printf.sprintf "1/%d" n

let prefixOpt total_factor length_factor =
  match (total_factor, length_factor) with
  | 1, 1 -> "Base"
  | 1, x -> string_of_ratio x ^ "Length"
  | x, 1 -> string_of_ratio x ^ "Duration"
  | l, d -> string_of_ratio l ^ "Length_" ^ string_of_ratio d ^ "Duration"

let divide_opt total_factor length_factor = function
  | MCTS.Two_opt opt ->
      MCTS.Two_opt
        {
          max_length = opt.max_length / length_factor;
          max_time = opt.max_time /. float total_factor;
          max_iter = opt.max_iter / total_factor;
        }
  | MCTS.Full_Two_opt opt ->
      MCTS.Full_Two_opt
        {
          max_time = opt.max_time /. float total_factor;
          max_iter = opt.max_iter / total_factor;
        }
  | x -> x

let name_opt total_factor length_factor = function
  | MCTS.Two_opt _ ->
      Printf.sprintf "%s2Opt" @@ prefixOpt total_factor length_factor
  | MCTS.Full_Two_opt _ ->
      Printf.sprintf "%sFull2Opt" @@ prefixOpt total_factor length_factor
  | No_opt -> "NoOpt"
  | _ -> assert false

let create_mcts_opt total_factor length_factor opt =
  let opt = divide_opt total_factor length_factor opt in
  let name = name_opt total_factor length_factor opt in
  { opt; name }

let opt_of_tuple (opt, (total_factor, length_factor)) =
  create_mcts_opt total_factor length_factor opt

let def_opt = create_mcts_opt 1 1

(** Create model record which will be run by the Solver_Runner module *)
let create_models ?(exploration_mode = MCTS.Standard_deviation)
    ?(mcts_vanilla_list = []) ?(mcts_opt_list = []) ?(iter2opt_list = [])
    max_time =
  let create_opt_mcts (selection_mode, (opt, t, hidden_opt)) =
    let { opt; name } = opt_of_tuple (opt, t) in
    MCTS
      {
        name =
          Printf.sprintf "MCTS-%s-%s%s" name
            (MCTS.str_of_selection_mode selection_mode)
            (if hidden_opt = MCTS.No_opt then ""
            else
              Printf.sprintf "-hidden_%s"
              @@ MCTS.str_of_optimization_mode_short hidden_opt);
        max_time;
        exploration_mode;
        optimization_mode = opt;
        selection_mode;
        hidden_opt;
      }
  in
  let create_vanilla_mcts (selection_mode, hidden_opt) =
    MCTS
      {
        name =
          Printf.sprintf "MCTS-Vanilla-%s%s"
            (MCTS.str_of_selection_mode selection_mode)
            (if hidden_opt = MCTS.No_opt then ""
            else
              Printf.sprintf "-hidden_%s"
              @@ MCTS.str_of_optimization_mode_short hidden_opt);
        max_time;
        exploration_mode;
        optimization_mode = No_opt;
        selection_mode = Random;
        hidden_opt;
      }
  in
  let create_iterated_opt (max_iter, random_mode) =
    Iter
      {
        max_iter;
        max_time;
        random_mode;
        name =
          Printf.sprintf "Iterated2Opt-%s%s"
            (Iterated_2Opt.string_of_random_mode random_mode)
            (if max_iter = max_iter then ""
            else Printf.sprintf "-%diters" max_iter);
      }
  in
  List.map init_model
    (List.map create_opt_mcts mcts_opt_list
    @ List.map create_vanilla_mcts mcts_vanilla_list
    @ List.map create_iterated_opt iter2opt_list)

let run_models ?(sim_name = "sim") ?(mk_new_log_dir = true) ?(verbose = 1) ?seed
    configs models =
  let exception Break of int list in
  let update_csv = ref false in
  if Sys.os_type <> "Win32" then
    Sys.set_signal Sys.sigusr1
      (Sys.Signal_handle
         (fun _ ->
           Printf.printf
             "Update csv signal received ! Waiting for last model result...\n%!";
           update_csv := true));
  let stop_experiment = ref false in
  if Sys.os_type <> "Win32" then
    Sys.set_signal Sys.sigusr2
      (Sys.Signal_handle
         (fun _ ->
           Printf.printf
             "Stop experiment signal received ! Waiting for last model result...\n\
              %!";
           stop_experiment := true));
  let start_time = Unix.gettimeofday () in
  let last_debug = ref start_time in
  let debug_count = ref 0 in
  let tour = Printf.sprintf "logs/%s" sim_name in
  let log_files_path =
    if mk_new_log_dir then File_log.create_log_dir tour else tour
  in
  let file_name = "all_mcts_tests-" ^ sim_name in
  let logs = File_log.create_file ~file_path:log_files_path ~file_name () in

  let update_log_file best_lengths =
    let first_row =
      "solver-name,average-deviation,standard-deviation-deviation,average-length,average-opted-deviation,standard-deviation-deviation,average-opted-length,max-deviation,min-deviation,opt-max-deviation,opt-min-deviation"
    in
    Printf.printf "%s\n%!" first_row;
    let oc = File_log.log_string_endline ~close:false logs first_row in
    ignore
      (List.filter_map
         (fun model ->
           if model.experiment_count = 0 then None
           else Some (get_model_results best_lengths model))
         models
      |> List.sort (fun a b -> compare a.opt_deviation b.opt_deviation)
      |> File_log.log_data
           (fun result ->
             if result.model.experiment_count = 0 then ""
             else
               let row =
                 Printf.sprintf "%s,%g,%g,%g,%g,%g,%g,%g,%g,%g,%g\n"
                   (solver_name result.model.solver)
                   result.deviation result.deviation_standart_dev result.length
                   result.opt_deviation result.opt_deviation_standart_dev
                   result.opt_length result.max_dev result.min_dev
                   result.opt_max_dev result.opt_min_dev
               in

               Printf.printf "%s\n%!" row;
               row)
           ~oc)
  in

  Printf.printf "\nRunning sim %s...\n%!"
    (Scanf.sscanf log_files_path "logs/%s" Fun.id);
  let best_lengths =
    try
      List.fold_left
        (fun best_lengths (file_path, config) ->
          let city_count, cities = Reader_tsp.open_tsp ~file_path config in
          let adj = Base_tsp.get_adj_matrix cities in
          let best_lengths =
            Base_tsp.best_path_length ~file_path config adj :: best_lengths
          in
          List.iter
            (fun model ->
              let diff = Unix.gettimeofday () -. !last_debug in
              if diff > 3600. then (
                debug_count := !debug_count + (int_of_float diff / 3600);
                update_log_file best_lengths;
                if verbose > 0 then
                  Printf.printf
                    "currently testing %s, has been running for %d hours\n%!"
                    config !debug_count;
                last_debug := Unix.gettimeofday ());
              let length, opt_length =
                solver_simulation config city_count adj log_files_path
                  model.solver ~verbose:(verbose - 1) ?seed
              in
              model.experiment_count <- model.experiment_count + 1;
              model.lengths <- length :: model.lengths;
              model.opted_lengths <- opt_length :: model.opted_lengths;
              if !update_csv then (
                update_csv := false;
                update_log_file best_lengths;
                Printf.printf "csv updated, check it at %s%s\n%!" logs.file_path
                  logs.file_name);
              if !stop_experiment then raise @@ Break best_lengths)
            models;
          best_lengths)
        [] configs
    with Break best_lengths -> best_lengths
  in
  update_log_file best_lengths;
  Printf.printf
    "\n\nExperiment ended in %g seconds\nResult file available at : %s%s\n"
    (Unix.gettimeofday () -. start_time)
    logs.file_path logs.file_name
