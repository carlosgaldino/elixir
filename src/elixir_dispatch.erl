%% Helpers related to dispatching to imports and references.
%% This module access the information stored on the scope
%% by elixir_import and therefore assumes it is normalized (ordsets)
-module(elixir_dispatch).
-export([default_macros/0, default_functions/0, default_requires/0,
  dispatch_require/6, dispatch_import/5,
  require_function/5, import_function/4,
  format_error/1]).
-include("elixir.hrl").
-import(ordsets, [is_element/2]).
-define(BUILTIN, '__MAIN__.Elixir.Builtin').

default_functions() ->
  [ { ?BUILTIN, ordsets:union(in_elixir_functions(), in_erlang_functions()) } ].
default_macros() ->
  [ { ?BUILTIN, ordsets:union(in_elixir_macros(), in_erlang_macros()) } ].
default_requires() ->
  [ ?BUILTIN ].

%% Function retrieval

import_function(Line, Name, Arity, S) ->
  Tuple = { Name, Arity },
  case find_dispatch(Tuple, S#elixir_scope.functions) of
    false ->
      case find_dispatch(Tuple, S#elixir_scope.macros) of
        false -> { { 'fun', Line, { function, Name, Arity } }, S };
        _ -> false
      end;
    Receiver ->
      elixir_import:record(import, Tuple, Receiver, S#elixir_scope.module),
      remote_function(Line, Receiver, Name, Arity, S)
  end.

require_function(Line, Receiver, Name, Arity, S) ->
  Tuple = { Name, Arity },

  case is_element(Tuple, get_optional_macros(Receiver)) of
    true  -> false;
    false -> remote_function(Line, Receiver, Name, Arity, S)
  end.

%% Function dispatch

dispatch_import(Line, Name, Args, S, Callback) ->
  Module = S#elixir_scope.module,
  Arity  = length(Args),
  Tuple  = { Name, Arity },

  case find_dispatch(Tuple, S#elixir_scope.functions) of
    false ->
      case expand_import(Line, Module, Tuple, Args, S) of
        { error, noexpansion } ->
          Callback();
        { error, internal } ->
          elixir_import:record(import, Tuple, ?BUILTIN, Module),
          elixir_macros:translate_macro({ Name, Line, Args }, S);
        { ok, Receiver, Tree } ->
          translate_expansion(Line, Tree, Receiver, Name, Arity, S)
      end;
    Receiver ->
      elixir_import:record(import, Tuple, Receiver, Module),
      Endpoint = case (Receiver == ?BUILTIN) andalso is_element(Tuple, in_erlang_functions()) of
        true  -> erlang;
        false -> Receiver
      end,
      elixir_translator:translate_each({ { '.', Line, [Endpoint, Name] }, Line, Args }, S)
  end.

dispatch_require(Line, Receiver, Name, Args, S, Callback) ->
  Module = S#elixir_scope.module,
  Arity  = length(Args),
  Tuple  = { Name, Arity },

  case (Receiver == Module) andalso is_element(Tuple, in_erlang_functions()) of
    true ->
      elixir_translator:translate_each({ { '.', Line, [erlang, Name] }, Line, Args }, S);
    false ->
      case expand_require(Line, Module, Receiver, Tuple, Args, S) of
        { error, noexpansion } ->
          Callback();
        { error, internal } ->
          elixir_macros:translate_macro({ Name, Line, Args }, S);
        { ok, Tree } ->
          translate_expansion(Line, Tree, Receiver, Name, Arity, S)
      end
  end.

%% Macros expansion

expand_import(Line, Module, { Name, Arity } = Tuple, Args, S) ->
  case find_dispatch(Tuple, S#elixir_scope.macros) of
    false ->
      Fun = (S#elixir_scope.function /= Tuple) andalso
        elixir_def_local:macro_for(Tuple, true, Module),
      case Fun of
        false -> { error, noexpansion };
        _ ->
          elixir_import:record(import, Tuple, Module, Module),
          { ok, Module, expand_macro_fun(Line, Fun, Module, Name, Arity, Args, S) }
      end;
    ?BUILTIN ->
      case is_element(Tuple, in_elixir_macros()) of
        false -> { error, internal };
        true  ->
          elixir_import:record(import, Tuple, ?BUILTIN, Module),
          { ok, ?BUILTIN, expand_macro_named(Line, ?BUILTIN, Name, Arity, Args, S) }
      end;
    Receiver ->
      elixir_import:record(import, Tuple, Receiver, Module),
      { ok, Receiver, expand_macro_named(Line, Receiver, Name, Arity, Args, S) }
  end.

expand_require(Line, _Module, ?BUILTIN, { Name, Arity } = Tuple, Args, S) ->
  case is_element(Tuple, in_erlang_macros()) of
    true  -> { error, internal };
    false ->
      case is_element(Tuple, in_elixir_macros()) of
        true  -> { ok, expand_macro_named(Line, ?BUILTIN, Name, Arity, Args, S) };
        false -> { error, noexpansion }
      end
  end;

expand_require(Line, Module, Receiver, { Name, Arity } = Tuple, Args, S) ->
  Fun = (Module == Receiver) andalso (S#elixir_scope.function /= Tuple) andalso
    elixir_def_local:macro_for(Tuple, false, Module),

  case Fun of
    false ->
      case is_element(Tuple, get_optional_macros(Receiver)) of
        true  -> { ok, expand_macro_named(Line, Receiver, Name, Arity, Args, S) };
        false -> { error, noexpansion }
      end;
    _ ->
      elixir_import:record(import, Tuple, Receiver, Module),
      { ok, expand_macro_fun(Line, Fun, Receiver, Name, Arity, Args, S) }
  end.

%% Expansion helpers

expand_macro_fun(Line, Fun, Receiver, Name, Arity, Args, S) ->
  ensure_required(Line, Receiver, Name, Arity, S),
  MacroS = {Line,S},

  try
    apply(Fun, [MacroS|Args])
  catch
    Kind:Reason ->
      Info = { Receiver, Name, length(Args), [{ file, S#elixir_scope.filename }, { line, Line }] },
      erlang:raise(Kind, Reason, munge_stacktrace(Info, erlang:get_stacktrace(), MacroS))
  end.

expand_macro_named(Line, Receiver, Name, Arity, Args, S) ->
  %% Fix macro name and arity
  ProperName  = ?ELIXIR_MACRO(Name),
  ProperArity = Arity + 1,
  expand_macro_fun(Line, fun Receiver:ProperName/ProperArity, Receiver, Name, Arity, Args, S).

translate_expansion(Line, Tree, Receiver, Name, Arity, S) ->
  NewS = S#elixir_scope{macro=[{Line,Receiver,Name,Arity}|S#elixir_scope.macro]},
  { TTree, TS } = elixir_translator:translate_each(elixir_quote:linify(Line, Tree), NewS),
  { TTree, TS#elixir_scope{macro=S#elixir_scope.macro} }.

%% Helpers

find_dispatch(Tuple, [{ Name, Values }|T]) ->
  case is_element(Tuple, Values) of
    true  -> Name;
    false -> find_dispatch(Tuple, T)
  end;

find_dispatch(_Tuple, []) -> false.

munge_stacktrace(Info, [{ _, _, [S|_], _ }|_], S) ->
  [Info];

munge_stacktrace(Info, [{ elixir_dispatch, expand_macro_fun, _, _ }|_], _) ->
  [Info];

munge_stacktrace(Info, [H|T], S) ->
  [H|munge_stacktrace(Info, T, S)];

munge_stacktrace(_, [], _) ->
  [].

%% ERROR HANDLING

ensure_required(_Line, Receiver, _Name, _Arity, #elixir_scope{module=Receiver}) -> ok;
ensure_required(Line, Receiver, Name, Arity, S) ->
  Requires = S#elixir_scope.requires,
  case is_element(Receiver, Requires) of
    true  -> ok;
    false ->
      Tuple = { unrequired_module, { Receiver, Name, Arity, Requires } },
      elixir_errors:form_error(Line, S#elixir_scope.filename, ?MODULE, Tuple)
  end.

format_error({ unrequired_module,{Receiver, Name, Arity, Required }}) ->
  io_lib:format("tried to invoke macro ~s.~s/~B but module was not required. Required: ~p",
    [elixir_errors:inspect(Receiver), Name, Arity, [elixir_errors:inspect(R) || R <- Required]]).

%% INTROSPECTION

remote_function(Line, Receiver, Name, Arity, S) ->
  Final =
    case Receiver == ?BUILTIN andalso is_element({ Name, Arity }, in_erlang_functions()) of
      true  -> erlang;
      false -> Receiver
    end,

  { { 'fun', Line, { function,
    { atom, Line, Final },
    { atom, Line, Name },
    { integer, Line, Arity}
  } }, S }.

%% Do not try to get macros from Erlang. Speeds up compilation a bit.
get_optional_macros(erlang) -> [];

get_optional_macros(Receiver) ->
  case code:ensure_loaded(Receiver) of
    { module, Receiver } ->
      try
        Receiver:'__info__'(macros)
      catch
        error:undef -> []
      end;
    { error, _ } -> []
  end.

%% Functions imported from Elixit.Builtin module. Sorted on compilation.

in_elixir_functions() ->
  try
    ?BUILTIN:'__info__'(functions) -- [{'__info__',1}]
  catch
    error:undef -> []
  end.

%% Macros imported from Elixit.Builtin module. Sorted on compilation.

in_elixir_macros() ->
  try
    ?BUILTIN:'__info__'(macros)
  catch
    error:undef -> []
  end.

%% Functions imported from Erlang module. MUST BE SORTED.
in_erlang_functions() ->
  [
    { abs, 1 },
    { atom_to_binary, 2 },
    { atom_to_list, 1 },
    % Those are allowed in guard clauses, so we need to bring them back.
    % { binary_part, 2 },
    % { binary_part, 3 },
    { binary_to_atom, 2 },
    { binary_to_existing_atom, 2 },
    { binary_to_list, 1 },
    { binary_to_list, 3 },
    { binary_to_term, 1 },
    { binary_to_term, 2 },
    { bit_size, 1 },
    { bitstring_to_list, 1 },
    { byte_size, 1 },
    % { date, 0 },
    { exit, 1 },
    { float, 1 },
    { float_to_list, 1 },
    { halt, 0 },
    { halt, 1 },
    { halt, 2 },
    { hd, 1 },
    { integer_to_list, 1 },
    { integer_to_list, 2 },
    { iolist_size, 1 },
    { iolist_to_binary, 1 },
    { is_atom, 1 },
    { is_binary, 1 },
    { is_bitstring, 1 },
    { is_boolean, 1 },
    { is_float, 1 },
    { is_function, 1 },
    { is_function, 2 },
    { is_integer, 1 },
    { is_list, 1 },
    { is_number, 1 },
    { is_pid, 1 },
    { is_port, 1 },
    { is_reference, 1 },
    { is_tuple, 1 },
    { length, 1 },
    { list_to_atom, 1 },
    { list_to_binary, 1 },
    { list_to_bitstring, 1 },
    { list_to_existing_atom, 1 },
    { list_to_float, 1 },
    { list_to_integer, 1 },
    { list_to_integer, 2 },
    { list_to_pid, 1 },
    { list_to_tuple, 1 },
    { make_ref, 0 },
    { max, 2 },
    { min, 2 },
    { node, 0 },
    { node, 1 },
    % { now, 0 },
    { pid_to_list, 1 },
    { round, 1 },
    { size, 1 },
    { spawn, 1 },
    { spawn, 3 },
    { spawn_link, 1 },
    { spawn_link, 3 },
    % { split_binary, 2 },
    { term_to_binary, 1 },
    { term_to_binary, 2 },
    { throw, 1 },
    % { time, 0 },
    { tl, 1 },
    { trunc, 1 },
    { tuple_size, 1 },
    { tuple_to_list, 1 }
  ].

%% Macros implemented in Erlang. MUST BE SORTED.
in_erlang_macros() ->
  [
    {'!=',2},
    {'!==',2},
    {'*',2},
    {'+',1},
    {'+',2},
    {'++',2},
    {'-',1},
    {'-',2},
    {'--',2},
    {'/',2},
    {'<',2},
    {'<-',2},
    {'<=',2},
    {'==',2},
    {'===',2},
    {'>',2},
    {'>=',2},
    {'@',1},
    {'and',2},
    {apply,2},
    {apply,3},
    {'case',2},
    {def,1},
    {def,2},
    {def,4},
    {defmacro,1},
    {defmacro,2},
    {defmacro,4},
    {defmacrop,1},
    {defmacrop,2},
    {defmacrop,4},
    {defmodule,2},
    {defp,1},
    {defp,2},
    {defp,4},
    {'not',1},
    {'or',2},
    {'receive',1},
    {'try',1},
    {'var!',1},
    {'xor',2}
  ].